#!/usr/bin/env bash
set -Eeuo pipefail

source /controls/logging.sh

NODE_ID=${NODE_ID:-}
NODE_NAME=${NODE_NAME:-}
NODE_ROLE=${NODE_ROLE:-validator}
SCENARIO_ID=${SCENARIO_ID:-}
ACTIVE_NODES=${ACTIVE_NODES:-}
BOOTSTRAP_TARGET_HEIGHT=${BOOTSTRAP_TARGET_HEIGHT:-200}
BOOTSTRAP_TIMEOUT_SECONDS=${BOOTSTRAP_TIMEOUT_SECONDS:-900}
BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
RPC_PORT=${RPC_PORT:-38332}
P2P_PORT=${P2P_PORT:-38333}
NETWORK_SUBNET=${NETWORK_SUBNET:-}
NETWORK_INTERFACE=${NETWORK_INTERFACE:-eth0}
SIGNET_CHALLENGE=${SIGNET_CHALLENGE:-51}
BITCOIN_DBCACHE_MB=${BITCOIN_DBCACHE_MB:-128}
BITCOIN_MAXMEMPOOL_MB=${BITCOIN_MAXMEMPOOL_MB:-64}
BITCOIN_PAR=${BITCOIN_PAR:-1}
BITCOIN_SOURCE_REPOSITORY=${BITCOIN_SOURCE_REPOSITORY:-}
BITCOIN_SOURCE_REVISION=${BITCOIN_SOURCE_REVISION:-}
BITCOIN_ARCHITECTURE=${BITCOIN_ARCHITECTURE:-}
BITCOIN_COMPILED_VERSION=
RUN_DIR=/run/bitcoin-env
CONF=${BITCOIN_DATADIR}/bitcoin.conf
BITCOIND_PID=
SHUTTING_DOWN=0
BOOTSTRAP_POSITION=-1
BOOTSTRAP_NODE_COUNT=0
BOOTSTRAP_START_HEIGHT=0
BOOTSTRAP_END_HEIGHT=0
BOOTSTRAP_BLOCK_COUNT=0
BOOTSTRAP_WALLET=
INITIAL_TIP_HASH=
SCENARIO_START_EPOCH=0
declare -a ACTIVE_NODE_LIST=()

log() {
  test_log INFO entrypoint "$*"
}

local_cli() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$CONF" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    "$@"
}

remote_cli() {
  local node=$1
  shift
  bitcoin-cli \
    -rpcconnect="$node" \
    -rpcport="$RPC_PORT" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=30 \
    "$@"
}

rpc_for_node() {
  local node=$1
  shift
  if [[ "$node" == "$NODE_NAME" ]]; then
    local_cli "$@"
  else
    remote_cli "$node" "$@"
  fi
}

verify_binary_metadata() {
  local binary metadata_file
  local embedded_repository embedded_revision embedded_architecture embedded_version actual_version

  for binary in bitcoin bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
    command -v "$binary" >/dev/null 2>&1 || {
      log "Required locally compiled binary is missing: ${binary}"
      return 1
    }
  done
  for metadata_file in SOURCE_REPOSITORY SOURCE_REVISION ARCHITECTURE VERSION; do
    if [[ ! -r "/opt/bitcoin/${metadata_file}" ]]; then
      log "Compiled-binary metadata file is missing: ${metadata_file}"
      return 1
    fi
  done

  embedded_repository=$(tr -d '[:space:]' < /opt/bitcoin/SOURCE_REPOSITORY)
  embedded_revision=$(tr -d '[:space:]' < /opt/bitcoin/SOURCE_REVISION)
  embedded_architecture=$(tr -d '[:space:]' < /opt/bitcoin/ARCHITECTURE)
  embedded_version=$(head -n 1 /opt/bitcoin/VERSION)
  actual_version=$(bitcoind --version | head -n 1)
  BITCOIN_COMPILED_VERSION=$embedded_version

  if [[ ! "$embedded_repository" =~ ^[A-Za-z0-9._-]+$ \
        || "$embedded_repository" == "." \
        || "$embedded_repository" == ".." \
        || -z "$embedded_revision" \
        || ! "$embedded_architecture" =~ ^(amd64|arm64)$ \
        || -z "$embedded_version" \
        || "$actual_version" != "$embedded_version" ]]; then
    log "Compiled-binary metadata is invalid"
    return 1
  fi
  if [[ "$BITCOIN_SOURCE_REPOSITORY" != "$embedded_repository" \
        || "$BITCOIN_SOURCE_REVISION" != "$embedded_revision" \
        || "$BITCOIN_ARCHITECTURE" != "$embedded_architecture" ]]; then
    log "Compiled-binary metadata does not match the image environment"
    return 1
  fi
}

shutdown() {
  local status=$?
  if [[ "$SHUTTING_DOWN" -eq 1 ]]; then
    exit "$status"
  fi
  SHUTTING_DOWN=1
  trap - EXIT TERM INT
  set +e
  local_cli stop >/dev/null 2>&1 || true
  if [[ -n "${BITCOIND_PID:-}" ]]; then
    for _ in $(seq 1 120); do
      kill -0 "$BITCOIND_PID" >/dev/null 2>&1 || break
      sleep 0.25
    done
    kill -TERM "$BITCOIND_PID" >/dev/null 2>&1 || true
    wait "$BITCOIND_PID" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

validate_inputs() {
  if [[ $# -gt 1 ]]; then
    printf 'Expected at most one scenario-number argument, received %d\n' "$#" >&2
    return 2
  fi
  if [[ $# -eq 1 ]]; then
    SCENARIO_ID=$1
  fi
  if [[ ! "$NODE_ID" =~ ^0[1-8]$ ]]; then
    printf 'NODE_ID must be 01 through 08: %s\n' "${NODE_ID:-missing}" >&2
    return 2
  fi
  NODE_NAME=${NODE_NAME:-node${NODE_ID}}
  if [[ "$NODE_NAME" != "node${NODE_ID}" ]]; then
    printf 'NODE_NAME must match NODE_ID: %s versus %s\n' "$NODE_NAME" "$NODE_ID" >&2
    return 2
  fi
  if [[ ! "$SCENARIO_ID" =~ ^[0-9]+$ ]]; then
    printf 'Scenario number must be a non-negative integer: %s\n' "${SCENARIO_ID:-missing}" >&2
    return 2
  fi
  if [[ "$BOOTSTRAP_TARGET_HEIGHT" != "200" ]]; then
    printf 'BOOTSTRAP_TARGET_HEIGHT must be exactly 200.\n' >&2
    return 2
  fi
  if [[ ! "$BOOTSTRAP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'BOOTSTRAP_TIMEOUT_SECONDS must be a positive integer.\n' >&2
    return 2
  fi
}

parse_active_nodes() {
  local node index
  declare -A seen=()

  IFS=',' read -r -a ACTIVE_NODE_LIST <<< "$ACTIVE_NODES"
  if [[ ${#ACTIVE_NODE_LIST[@]} -eq 0 ]]; then
    log "ACTIVE_NODES is empty"
    return 2
  fi

  BOOTSTRAP_POSITION=-1
  for index in "${!ACTIVE_NODE_LIST[@]}"; do
    node=${ACTIVE_NODE_LIST[$index]}
    if [[ ! "$node" =~ ^node0[1-8]$ ]]; then
      log "Invalid active-node name: ${node}"
      return 2
    fi
    if [[ -n "${seen[$node]:-}" ]]; then
      log "Duplicate active-node name: ${node}"
      return 2
    fi
    seen[$node]=1
    if [[ "$node" == "$NODE_NAME" ]]; then
      BOOTSTRAP_POSITION=$index
    fi
  done

  BOOTSTRAP_NODE_COUNT=${#ACTIVE_NODE_LIST[@]}
  if [[ "$BOOTSTRAP_POSITION" -lt 0 ]]; then
    log "${NODE_NAME} is not present in ACTIVE_NODES=${ACTIVE_NODES}"
    return 2
  fi
}

calculate_bootstrap_range() {
  local target=$1
  local position=$2
  local node_count=$3
  local base remainder earlier_extras count start end

  if (( target < 1 || node_count < 1 || position < 0 || position >= node_count )); then
    return 2
  fi

  base=$((target / node_count))
  remainder=$((target % node_count))
  earlier_extras=$position
  if (( earlier_extras > remainder )); then
    earlier_extras=$remainder
  fi

  count=$base
  if (( position < remainder )); then
    count=$((count + 1))
  fi
  start=$((position * base + earlier_extras + 1))
  end=$((start + count - 1))
  printf '%d %d %d\n' "$start" "$count" "$end"
}

detect_network_subnet() {
  local subnet
  subnet=$(ip -4 route show dev "$NETWORK_INTERFACE" scope link 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print $1; exit}')
  if [[ ! "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    log "Could not detect the Docker IPv4 subnet on ${NETWORK_INTERFACE}"
    return 1
  fi
  NETWORK_SUBNET=$subnet
  export NETWORK_SUBNET
  log "Using Docker-assigned internal subnet ${NETWORK_SUBNET}"
}

configure_node() {
  local peer peer_count=0

  find "$BITCOIN_DATADIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  rm -rf "$RUN_DIR"
  install -d -m 0755 "$BITCOIN_DATADIR" "$RUN_DIR"

  cat > "$CONF" <<CFG
signet=1
signetchallenge=${SIGNET_CHALLENGE}
server=1
rpcuser=${RPC_USER}
rpcpassword=${RPC_PASSWORD}
rpcthreads=4
maxconnections=64
txindex=1
assumevalid=0
minimumchainwork=0
fallbackfee=0.00001000
dbcache=${BITCOIN_DBCACHE_MB}
maxmempool=${BITCOIN_MAXMEMPOOL_MB}
par=${BITCOIN_PAR}
persistmempool=0
printtoconsole=1
logtimestamps=1
logtimemicros=1
logthreadnames=1
loglevelalways=1
logips=1

debug=net
debug=validation
debug=mempool
debug=mempoolrej
debug=cmpctblock
debug=txreconciliation
debug=blockstorage

[signet]
listen=1
dnsseed=0
fixedseeds=0
discover=0
listenonion=0
natpmp=0
onlynet=ipv4
bind=0.0.0.0:${P2P_PORT}
port=${P2P_PORT}
rpcallowip=${NETWORK_SUBNET}
rpcallowip=127.0.0.1
rpcbind=0.0.0.0:${RPC_PORT}
rpcport=${RPC_PORT}
CFG

  for peer in "${ACTIVE_NODE_LIST[@]}"; do
    if [[ "$peer" != "$NODE_NAME" ]]; then
      printf 'connect=%s:%s\n' "$peer" "$P2P_PORT" >> "$CONF"
      peer_count=$((peer_count + 1))
    fi
  done
  if [[ "$peer_count" -eq 0 ]]; then
    printf 'connect=0\n' >> "$CONF"
  fi

  chown -R bitcoin:bitcoin "$BITCOIN_DATADIR"
  chmod 0600 "$CONF"
}

start_bitcoin() {
  gosu bitcoin bitcoind -datadir="$BITCOIN_DATADIR" -conf="$CONF" &
  BITCOIND_PID=$!
}

wait_for_local_rpc() {
  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
  while (( $(date +%s) <= deadline )); do
    if local_cli getblockchaininfo >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$BITCOIND_PID" >/dev/null 2>&1; then
      log "Bitcoin Core exited before RPC became ready"
      wait "$BITCOIND_PID" || true
      return 1
    fi
    sleep 0.25
  done
  log "Local RPC did not become ready within ${BOOTSTRAP_TIMEOUT_SECONDS}s"
  return 1
}

verify_private_signet() {
  local chain challenge

  chain=$(local_cli getblockchaininfo | jq -r '.chain // empty')
  challenge=$(local_cli getmininginfo | jq -r '.signet_challenge // empty')
  if [[ "$chain" != "signet" || "$challenge" != "$SIGNET_CHALLENGE" ]]; then
    log "Unexpected network mode: chain=${chain:-missing}, challenge=${challenge:-missing}"
    return 1
  fi
}

wait_for_all_rpc() {
  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
  local node all_ready

  log "Waiting for RPC on ${BOOTSTRAP_NODE_COUNT} selected node(s)"
  while (( $(date +%s) <= deadline )); do
    all_ready=1
    for node in "${ACTIVE_NODE_LIST[@]}"; do
      if ! rpc_for_node "$node" getblockcount >/dev/null 2>&1; then
        all_ready=0
        break
      fi
    done
    if [[ "$all_ready" -eq 1 ]]; then
      log "All selected node RPC endpoints are ready"
      return 0
    fi
    sleep 0.5
  done
  log "Timed out waiting for all selected node RPC endpoints"
  return 1
}

wait_for_peer_mesh() {
  local expected=$((BOOTSTRAP_NODE_COUNT - 1))
  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
  local current

  if [[ "$expected" -eq 0 ]]; then
    return 0
  fi
  while (( $(date +%s) <= deadline )); do
    current=$(local_cli getconnectioncount 2>/dev/null || printf '0')
    if (( current >= expected )); then
      return 0
    fi
    sleep 0.5
  done
  log "Timed out with $(local_cli getconnectioncount 2>/dev/null || printf '0') peer connection(s)"
  return 1
}

prepare_bootstrap_wallet() {
  BOOTSTRAP_WALLET=$(_default_wallet)
  create_wallet "$BOOTSTRAP_WALLET"
}

wait_for_exact_bootstrap_height() {
  local target=$1
  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
  local current

  while (( $(date +%s) <= deadline )); do
    current=$(local_cli getblockcount 2>/dev/null || printf -- '-1')
    if (( current == target )); then
      return 0
    fi
    if (( current > target )); then
      log "Bootstrap chain passed expected height ${target}: current=${current}"
      return 1
    fi
    sleep 0.25
  done
  log "Timed out waiting for bootstrap height ${target}"
  return 1
}

mine_bootstrap_share() {
  local previous_height=$((BOOTSTRAP_START_HEIGHT - 1))
  local height block_hash

  log "Assigned bootstrap range ${BOOTSTRAP_START_HEIGHT}-${BOOTSTRAP_END_HEIGHT} (${BOOTSTRAP_BLOCK_COUNT} blocks)"
  wait_for_exact_bootstrap_height "$previous_height"

  for ((height = BOOTSTRAP_START_HEIGHT; height <= BOOTSTRAP_END_HEIGHT; height++)); do
    block_hash=$(mine_blocks 1 "$BOOTSTRAP_WALLET")
    block_hash=${block_hash//$'\n'/}
    if [[ ! "$block_hash" =~ ^[0-9a-f]{64}$ ]]; then
      log "Invalid block hash returned while generating initial block ${height}: ${block_hash:-missing}"
      return 1
    fi
    wait_for_exact_bootstrap_height "$height"
  done

  wait_for_exact_bootstrap_height "$BOOTSTRAP_END_HEIGHT"
  log "Completed bootstrap range ${BOOTSTRAP_START_HEIGHT}-${BOOTSTRAP_END_HEIGHT}"
}

wait_for_txindex() {
  local deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
  while (( $(date +%s) <= deadline )); do
    if local_cli getindexinfo txindex 2>/dev/null | jq -e '.txindex.synced == true' >/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  log "Timed out waiting for txindex"
  return 1
}

verify_local_initial_state() {
  local chain challenge

  wait_for_exact_bootstrap_height "$BOOTSTRAP_TARGET_HEIGHT"
  wait_for_txindex
  verify_private_signet
  INITIAL_TIP_HASH=$(local_cli getblockhash "$BOOTSTRAP_TARGET_HEIGHT")
  local_cli verifychain 4 0 >/dev/null

  chain=$(local_cli getblockchaininfo | jq -r '.chain // empty')
  challenge=$(local_cli getmininginfo | jq -r '.signet_challenge // empty')
  if [[ "$chain" != "signet" || "$challenge" != "$SIGNET_CHALLENGE" ]]; then
    log "Local bootstrap verification failed: chain=${chain:-missing}, challenge=${challenge:-missing}"
    return 1
  fi
}

record_initial_state() {
  cat > "$RUN_DIR/initial-state.env" <<STATE
CHAIN=signet
HEIGHT=${BOOTSTRAP_TARGET_HEIGHT}
TIP_HASH=${INITIAL_TIP_HASH}
ACTIVE_NODE_COUNT=${BOOTSTRAP_NODE_COUNT}
MINED_FROM=${BOOTSTRAP_START_HEIGHT}
MINED_TO=${BOOTSTRAP_END_HEIGHT}
MINED_BLOCKS=${BOOTSTRAP_BLOCK_COUNT}
WALLET=${BOOTSTRAP_WALLET}
SOURCE_REPOSITORY=${BITCOIN_SOURCE_REPOSITORY}
SOURCE_REVISION=${BITCOIN_SOURCE_REVISION}
ARCHITECTURE=${BITCOIN_ARCHITECTURE}
VERSION=${BITCOIN_COMPILED_VERSION}
STATE
  touch "$RUN_DIR/initial-state.ready"
}

wait_for_scenario_release() {
  local release_file="$RUN_DIR/scenario.start"
  log "Initial chain is ready; waiting for the shared scenario release"
  while [[ ! -s "$release_file" ]]; do
    if ! kill -0 "$BITCOIND_PID" >/dev/null 2>&1; then
      log "Bitcoin Core exited while waiting for scenario release"
      return 1
    fi
    sleep 0.25
  done
  SCENARIO_START_EPOCH=$(tr -d '[:space:]' < "$release_file")
  if [[ ! "$SCENARIO_START_EPOCH" =~ ^[1-9][0-9]*$ ]]; then
    log "Invalid scenario start epoch: ${SCENARIO_START_EPOCH}"
    return 1
  fi
  export SCENARIO_START_EPOCH
  log "Scenario ${SCENARIO_ID} released for epoch ${SCENARIO_START_EPOCH}"
}

execute_scenario() {
  local scenario_file="/scenarios/node${NODE_ID}_scenario${SCENARIO_ID}.sh"
  local scenario_status=127

  if [[ ! -f "$scenario_file" ]]; then
    log "Scenario file is missing: ${scenario_file}"
  else
    export NODE_ID NODE_NAME NODE_ROLE SCENARIO_ID ACTIVE_NODES SCENARIO_START_EPOCH BITCOIND_PID
    export BITCOIN_DATADIR RPC_USER RPC_PASSWORD RPC_PORT P2P_PORT NETWORK_SUBNET
    export BITCOIN_SOURCE_REPOSITORY BITCOIN_SOURCE_REVISION BITCOIN_ARCHITECTURE BITCOIN_COMPILED_VERSION
    log "Executing ${scenario_file}"
    set +e
    bash "$scenario_file"
    scenario_status=$?
    set -e
  fi

  printf '%s\n' "$scenario_status" > "$RUN_DIR/scenario.status"
  touch "$RUN_DIR/scenario.done"
  if [[ "$scenario_status" -eq 0 ]]; then
    log "Scenario ${SCENARIO_ID} completed successfully; keeping the node alive for result collection"
  else
    log "Scenario ${SCENARIO_ID} failed with status ${scenario_status}; keeping the node alive for result collection"
  fi
}

main() {
  validate_inputs "$@"
  parse_active_nodes
  read -r BOOTSTRAP_START_HEIGHT BOOTSTRAP_BLOCK_COUNT BOOTSTRAP_END_HEIGHT \
    < <(calculate_bootstrap_range "$BOOTSTRAP_TARGET_HEIGHT" "$BOOTSTRAP_POSITION" "$BOOTSTRAP_NODE_COUNT")

  trap shutdown EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  verify_binary_metadata
  detect_network_subnet
  configure_node
  start_bitcoin
  wait_for_local_rpc
  verify_private_signet

  source /controls/actions.sh
  prepare_bootstrap_wallet
  wait_for_all_rpc
  wait_for_peer_mesh
  mine_bootstrap_share
  verify_local_initial_state
  record_initial_state
  wait_for_scenario_release
  execute_scenario

  while kill -0 "$BITCOIND_PID" >/dev/null 2>&1; do
    sleep 1
  done
  wait "$BITCOIND_PID"
}

if [[ "${BITCOIN_ENV_LIBRARY_ONLY:-0}" != "1" ]]; then
  main "$@"
fi

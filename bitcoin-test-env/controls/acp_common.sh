#!/usr/bin/env bash

source /controls/logging.sh
source /controls/actions.sh

SCENARIO_DURATION_SECONDS=${SCENARIO_DURATION_SECONDS:-180}
SCENARIO_WARMUP_SECONDS=${SCENARIO_WARMUP_SECONDS:-20}

readonly ACP_EXPECTED_NODES=node01,node02,node03,node04
readonly ACP_FORK_NODE=node02
readonly ACP_RECIPIENT_NODE=node03
readonly ACP_OBSERVER_NODE=node04

ACP_WALLET=
ACP_RECIPIENT_ADDRESS=
ACP_MINING_ADDRESS=
ACP_FORK_MINING_ADDRESS=
ACP_CHANGE_ADDRESS=
ACP_SEND_OUTPUTS=

readonly ACP_WORK_DIR="/data/acp-test/scenario-${SCENARIO_ID}-${NODE_NAME}"
readonly ACP_OBSERVATIONS_FILE=/run/bitcoin-env/acp-observations.jsonl
readonly ACP_SUMMARY_FILE=/run/bitcoin-env/acp-behavior-summary.json

ACP_LAST_OUTCOME=unobserved
ACP_LAST_EFFECTS_JSON='{}'

acp_log() {
  local component=$1
  shift
  test_log INFO "$component" "$*"
}

acp_require_positive_integer() {
  local name=$1
  local value=$2

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s must be a positive integer: %s\n' "$name" "$value" >&2
    return 2
  fi
}

acp_rpc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=120 \
    "$@"
}

acp_wallet_rpc() {
  local wallet=$1
  shift
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=120 \
    -rpcwallet="$wallet" \
    "$@"
}

acp_remote_rpc() {
  local node=$1
  shift
  bitcoin-cli \
    -rpcconnect="$node" \
    -rpcport="$RPC_PORT" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=120 \
    "$@"
}

acp_remote_wallet_rpc() {
  local node=$1
  local wallet=$2
  shift 2
  bitcoin-cli \
    -rpcconnect="$node" \
    -rpcport="$RPC_PORT" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=120 \
    -rpcwallet="$wallet" \
    "$@"
}

acp_wait_until_epoch() {
  local epoch=$1
  local now

  while :; do
    now=$(date +%s)
    (( now >= epoch )) && return 0
    sleep 1
  done
}

acp_assert_initial_state() {
  local state_file=/run/bitcoin-env/initial-state.env
  local expected_hash actual_hash height recorded_height recorded_chain local_chain

  [[ -r "$state_file" ]] || return 1
  recorded_chain=$(awk -F= '$1 == "CHAIN" {print $2; exit}' "$state_file")
  recorded_height=$(awk -F= '$1 == "HEIGHT" {print $2; exit}' "$state_file")
  expected_hash=$(awk -F= '$1 == "TIP_HASH" {print $2; exit}' "$state_file")
  height=$(acp_rpc getblockcount)
  local_chain=$(acp_rpc getblockchaininfo | jq -r '.chain // empty')

  [[ "$recorded_chain" == "signet" && "$local_chain" == "signet" ]] || return 1
  [[ "$recorded_height" == "$BOOTSTRAP_TARGET_HEIGHT" ]] || return 1
  (( height >= BOOTSTRAP_TARGET_HEIGHT )) || return 1
  actual_hash=$(acp_rpc getblockhash "$BOOTSTRAP_TARGET_HEIGHT")
  [[ -n "$expected_hash" && "$actual_hash" == "$expected_hash" ]]
}

acp_begin_scenario() {
  local scenario_name=$1

  [[ "$ACTIVE_NODES" == "$ACP_EXPECTED_NODES" ]] || {
    printf 'ACP scenario %s requires exactly %s: %s\n' \
      "$SCENARIO_ID" "$ACP_EXPECTED_NODES" "$ACTIVE_NODES" >&2
    return 2
  }
  acp_require_positive_integer SCENARIO_DURATION_SECONDS "$SCENARIO_DURATION_SECONDS"
  acp_require_positive_integer SCENARIO_WARMUP_SECONDS "$SCENARIO_WARMUP_SECONDS"
  acp_assert_initial_state
  mkdir -p "$ACP_WORK_DIR"
  chmod 0700 "$ACP_WORK_DIR"
  export TMPDIR="$ACP_WORK_DIR"
  if [[ "$NODE_NAME" == "node01" ]]; then
    : > "$ACP_OBSERVATIONS_FILE"
    rm -f "$ACP_SUMMARY_FILE"
  fi
  acp_wait_until_epoch "$SCENARIO_START_EPOCH"
  acp_log scenario \
    "preparing behavior-observation scenario=${SCENARIO_ID} name=${scenario_name} node=${NODE_NAME} version=${BITCOIN_COMPILED_VERSION}"
}

acp_wait_for_activity_release() {
  local release_file=/run/bitcoin-env/activity.start
  local activity_epoch

  acp_log scenario "preparation complete; waiting for synchronized test release"
  touch /run/bitcoin-env/scenario.prepared
  while [[ ! -s "$release_file" ]]; do
    kill -0 "$BITCOIND_PID" >/dev/null 2>&1 || return 1
    sleep 0.25
  done
  activity_epoch=$(tr -d '[:space:]' < "$release_file")
  [[ "$activity_epoch" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid activity start epoch: %s\n' "$activity_epoch" >&2
    return 2
  }
  printf '%s\n' "$activity_epoch"
}

acp_wait_for_node_tip() {
  local node=$1
  local expected_hash=$2
  local timeout_seconds=${3:-60}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local tip

  while (( $(date +%s) <= deadline )); do
    if [[ "$node" == "$NODE_NAME" ]]; then
      tip=$(bitcoin_rpc getbestblockhash 2>/dev/null || true)
    else
      tip=$(acp_remote_rpc "$node" getbestblockhash 2>/dev/null || true)
    fi
    [[ "$tip" == "$expected_hash" ]] && return 0
    sleep 0.1
  done
  return 1
}

acp_wait_for_all_tips() {
  local expected_hash=$1
  local timeout_seconds=${2:-60}
  local node

  for node in node01 node02 node03 node04; do
    acp_wait_for_node_tip "$node" "$expected_hash" "$timeout_seconds" || {
      acp_log fixture "node=${node} did not reach expected_tip=${expected_hash}"
      return 1
    }
  done
}

acp_wait_for_common_tip() {
  local timeout_seconds=${1:-60}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local local_tip node remote_tip all_match
  local -a active_nodes=()

  IFS=',' read -r -a active_nodes <<< "$ACTIVE_NODES"
  while (( $(date +%s) <= deadline )); do
    local_tip=$(acp_rpc getbestblockhash 2>/dev/null || true)
    all_match=1
    [[ "$local_tip" =~ ^[0-9a-f]{64}$ ]] || all_match=0
    for node in "${active_nodes[@]}"; do
      [[ "$node" != "$NODE_NAME" ]] || continue
      remote_tip=$(acp_remote_rpc "$node" getbestblockhash 2>/dev/null || true)
      if [[ "$remote_tip" != "$local_tip" ]]; then
        all_match=0
        break
      fi
    done
    [[ "$all_match" -eq 1 ]] && return 0
    sleep 1
  done
  return 1
}

acp_mine_local_one() {
  local address=$1
  local result hash

  result=$(acp_rpc generatetoaddress 1 "$address" 100000000)
  hash=$(jq -r 'if type == "array" and length == 1 then .[0] else empty end' <<<"$result")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

acp_mine_remote_one() {
  local node=$1
  local address=$2
  local result hash

  result=$(acp_remote_rpc "$node" generatetoaddress 1 "$address" 100000000)
  hash=$(jq -r 'if type == "array" and length == 1 then .[0] else empty end' <<<"$result")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

acp_submit_fork_block() {
  local hash=$1
  local block_hex result

  block_hex=$(acp_remote_rpc "$ACP_FORK_NODE" getblock "$hash" 0)
  [[ "$block_hex" =~ ^[0-9a-fA-F]+$ ]] || return 1
  result=$(acp_rpc -stdin submitblock <<<"$block_hex") || return 1
  [[ -z "$result" || "$result" == "inconclusive" ]] || {
    acp_log fixture "fork block submission failed hash=${hash} result=${result}"
    return 1
  }
}

acp_effect_snapshot() {
  local wallet=$1
  local txcount balances locks local_mempool recipient_mempool observer_mempool tx_relay_bytes

  txcount=$(acp_wallet_rpc "$wallet" getwalletinfo | jq -r '.txcount') || return 1
  balances=$(acp_wallet_rpc "$wallet" getbalances | jq -cS '.mine') || return 1
  locks=$(acp_wallet_rpc "$wallet" listlockunspent | jq -cS 'sort_by(.txid, .vout)') || return 1
  local_mempool=$(bitcoin_rpc getrawmempool | jq -cS 'sort') || return 1
  recipient_mempool=$(acp_remote_rpc "$ACP_RECIPIENT_NODE" getrawmempool | jq -cS 'sort') || return 1
  observer_mempool=$(acp_remote_rpc "$ACP_OBSERVER_NODE" getrawmempool | jq -cS 'sort') || return 1
  tx_relay_bytes=$(bitcoin_rpc getpeerinfo \
    | jq '[.[] | (.bytessent_per_msg.tx // 0)] | add // 0') || return 1

  jq -cn \
    --argjson txcount "$txcount" \
    --argjson balances "$balances" \
    --argjson locks "$locks" \
    --argjson local_mempool "$local_mempool" \
    --argjson recipient_mempool "$recipient_mempool" \
    --argjson observer_mempool "$observer_mempool" \
    --argjson tx_relay_bytes "$tx_relay_bytes" \
    '{
      wallet_txcount: $txcount,
      balances: $balances,
      locks: $locks,
      local_mempool: $local_mempool,
      recipient_mempool: $recipient_mempool,
      observer_mempool: $observer_mempool,
      tx_relay_bytes: $tx_relay_bytes
    }'
}

acp_effect_delta() {
  local before=$1
  local after=$2

  jq -cn --argjson before "$before" --argjson after "$after" '
    def additions($new; $old):
      [$new[] as $item | select(($old | index($item)) == null) | $item];
    {
      wallet_txcount_before: $before.wallet_txcount,
      wallet_txcount_after: $after.wallet_txcount,
      wallet_txcount_delta: ($after.wallet_txcount - $before.wallet_txcount),
      balances_before: $before.balances,
      balances_after: $after.balances,
      balances_changed: ($after.balances != $before.balances),
      locks_before_count: ($before.locks | length),
      locks_after_count: ($after.locks | length),
      locks_added: additions($after.locks; $before.locks),
      locks_removed: additions($before.locks; $after.locks),
      local_mempool_before_count: ($before.local_mempool | length),
      local_mempool_after_count: ($after.local_mempool | length),
      local_mempool_added: additions($after.local_mempool; $before.local_mempool),
      recipient_mempool_before_count: ($before.recipient_mempool | length),
      recipient_mempool_after_count: ($after.recipient_mempool | length),
      recipient_mempool_added: additions($after.recipient_mempool; $before.recipient_mempool),
      observer_mempool_before_count: ($before.observer_mempool | length),
      observer_mempool_after_count: ($after.observer_mempool | length),
      observer_mempool_added: additions($after.observer_mempool; $before.observer_mempool),
      tx_relay_bytes_before: $before.tx_relay_bytes,
      tx_relay_bytes_after: $after.tx_relay_bytes,
      tx_relay_bytes_delta: ($after.tx_relay_bytes - $before.tx_relay_bytes)
    }'
}

acp_compact_file_text() {
  local path=$1

  if [[ ! -s "$path" ]]; then
    printf '%s\n' ''
    return 0
  fi
  tr '\r\n\t' '   ' < "$path" \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' \
    | cut -c1-500
}

acp_record_send_observation() {
  local observation_label=$1
  local status=$2
  local output_file=$3
  local error_file=$4
  local before=$5
  local after=$6
  local extra_json=${7:-'{}'}
  local valid_json=false complete_json=null
  local txid= decoded_txid= rpc_code= outcome error_summary result_keys=
  local hex_present=false psbt_present=false hex_decodable=false
  local stdout_bytes stderr_bytes hex_bytes=0 hex_sha256= effects summary

  [[ "$status" =~ ^[0-9]+$ ]] || return 1
  jq -e 'type == "object"' <<<"$extra_json" >/dev/null || return 1

  stdout_bytes=$(wc -c < "$output_file" | tr -d '[:space:]')
  stderr_bytes=$(wc -c < "$error_file" | tr -d '[:space:]')

  if [[ "$status" -eq 0 && -s "$output_file" ]] \
      && jq -e 'type == "object"' "$output_file" >/dev/null 2>&1; then
    valid_json=true
    complete_json=$(jq -c 'if has("complete") then .complete else null end' "$output_file")
    txid=$(jq -r '.txid // empty' "$output_file")
    result_keys=$(jq -r 'keys | join(",")' "$output_file")

    if jq -e '.hex | type == "string" and length > 0' "$output_file" >/dev/null 2>&1; then
      hex_present=true
      hex_bytes=$(jq -r '.hex | length' "$output_file")
      hex_sha256=$(jq -jr '.hex' "$output_file" | sha256sum | awk '{print $1}')
      if decoded_txid=$(jq -r '.hex' "$output_file" \
          | bitcoin_rpc -stdin decoderawtransaction 2>/dev/null \
          | jq -r '.txid // empty') \
          && [[ "$decoded_txid" =~ ^[0-9a-f]{64}$ ]]; then
        hex_decodable=true
      else
        decoded_txid=
      fi
    fi
    if jq -e '.psbt | type == "string" and length > 0' "$output_file" >/dev/null 2>&1; then
      psbt_present=true
    fi

    if [[ "$complete_json" == "true" && "$hex_present" == "true" ]]; then
      outcome=success_signed_transaction
    elif [[ "$psbt_present" == "true" ]]; then
      outcome=success_psbt
    else
      outcome=success_other
    fi
  elif [[ "$status" -eq 0 ]]; then
    outcome=success_non_json
  else
    rpc_code=$(sed -n 's/^error code: //p' "$error_file" | head -n 1 | tr -d '[:space:]')
    if grep -Fq 'Active-chain precondition failed' "$output_file" "$error_file"; then
      if grep -Fq 'before release' "$output_file" "$error_file"; then
        outcome=error_active_chain_precondition_before_release
      elif grep -Fq 'before signing' "$output_file" "$error_file"; then
        outcome=error_active_chain_precondition_before_signing
      else
        outcome=error_active_chain_precondition
      fi
    elif grep -Fqi 'active_chain_precondition' "$output_file" "$error_file"; then
      outcome=error_mentions_active_chain_precondition
    else
      outcome=error_rpc
    fi
  fi

  error_summary=$(acp_compact_file_text "$error_file")
  effects=$(acp_effect_delta "$before" "$after")
  summary=$(jq -cn \
    --argjson scenario "$SCENARIO_ID" \
    --arg observation_label "$observation_label" \
    --arg version "$BITCOIN_COMPILED_VERSION" \
    --arg source_repository "$BITCOIN_SOURCE_REPOSITORY" \
    --arg source_revision "$BITCOIN_SOURCE_REVISION" \
    --arg architecture "$BITCOIN_ARCHITECTURE" \
    --arg outcome "$outcome" \
    --argjson rpc_status "$status" \
    --arg rpc_code "$rpc_code" \
    --argjson valid_json "$valid_json" \
    --argjson complete "$complete_json" \
    --argjson hex_present "$hex_present" \
    --argjson psbt_present "$psbt_present" \
    --argjson hex_decodable "$hex_decodable" \
    --argjson stdout_bytes "$stdout_bytes" \
    --argjson stderr_bytes "$stderr_bytes" \
    --argjson hex_bytes "$hex_bytes" \
    --arg hex_sha256 "$hex_sha256" \
    --arg txid "$txid" \
    --arg decoded_txid "$decoded_txid" \
    --arg result_keys "$result_keys" \
    --arg error_summary "$error_summary" \
    --argjson effects "$effects" \
    --argjson extra "$extra_json" \
    '{
      scenario: $scenario,
      "label": $observation_label,
      binary_version: $version,
      binary_source_repository: $source_repository,
      binary_source_revision: $source_revision,
      binary_architecture: $architecture,
      outcome: $outcome,
      rpc_status: $rpc_status,
      rpc_code: (if $rpc_code == "" then null else $rpc_code end),
      valid_json_result: $valid_json,
      complete: $complete,
      hex_present: $hex_present,
      psbt_present: $psbt_present,
      hex_decodable: $hex_decodable,
      stdout_bytes: $stdout_bytes,
      stderr_bytes: $stderr_bytes,
      hex_bytes: $hex_bytes,
      hex_sha256: (if $hex_sha256 == "" then null else $hex_sha256 end),
      txid: (if $txid == "" then null else $txid end),
      decoded_txid: (if $decoded_txid == "" then null else $decoded_txid end),
      result_keys: (if $result_keys == "" then null else $result_keys end),
      error_summary: (if $error_summary == "" then null else $error_summary end),
      effects: $effects
    } + $extra')

  ACP_LAST_OUTCOME=$outcome
  ACP_LAST_EFFECTS_JSON=$effects

  printf '%s\n' "$summary" >> "$ACP_OBSERVATIONS_FILE"
  acp_log behavior "observation ${summary}"
}

acp_observe_send() {
  local label=$1
  local wallet=$2
  local outputs=$3
  local options=$4
  local before after start_ms end_ms status extra_json safe_label
  local output_file error_file

  safe_label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_')
  output_file="$ACP_WORK_DIR/acp-${SCENARIO_ID}-${safe_label}.out"
  error_file="$ACP_WORK_DIR/acp-${SCENARIO_ID}-${safe_label}.err"
  rm -f "$output_file" "$error_file"

  before=$(acp_effect_snapshot "$wallet")
  start_ms=$(date +%s%3N)
  if acp_wallet_rpc "$wallet" -named send \
      "outputs=$outputs" "options=$options" >"$output_file" 2>"$error_file"; then
    status=0
  else
    status=$?
  fi
  end_ms=$(date +%s%3N)
  sleep 1
  after=$(acp_effect_snapshot "$wallet")
  extra_json=$(jq -cn \
    --argjson start_ms "$start_ms" \
    --argjson end_ms "$end_ms" \
    --argjson elapsed_ms "$((end_ms - start_ms))" \
    '{request_start_ms: $start_ms, request_end_ms: $end_ms, elapsed_ms: $elapsed_ms}')
  acp_record_send_observation \
    "$label" "$status" "$output_file" "$error_file" "$before" "$after" "$extra_json"
  rm -f "$output_file" "$error_file"
}

acp_write_behavior_summary() {
  local summary=$1

  jq -e 'type == "object"' <<<"$summary" >/dev/null || return 1
  printf '%s\n' "$summary" > "$ACP_SUMMARY_FILE"
  acp_log behavior "summary ${summary}"
}

acp_plain_send_options() {
  local add_to_wallet=$1

  jq -cn \
    --arg change_address "$ACP_CHANGE_ADDRESS" \
    --argjson add_to_wallet "$add_to_wallet" \
    '{
      fee_rate: 1,
      add_to_wallet: $add_to_wallet,
      change_address: $change_address
    }'
}

acp_send_options() {
  local block_hash=$1
  local min_confirmations=$2
  local add_to_wallet=$3

  jq -cn \
    --arg block_hash "$block_hash" \
    --arg change_address "$ACP_CHANGE_ADDRESS" \
    --argjson min_confirmations "$min_confirmations" \
    --argjson add_to_wallet "$add_to_wallet" \
    '{
      fee_rate: 1,
      add_to_wallet: $add_to_wallet,
      change_address: $change_address,
      active_chain_precondition: {
        blockhash: $block_hash,
        min_confirmations: $min_confirmations
      }
    }'
}

acp_prepare_wallet_context() {
  local recipient_wallet observer_wallet

  ACP_WALLET=$(_default_wallet)
  recipient_wallet=$(_wallet_for_node "$ACP_RECIPIENT_NODE")
  observer_wallet=$(_wallet_for_node "$ACP_OBSERVER_NODE")

  wait_for_spendable_balance "$ACP_WALLET" 2 90
  ACP_RECIPIENT_ADDRESS=$(acp_remote_wallet_rpc "$ACP_RECIPIENT_NODE" "$recipient_wallet" \
    getnewaddress "acp-s${SCENARIO_ID}-recipient" bech32)
  ACP_MINING_ADDRESS=$(acp_remote_wallet_rpc "$ACP_OBSERVER_NODE" "$observer_wallet" \
    getnewaddress "acp-s${SCENARIO_ID}-mining" bech32)
  ACP_FORK_MINING_ADDRESS=$(acp_remote_wallet_rpc "$ACP_OBSERVER_NODE" "$observer_wallet" \
    getnewaddress "acp-s${SCENARIO_ID}-fork-mining" bech32)
  ACP_CHANGE_ADDRESS=$(acp_wallet_rpc "$ACP_WALLET" getrawchangeaddress bech32)
  ACP_SEND_OUTPUTS=$(jq -cn --arg address "$ACP_RECIPIENT_ADDRESS" '{($address): 0.5}')
}

acp_isolate_fork_node() {
  local attempt

  acp_remote_rpc "$ACP_FORK_NODE" setnetworkactive false >/dev/null
  for ((attempt = 1; attempt <= 100; attempt++)); do
    [[ "$(acp_remote_rpc "$ACP_FORK_NODE" getconnectioncount)" == "0" ]] && return 0
    sleep 0.1
  done
  acp_log fixture "fork node did not become isolated"
  return 1
}

acp_reconnect_fork_node() {
  local attempt connections

  acp_remote_rpc "$ACP_FORK_NODE" setnetworkactive true >/dev/null
  for ((attempt = 1; attempt <= 150; attempt++)); do
    connections=$(acp_remote_rpc "$ACP_FORK_NODE" getconnectioncount 2>/dev/null || printf '0')
    (( connections >= 1 )) && return 0
    sleep 0.2
  done
  acp_log fixture "fork node did not reconnect after setnetworkactive true"
  return 1
}

acp_validate_chain() {
  [[ "$(acp_rpc verifychain 4 0)" == "true" ]]
}

acp_finish_orchestrator() {
  local scenario_name=$1
  local terminal_height=$2
  local final_tip

  acp_reconnect_fork_node
  acp_wait_for_common_tip 90
  final_tip=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  acp_wait_for_all_tips "$final_tip" 90
  [[ "$(bitcoin_rpc getblockcount)" == "$terminal_height" ]] || {
    acp_log fixture \
      "unexpected terminal height actual=$(bitcoin_rpc getblockcount) expected=${terminal_height}"
    return 1
  }
  acp_validate_chain
  acp_log scenario \
    "scenario finished name=${scenario_name} terminal_height=${terminal_height} terminal_tip=${final_tip}"
}

acp_run_support() {
  local scenario_name=$1
  local terminal_height=$2
  local activity_start deadline local_height=unknown leader_height=unknown leader_tip local_tip

  acp_begin_scenario "$scenario_name"
  activity_start=$(acp_wait_for_activity_release)
  acp_wait_until_epoch "$activity_start"
  acp_log scenario \
    "support role active scenario=${SCENARIO_ID} name=${scenario_name} terminal_height=${terminal_height} leader=node01"

  deadline=$(( $(date +%s) + SCENARIO_DURATION_SECONDS + 240 ))
  while (( $(date +%s) <= deadline )); do
    leader_height=$(acp_remote_rpc node01 getblockcount 2>/dev/null || printf -- '-1')
    local_height=$(bitcoin_rpc getblockcount 2>/dev/null || printf -- '-1')
    if [[ "$leader_height" =~ ^[0-9]+$ && "$local_height" =~ ^[0-9]+$ ]] \
        && (( leader_height >= terminal_height && local_height >= terminal_height )); then
      leader_tip=$(acp_remote_rpc node01 getbestblockhash)
      local_tip=$(bitcoin_rpc getbestblockhash)
      if [[ "$leader_tip" == "$local_tip" ]]; then
        acp_validate_chain
        acp_log scenario \
          "support role finished name=${scenario_name} node=${NODE_NAME} terminal_height=${local_height} terminal_tip=${local_tip}"
        return 0
      fi
    fi
    sleep 1
  done

  acp_log fixture \
    "support timed out scenario=${SCENARIO_ID} node=${NODE_NAME} local_height=${local_height} leader_height=${leader_height}"
  return 1
}

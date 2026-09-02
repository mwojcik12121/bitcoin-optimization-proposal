#!/usr/bin/env bash

BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
RPC_PORT=${RPC_PORT:-38332}
ACTIVE_NODES=${ACTIVE_NODES:-}

_info_btc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=15 \
    "$@"
}

_info_remote() {
  local node=$1
  shift
  bitcoin-cli \
    -rpcconnect="$node" \
    -rpcport="$RPC_PORT" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=5 \
    "$@"
}

wait_for_peer_count() {
  local minimum_peers=$1
  local timeout_seconds=${2:-180}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local current

  while (( $(date +%s) <= deadline )); do
    current=$(_info_btc getconnectioncount 2>/dev/null || printf '0')
    if (( current >= minimum_peers )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_regular_peer_count() {
  local minimum_peers=$1
  local timeout_seconds=${2:-60}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local current

  while (( $(date +%s) <= deadline )); do
    current=$(
      _info_btc getpeerinfo 2>/dev/null \
        | jq '[.[] | select(.subver != "/bitcoin-env-invalid-block:1.0/")] | length' \
        || printf '0'
    )
    if (( current >= minimum_peers )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_common_tip() {
  local timeout_seconds=${1:-60}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local local_tip peer remote_tip all_match
  local -a active_nodes=()

  IFS=',' read -r -a active_nodes <<< "$ACTIVE_NODES"
  while (( $(date +%s) <= deadline )); do
    local_tip=$(_info_btc getbestblockhash 2>/dev/null || true)
    all_match=1
    [[ "$local_tip" =~ ^[0-9a-f]{64}$ ]] || all_match=0
    for peer in "${active_nodes[@]}"; do
      [[ "$peer" != "${NODE_NAME:-}" ]] || continue
      remote_tip=$(_info_remote "$peer" getbestblockhash 2>/dev/null || true)
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

wait_until_epoch() {
  local epoch=$1
  local now

  while :; do
    now=$(date +%s)
    (( now >= epoch )) && return 0
    sleep 1
  done
}

assert_initial_state() {
  local state_file=/run/bitcoin-env/initial-state.env
  local expected_hash actual_hash height recorded_height recorded_chain local_chain

  [[ -r "$state_file" ]] || return 1
  recorded_chain=$(awk -F= '$1 == "CHAIN" {print $2; exit}' "$state_file")
  recorded_height=$(awk -F= '$1 == "HEIGHT" {print $2; exit}' "$state_file")
  expected_hash=$(awk -F= '$1 == "TIP_HASH" {print $2; exit}' "$state_file")
  height=$(_info_btc getblockcount)
  local_chain=$(_info_btc getblockchaininfo | jq -r '.chain // empty')

  [[ "$recorded_chain" == "signet" && "$local_chain" == "signet" ]] || return 1
  [[ "$recorded_height" == "200" ]] || return 1
  (( height >= 200 )) || return 1
  actual_hash=$(_info_btc getblockhash 200)
  [[ -n "$expected_hash" && "$actual_hash" == "$expected_hash" ]]
}

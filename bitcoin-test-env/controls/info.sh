#!/usr/bin/env bash

NODE_ID=${NODE_ID:-unknown}
NODE_NAME=${NODE_NAME:-node${NODE_ID}}
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
    "$@"
}

_info_btc_wallet() {
  local wallet=$1
  shift
  _info_btc -rpcwallet="$wallet" "$@"
}

_info_remote() {
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

block_height() {
  _info_btc getblockcount
}

best_block_hash() {
  _info_btc getbestblockhash
}

block_hash_at_height() {
  local height=$1
  _info_btc getblockhash "$height"
}

last_block() {
  local hash
  hash=$(_info_btc getbestblockhash)
  _info_btc getblock "$hash" 2
}

block_at_height() {
  local height=$1
  local verbosity=${2:-2}
  local hash
  hash=$(_info_btc getblockhash "$height")
  _info_btc getblock "$hash" "$verbosity"
}

show_blockchain_state() {
  _info_btc getblockchaininfo | jq '{chain, blocks, headers, bestblockhash, difficulty, mediantime, verificationprogress, initialblockdownload, size_on_disk, pruned, warnings}'
}

show_last_block() {
  last_block | jq '{hash, confirmations, height, versionHex, merkleroot, time, mediantime, nonce, bits, difficulty, nTx, previousblockhash, nextblockhash}'
}

show_chain_tips() {
  _info_btc getchaintips | jq '.'
}

show_mempool_state() {
  _info_btc getmempoolinfo | jq '.'
}

show_mempool_transactions() {
  _info_btc getrawmempool true | jq '.'
}

peer_count() {
  _info_btc getconnectioncount
}

show_peer_state() {
  _info_btc getpeerinfo | jq 'map({id, addr, addrbind, network, servicesnames, relaytxes, lastsend, lastrecv, bytessent, bytesrecv, conntime, pingtime, minping, synced_headers, synced_blocks, inflight, connection_type, permissions})'
}

log_peer_connections() {
  local stage=${1:-current}
  local node ip peer_json row address inbound connection_type peer_ip peer_name direction
  local -a nodes=() peer_rows=()
  declare -A node_by_ip=()

  IFS=',' read -r -a nodes <<< "$ACTIVE_NODES"
  for node in "${nodes[@]}"; do
    [[ "$node" =~ ^node0[1-8]$ ]] || continue
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && node_by_ip["$ip"]=$node
    done < <(getent ahostsv4 "$node" 2>/dev/null | awk '{print $1}' | sort -u)
  done

  peer_json=$(_info_btc getpeerinfo)
  mapfile -t peer_rows < <(
    jq -r \
      '.[] | [(.addr // ""), ((.inbound // false) | tostring), (.connection_type // "unknown")] | @tsv' \
      <<< "$peer_json" | sort -u
  )

  if [[ ${#peer_rows[@]} -eq 0 ]]; then
    printf '%s [%s][peers] stage=%s connected_to=none\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE_NAME" "$stage" >&2
    return 0
  fi

  for row in "${peer_rows[@]}"; do
    IFS=$'\t' read -r address inbound connection_type <<< "$row"
    peer_ip=${address%:*}
    peer_name=${node_by_ip[$peer_ip]:-$peer_ip}
    direction=outbound
    [[ "$inbound" == "true" ]] && direction=inbound
    printf '%s [%s][peers] stage=%s connected_to=%s address=%s direction=%s type=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE_NAME" "$stage" \
      "$peer_name" "$address" "$direction" "$connection_type" >&2
  done
}

show_network_state() {
  _info_btc getnetworkinfo | jq '{version, subversion, protocolversion, localservicesnames, localrelay, timeoffset, networkactive, connections, connections_in, connections_out, networks, relayfee, incrementalfee, warnings}'
}

show_wallet_state() {
  local wallet=$1
  _info_btc_wallet "$wallet" getwalletinfo | jq '.'
}

wallet_balance() {
  local wallet=$1
  _info_btc_wallet "$wallet" getbalance
}

show_wallet_balances() {
  local wallet=$1
  _info_btc_wallet "$wallet" getbalances | jq '.'
}

show_transaction() {
  local txid=$1
  _info_btc getrawtransaction "$txid" true | jq '.'
}

show_wallet_transaction() {
  local txid=$1
  local wallet=$2
  _info_btc_wallet "$wallet" gettransaction "$txid" true true | jq '.'
}

show_utxo_set_state() {
  _info_btc gettxoutsetinfo | jq '.'
}

show_index_state() {
  _info_btc getindexinfo | jq '.'
}

show_initial_state() {
  local state_file=/run/bitcoin-env/initial-state.env
  local key value
  local chain= height= tip= nodes= mined_from= mined_to= mined_blocks= wallet=

  [[ -r "$state_file" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      CHAIN) chain=$value ;;
      HEIGHT) height=$value ;;
      TIP_HASH) tip=$value ;;
      ACTIVE_NODE_COUNT) nodes=$value ;;
      MINED_FROM) mined_from=$value ;;
      MINED_TO) mined_to=$value ;;
      MINED_BLOCKS) mined_blocks=$value ;;
      WALLET) wallet=$value ;;
    esac
  done < "$state_file"

  jq -n \
    --arg chain "$chain" \
    --argjson height "$height" \
    --arg tip_hash "$tip" \
    --argjson active_nodes "$nodes" \
    --arg mining_range "${mined_from}-${mined_to}" \
    --argjson mined_blocks "$mined_blocks" \
    --arg wallet "$wallet" \
    '{chain:$chain,height:$height,tip_hash:$tip_hash,active_nodes:$active_nodes,local_mining_range:$mining_range,local_mined_blocks:$mined_blocks,wallet:$wallet}'
}

initial_chain_hash() {
  local state_file=/run/bitcoin-env/initial-state.env
  [[ -r "$state_file" ]] || return 1
  awk -F= '$1 == "TIP_HASH" {print $2; exit}' "$state_file"
}

show_node_resources() {
  local memory_current=unknown memory_max=unknown cpu_stat='{}' filesystem
  [[ -r /sys/fs/cgroup/memory.current ]] && memory_current=$(cat /sys/fs/cgroup/memory.current)
  [[ -r /sys/fs/cgroup/memory.max ]] && memory_max=$(cat /sys/fs/cgroup/memory.max)
  if [[ -r /sys/fs/cgroup/cpu.stat ]]; then
    cpu_stat=$(awk '{printf "%s\"%s\":%s", sep, $1, $2; sep=","}' /sys/fs/cgroup/cpu.stat)
    cpu_stat="{${cpu_stat}}"
  fi
  filesystem=$(df -P -B1 "$BITCOIN_DATADIR" | awk 'NR==2 {print $2":"$3":"$4":"$5}')
  jq -n \
    --arg node "$NODE_NAME" \
    --arg memory_current "$memory_current" \
    --arg memory_max "$memory_max" \
    --argjson cpu "$cpu_stat" \
    --arg filesystem "$filesystem" \
    '{node:$node, memory_bytes:{current:$memory_current,max:$memory_max}, cpu:$cpu, filesystem_bytes:$filesystem}'
}

remote_block_height() {
  local node=$1
  _info_remote "$node" getblockcount
}

remote_best_block_hash() {
  local node=$1
  _info_remote "$node" getbestblockhash
}

wait_for_node_rpc() {
  local node=$1
  local timeout_seconds=${2:-120}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while (( $(date +%s) <= deadline )); do
    if _info_remote "$node" getblockcount >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_height() {
  local target_height=$1
  local timeout_seconds=${2:-180}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local current
  while (( $(date +%s) <= deadline )); do
    current=$(_info_btc getblockcount 2>/dev/null || printf '0')
    if (( current >= target_height )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_exact_height() {
  local target_height=$1
  local timeout_seconds=${2:-180}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local current
  while (( $(date +%s) <= deadline )); do
    current=$(_info_btc getblockcount 2>/dev/null || printf -- '-1')
    if (( current == target_height )); then
      return 0
    fi
    if (( current > target_height )); then
      return 1
    fi
    sleep 1
  done
  return 1
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

wait_for_tx_in_mempool() {
  local txid=$1
  local timeout_seconds=${2:-120}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while (( $(date +%s) <= deadline )); do
    if _info_btc getmempoolentry "$txid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_tx_confirmations() {
  local txid=$1
  local required_confirmations=${2:-1}
  local timeout_seconds=${3:-180}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local confirmations
  while (( $(date +%s) <= deadline )); do
    confirmations=$(_info_btc getrawtransaction "$txid" true 2>/dev/null | jq -r '.confirmations // 0' || printf '0')
    if (( confirmations >= required_confirmations )); then
      return 0
    fi
    sleep 1
  done
  return 1
}

compare_tip_with_node() {
  local node=$1
  local local_tip remote_tip
  local_tip=$(_info_btc getbestblockhash)
  remote_tip=$(_info_remote "$node" getbestblockhash)
  [[ "$local_tip" == "$remote_tip" ]]
}

wait_for_same_tip() {
  local node=$1
  local timeout_seconds=${2:-180}
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while (( $(date +%s) <= deadline )); do
    if compare_tip_with_node "$node" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_until_epoch() {
  local epoch=$1
  local now
  while :; do
    now=$(date +%s)
    (( now >= epoch )) && break
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

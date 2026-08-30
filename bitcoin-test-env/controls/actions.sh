#!/usr/bin/env bash

NODE_ID=${NODE_ID:-unknown}
NODE_NAME=${NODE_NAME:-node${NODE_ID}}
BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
RPC_PORT=${RPC_PORT:-38332}
P2P_PORT=${P2P_PORT:-38333}

_btc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    "$@"
}

_btc_wallet() {
  local wallet=$1
  shift
  _btc -rpcwallet="$wallet" "$@"
}

_btc_remote() {
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

_btc_remote_wallet() {
  local node=$1
  local wallet=$2
  shift 2
  _btc_remote "$node" -rpcwallet="$wallet" "$@"
}

_wallet_is_loaded() {
  local wallet=$1
  _btc listwallets | jq -e --arg wallet "$wallet" 'index($wallet) != null' >/dev/null
}

_wallet_exists() {
  local wallet=$1
  _btc listwalletdir | jq -e --arg wallet "$wallet" '.wallets | any(.name == $wallet)' >/dev/null
}

_default_wallet() {
  case "$NODE_ID" in
    01) printf 'wallet01\n' ;;
    05) printf 'wallet05\n' ;;
    *) printf 'wallet-%s\n' "$NODE_NAME" ;;
  esac
}

bitcoin_rpc() {
  _btc "$@"
}

remote_bitcoin_rpc() {
  local node=$1
  shift
  _btc_remote "$node" "$@"
}

create_wallet() {
  local wallet=${1:-$(_default_wallet)}
  if _wallet_is_loaded "$wallet"; then
    return 0
  fi
  if _wallet_exists "$wallet"; then
    _btc loadwallet "$wallet" >/dev/null
  else
    _btc createwallet "$wallet" >/dev/null
  fi
}

create_remote_wallet() {
  local node=$1
  local wallet=$2
  local loaded
  loaded=$(_btc_remote "$node" listwallets)
  if jq -e --arg wallet "$wallet" 'index($wallet) != null' <<<"$loaded" >/dev/null; then
    return 0
  fi
  if _btc_remote "$node" listwalletdir | jq -e --arg wallet "$wallet" '.wallets | any(.name == $wallet)' >/dev/null; then
    _btc_remote "$node" loadwallet "$wallet" >/dev/null
  else
    _btc_remote "$node" createwallet "$wallet" >/dev/null
  fi
}

load_wallet() {
  local wallet=$1
  _btc loadwallet "$wallet"
}

unload_wallet() {
  local wallet=$1
  _btc unloadwallet "$wallet"
}

new_address() {
  local wallet=${1:-$(_default_wallet)}
  local label=${2:-scenario-${SCENARIO_ID:-manual}}
  local address_type=${3:-bech32}
  create_wallet "$wallet"
  _btc_wallet "$wallet" getnewaddress "$label" "$address_type"
}

remote_new_address() {
  local node=$1
  local wallet=$2
  local label=${3:-from-${NODE_NAME}}
  local address_type=${4:-bech32}
  create_remote_wallet "$node" "$wallet"
  _btc_remote_wallet "$node" "$wallet" getnewaddress "$label" "$address_type"
}

send_to_address() {
  local address=$1
  local amount=$2
  local wallet=${3:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" sendtoaddress "$address" "$amount"
}

send_to_node() {
  local target_node=$1
  local amount=$2
  local source_wallet=${3:-$(_default_wallet)}
  local target_wallet=${4:-wallet-${target_node}}
  local address
  address=$(remote_new_address "$target_node" "$target_wallet" "payment-from-${NODE_NAME}")
  send_to_address "$address" "$amount" "$source_wallet"
}

create_raw_transaction() {
  local inputs_json=$1
  local outputs_json=$2
  local locktime=${3:-0}
  _btc createrawtransaction "$inputs_json" "$outputs_json" "$locktime"
}

fund_raw_transaction() {
  local raw_hex=$1
  local wallet=${2:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" fundrawtransaction "$raw_hex"
}

sign_raw_transaction() {
  local raw_hex=$1
  local wallet=${2:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" signrawtransactionwithwallet "$raw_hex"
}

broadcast_raw_transaction() {
  local raw_hex=$1
  _btc sendrawtransaction "$raw_hex"
}

test_transaction_acceptance() {
  local raw_hex=$1
  _btc testmempoolaccept "[\"${raw_hex}\"]"
}

decode_raw_transaction() {
  local raw_hex=$1
  _btc decoderawtransaction "$raw_hex"
}

create_funded_psbt() {
  local address=$1
  local amount=$2
  local wallet=${3:-$(_default_wallet)}
  local outputs
  create_wallet "$wallet"
  outputs=$(jq -cn --arg address "$address" --argjson amount "$amount" '[{($address): $amount}]')
  _btc_wallet "$wallet" walletcreatefundedpsbt '[]' "$outputs" 0 '{"replaceable":true}' true
}

sign_psbt() {
  local psbt=$1
  local wallet=${2:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" walletprocesspsbt "$psbt"
}

finalize_psbt() {
  local psbt=$1
  _btc finalizepsbt "$psbt"
}

send_psbt_to_address() {
  local address=$1
  local amount=$2
  local wallet=${3:-$(_default_wallet)}
  local funded signed finalized raw_hex
  funded=$(create_funded_psbt "$address" "$amount" "$wallet")
  signed=$(sign_psbt "$(jq -r '.psbt' <<<"$funded")" "$wallet")
  finalized=$(finalize_psbt "$(jq -r '.psbt' <<<"$signed")")
  raw_hex=$(jq -r '.hex // empty' <<<"$finalized")
  if [[ -z "$raw_hex" ]]; then
    return 1
  fi
  broadcast_raw_transaction "$raw_hex"
}

bump_transaction_fee() {
  local txid=$1
  local wallet=${2:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" bumpfee "$txid"
}

abandon_transaction() {
  local txid=$1
  local wallet=${2:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" abandontransaction "$txid"
}

lock_utxo() {
  local txid=$1
  local vout=$2
  local wallet=${3:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" lockunspent false "[{\"txid\":\"${txid}\",\"vout\":${vout}}]"
}

unlock_all_utxos() {
  local wallet=${1:-$(_default_wallet)}
  create_wallet "$wallet"
  _btc_wallet "$wallet" lockunspent true
}

prioritise_transaction() {
  local txid=$1
  local fee_delta_sats=$2
  _btc prioritisetransaction "$txid" 0 "$fee_delta_sats"
}

_mine_one_to_address() {
  local address=$1
  local hash_result block_hash

  hash_result=$(_btc generatetoaddress 1 "$address" 100000000)
  block_hash=$(jq -r 'if type == "array" and length == 1 then .[0] else empty end' <<<"$hash_result")
  if [[ ! "$block_hash" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'Bitcoin Core returned no valid block hash.\n' >&2
    return 1
  fi

  printf '%s\n' "$block_hash"
}

mine_blocks() {
  local count=$1
  local wallet=${2:-$(_default_wallet)}
  local address block_hash index

  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    printf 'Block count must be a non-negative integer: %s\n' "$count" >&2
    return 2
  fi
  if [[ "$count" == "0" ]]; then
    _btc getbestblockhash
    return 0
  fi

  create_wallet "$wallet"
  address=$(new_address "$wallet" "mining-${NODE_NAME}")
  for ((index = 1; index <= count; index++)); do
    block_hash=$(_mine_one_to_address "$address")
  done
  printf '%s\n' "$block_hash"
}

mine_blocks_until_epoch() {
  local end_epoch=$1
  local interval_seconds=$2
  local wallet=${3:-$(_default_wallet)}
  local initial_delay=${4:-0}
  local address

  [[ "$end_epoch" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$interval_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2
  [[ "$initial_delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2

  create_wallet "$wallet"
  address=$(new_address "$wallet" "scenario-mining-${NODE_NAME}")
  sleep "$initial_delay"
  while (( $(date +%s) < end_epoch )); do
    _mine_one_to_address "$address" >/dev/null
    sleep "$interval_seconds"
  done
}

mine_blocks_at_offsets() {
  local start_epoch=$1
  local offsets_csv=$2
  local wallet=${3:-$(_default_wallet)}
  local offset target_epoch now previous_offset=-1 address block_hash
  local -a offsets=()

  [[ "$start_epoch" =~ ^[1-9][0-9]*$ ]] || return 2
  IFS=',' read -r -a offsets <<< "$offsets_csv"
  (( ${#offsets[@]} > 0 )) || return 2

  create_wallet "$wallet"
  address=$(new_address "$wallet" "scheduled-mining-${NODE_NAME}")
  for offset in "${offsets[@]}"; do
    [[ "$offset" =~ ^[0-9]+$ ]] || return 2
    (( offset > previous_offset )) || return 2
    previous_offset=$offset
    target_epoch=$((start_epoch + offset))
    while :; do
      now=$(date +%s)
      (( now >= target_epoch )) && break
      sleep 0.2
    done
    block_hash=$(_mine_one_to_address "$address")
  done
  printf '%s\n' "$block_hash"
}

generate_transactions_until_epoch() {
  local end_epoch=$1
  local wallet=$2
  local target_nodes_csv=$3
  local amount=${4:-0.001}
  local interval_seconds=${5:-2}
  local target address txid counter=0 successful_transactions=0
  local -a target_nodes=()

  [[ "$end_epoch" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$interval_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2
  IFS=',' read -r -a target_nodes <<< "$target_nodes_csv"
  (( ${#target_nodes[@]} > 0 )) || return 2

  create_wallet "$wallet"
  while (( $(date +%s) < end_epoch )); do
    target=${target_nodes[$((counter % ${#target_nodes[@]}))]}
    if address=$(remote_new_address "$target" "wallet-${target}" "scenario${SCENARIO_ID:-0}-from-${NODE_NAME}-${counter}" 2>/dev/null); then
      if txid=$(send_to_address "$address" "$amount" "$wallet" 2>/dev/null) \
          && [[ "$txid" =~ ^[0-9a-f]{64}$ ]]; then
        successful_transactions=$((successful_transactions + 1))
      fi
    fi
    counter=$((counter + 1))
    sleep "$interval_seconds"
  done

  (( successful_transactions > 0 ))
}

mine_one_block() {
  local wallet=${1:-$(_default_wallet)}
  mine_blocks 1 "$wallet"
}

validate_chain() {
  local check_level=${1:-4}
  local block_count=${2:-0}
  local result
  result=$(_btc verifychain "$check_level" "$block_count")
  printf '%s\n' "$result"
  [[ "$result" == "true" ]]
}

invalidate_block() {
  local block_hash=$1
  _btc invalidateblock "$block_hash"
}

invalidate_tip() {
  local block_hash
  block_hash=$(_btc getbestblockhash)
  _btc invalidateblock "$block_hash"
  printf '%s\n' "$block_hash"
}

reconsider_block() {
  local block_hash=$1
  _btc reconsiderblock "$block_hash"
}

mark_block_precious() {
  local block_hash=$1
  _btc preciousblock "$block_hash"
}

rescan_wallet() {
  local wallet=${1:-$(_default_wallet)}
  local start_height=${2:-0}
  local stop_height=${3:-}
  create_wallet "$wallet"
  if [[ -n "$stop_height" ]]; then
    _btc_wallet "$wallet" rescanblockchain "$start_height" "$stop_height"
  else
    _btc_wallet "$wallet" rescanblockchain "$start_height"
  fi
}

submit_block() {
  local block_hex=$1
  _btc submitblock "$block_hex"
}

submit_header() {
  local header_hex=$1
  _btc submitheader "$header_hex"
}

connect_peer() {
  local peer=$1
  _btc addnode "${peer}:${P2P_PORT}" onetry
}

disconnect_peer() {
  local peer=$1
  local ip
  ip=$(getent ahostsv4 "$peer" | awk 'NR == 1 {print $1}')
  _btc disconnectnode "${ip:-$peer}:${P2P_PORT}" || _btc disconnectnode "${peer}:${P2P_PORT}"
}

stop_node() {
  _btc stop
}

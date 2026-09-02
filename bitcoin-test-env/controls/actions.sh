#!/usr/bin/env bash

NODE_ID=${NODE_ID:-unknown}
NODE_NAME=${NODE_NAME:-node${NODE_ID}}
BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
RPC_PORT=${RPC_PORT:-38332}
MINING_LOCK_FILE=${MINING_LOCK_FILE:-/run/bitcoin-env/mining.lock}

_btc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=15 \
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
    -rpcclienttimeout=5 \
    "$@"
}

_wallet_for_node() {
  local node=$1
  if [[ ! "$node" =~ ^node0[1-8]$ ]]; then
    printf 'Invalid node name: %s\n' "$node" >&2
    return 2
  fi
  printf 'wallet-%s\n' "$node"
}

_default_wallet() {
  _wallet_for_node "$NODE_NAME"
}

bitcoin_rpc() {
  _btc "$@"
}

create_wallet() {
  local wallet=${1:-$(_default_wallet)}

  if _btc listwallets | jq -e --arg wallet "$wallet" 'index($wallet) != null' >/dev/null; then
    return 0
  fi
  if _btc listwalletdir | jq -e --arg wallet "$wallet" '.wallets | any(.name == $wallet)' >/dev/null; then
    _btc loadwallet "$wallet" >/dev/null
  else
    _btc createwallet "$wallet" >/dev/null
  fi
}

new_address() {
  local wallet=${1:-$(_default_wallet)}
  local label=${2:-scenario-${SCENARIO_ID:-manual}}

  create_wallet "$wallet"
  _btc_wallet "$wallet" getnewaddress "$label" bech32
}

remote_new_address() {
  local node=$1
  local label=${2:-from-${NODE_NAME}}
  local wallet

  wallet=$(_wallet_for_node "$node")
  _btc_remote "$node" -rpcwallet="$wallet" getnewaddress "$label" bech32
}

send_to_address() {
  local address=$1
  local amount=$2
  local wallet=${3:-$(_default_wallet)}

  create_wallet "$wallet"
  _btc_wallet "$wallet" sendtoaddress "$address" "$amount"
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

_mine_blocks_unlocked() {
  local count=$1
  local wallet=$2
  local address block_hash index

  create_wallet "$wallet"
  address=$(new_address "$wallet" "mining-${NODE_NAME}")
  for ((index = 1; index <= count; index++)); do
    block_hash=$(_mine_one_to_address "$address")
  done
  printf '%s\n' "$block_hash"
}

mine_blocks() {
  local count=$1
  local wallet=${2:-$(_default_wallet)}

  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Block count must be a positive integer: %s\n' "$count" >&2
    return 2
  fi
  {
    flock -x 9
    _mine_blocks_unlocked "$count" "$wallet"
  } 9>"$MINING_LOCK_FILE"
}

wait_for_spendable_balance() {
  local wallet=${1:-$(_default_wallet)}
  local minimum=${2:-0.5}
  local timeout_seconds=${3:-60}
  local deadline=$(( $(date +%s) + timeout_seconds ))

  create_wallet "$wallet"
  while (( $(date +%s) <= deadline )); do
    if _btc_wallet "$wallet" getbalances 2>/dev/null \
        | jq -e --argjson minimum "$minimum" '.mine.trusted >= $minimum' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

validate_chain() {
  [[ "$(_btc verifychain 4 0)" == "true" ]]
}

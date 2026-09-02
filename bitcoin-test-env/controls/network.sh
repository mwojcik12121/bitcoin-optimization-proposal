#!/usr/bin/env bash

BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
NETWORK_INTERFACE=${NETWORK_INTERFACE:-eth0}
BTC_ENV_OUT_CHAIN=BTC_ENV_OUT
BTC_ENV_IN_CHAIN=BTC_ENV_IN

_network_btc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
    -rpcclienttimeout=15 \
    "$@"
}

_network_require_admin() {
  if [[ $(id -u) -ne 0 ]]; then
    printf 'Network fault functions must run as root inside the container.\n' >&2
    return 1
  fi
  command -v tc >/dev/null || {
    printf 'tc is unavailable.\n' >&2
    return 1
  }
  command -v iptables >/dev/null || {
    printf 'iptables is unavailable.\n' >&2
    return 1
  }
}

_network_setup_firewall() {
  _network_require_admin
  iptables -w 5 -N "$BTC_ENV_OUT_CHAIN" >/dev/null 2>&1 || true
  iptables -w 5 -N "$BTC_ENV_IN_CHAIN" >/dev/null 2>&1 || true
  iptables -w 5 -C OUTPUT -j "$BTC_ENV_OUT_CHAIN" >/dev/null 2>&1 \
    || iptables -w 5 -I OUTPUT 1 -j "$BTC_ENV_OUT_CHAIN"
  iptables -w 5 -C INPUT -j "$BTC_ENV_IN_CHAIN" >/dev/null 2>&1 \
    || iptables -w 5 -I INPUT 1 -j "$BTC_ENV_IN_CHAIN"
}

network_impair() {
  local delay_ms=${1:-900}
  local jitter_ms=${2:-250}
  local loss_percent=${3:-4}
  local rate=${4:-2mbit}

  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem \
    delay "${delay_ms}ms" "${jitter_ms}ms" \
    loss "${loss_percent}%" rate "$rate"
}

network_clear_impairment() {
  _network_require_admin
  tc qdisc del dev "$NETWORK_INTERFACE" root >/dev/null 2>&1 || true
}

network_blackout() {
  _network_setup_firewall
  iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP
  iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP
}

network_restore() {
  _network_setup_firewall
  tc qdisc del dev "$NETWORK_INTERFACE" root >/dev/null 2>&1 || true
  iptables -w 5 -F "$BTC_ENV_OUT_CHAIN" >/dev/null 2>&1 || true
  iptables -w 5 -F "$BTC_ENV_IN_CHAIN" >/dev/null 2>&1 || true
  _network_btc setnetworkactive true >/dev/null 2>&1 || true
}

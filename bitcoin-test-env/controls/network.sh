#!/usr/bin/env bash

NODE_ID=${NODE_ID:-unknown}
NODE_NAME=${NODE_NAME:-node${NODE_ID}}
BITCOIN_DATADIR=${BITCOIN_DATADIR:-/data}
RPC_USER=${RPC_USER:-bitcoinenv}
RPC_PASSWORD=${RPC_PASSWORD:-bitcoinenv-internal-only}
P2P_PORT=${P2P_PORT:-38333}
NETWORK_INTERFACE=${NETWORK_INTERFACE:-eth0}
BTC_ENV_OUT_CHAIN=BTC_ENV_OUT
BTC_ENV_IN_CHAIN=BTC_ENV_IN

_network_btc() {
  bitcoin-cli \
    -datadir="$BITCOIN_DATADIR" \
    -conf="$BITCOIN_DATADIR/bitcoin.conf" \
    -rpcuser="$RPC_USER" \
    -rpcpassword="$RPC_PASSWORD" \
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

_network_peer_ip() {
  local peer=$1
  getent ahostsv4 "$peer" | awk 'NR == 1 {print $1}'
}

_network_remove_blackout() {
  _network_setup_firewall
  while iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP
  done
  while iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP
  done
}

network_delay() {
  local delay_ms=$1
  local jitter_ms=${2:-0}
  local correlation=${3:-0}
  _network_require_admin
  if [[ "$jitter_ms" == "0" ]]; then
    tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${delay_ms}ms"
  else
    tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${delay_ms}ms" "${jitter_ms}ms" "${correlation}%"
  fi
}

network_latency() {
  local latency_ms=$1
  network_delay "$latency_ms" 0 0
}

network_loss() {
  local percent=$1
  local correlation=${2:-0}
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem loss "${percent}%" "${correlation}%"
}

network_duplicate() {
  local percent=$1
  local correlation=${2:-0}
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem duplicate "${percent}%" "${correlation}%"
}

network_corrupt() {
  local percent=$1
  local correlation=${2:-0}
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem corrupt "${percent}%" "${correlation}%"
}

network_reorder() {
  local percent=$1
  local correlation=${2:-0}
  local base_delay_ms=${3:-10}
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${base_delay_ms}ms" reorder "${percent}%" "${correlation}%"
}

network_rate_limit() {
  local rate=$1
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem rate "$rate"
}

network_impair() {
  local delay_ms=${1:-0}
  local jitter_ms=${2:-0}
  local loss_percent=${3:-0}
  local rate=${4:-}
  local args=(qdisc replace dev "$NETWORK_INTERFACE" root netem)

  _network_require_admin
  (( delay_ms > 0 )) && args+=(delay "${delay_ms}ms" "${jitter_ms}ms")
  [[ "$loss_percent" != "0" ]] && args+=(loss "${loss_percent}%")
  [[ -n "$rate" ]] && args+=(rate "$rate")
  tc "${args[@]}"
}

network_clear_impairment() {
  _network_require_admin
  tc qdisc del dev "$NETWORK_INTERFACE" root >/dev/null 2>&1 || true
}

network_partition_peer() {
  local peer=$1
  local ip peer_id

  _network_setup_firewall
  ip=$(_network_peer_ip "$peer")
  if [[ -z "$ip" ]]; then
    printf 'Could not resolve peer %s.\n' "$peer" >&2
    return 1
  fi
  iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP
  iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP

  while IFS= read -r peer_id; do
    [[ "$peer_id" =~ ^[0-9]+$ ]] || continue
    _network_btc disconnectnode "" "$peer_id" >/dev/null 2>&1 || true
  done < <(
    _network_btc getpeerinfo \
      | jq -r --arg ip "$ip" --arg peer "$peer" \
          '.[] | select((.addr | startswith($ip + ":")) or (.addr | startswith($peer + ":"))) | .id'
  )
}

network_heal_peer() {
  local peer=$1
  local ip

  _network_setup_firewall
  ip=$(_network_peer_ip "$peer")
  if [[ -z "$ip" ]]; then
    printf 'Could not resolve peer %s.\n' "$peer" >&2
    return 1
  fi
  while iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP
  done
  while iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP
  done
  _network_btc addnode "${peer}:${P2P_PORT}" onetry >/dev/null 2>&1 || true
}

network_partition_group() {
  local peer
  for peer in "$@"; do
    network_partition_peer "$peer"
  done
}

network_heal_group() {
  local peer
  for peer in "$@"; do
    network_heal_peer "$peer"
  done
}

network_isolate_from_active_nodes() {
  local peer
  local -a peers
  IFS=',' read -r -a peers <<< "${ACTIVE_NODES:-}"
  for peer in "${peers[@]}"; do
    [[ -n "$peer" && "$peer" != "$NODE_NAME" ]] || continue
    network_partition_peer "$peer"
  done
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

network_pause() {
  local seconds=$1
  network_blackout
  sleep "$seconds"
  _network_remove_blackout
}

network_flap_peer() {
  local peer=$1
  local cycles=${2:-3}
  local down_seconds=${3:-2}
  local up_seconds=${4:-2}
  local cycle

  for ((cycle = 1; cycle <= cycles; cycle++)); do
    network_partition_peer "$peer"
    sleep "$down_seconds"
    network_heal_peer "$peer"
    sleep "$up_seconds"
  done
}

network_set_active() {
  local active=$1
  _network_btc setnetworkactive "$active"
}

network_show_faults() {
  _network_require_admin
  _network_setup_firewall
  printf '%s\n' '--- tc qdisc ---'
  tc qdisc show dev "$NETWORK_INTERFACE"
  printf '%s\n' '--- iptables output faults ---'
  iptables -w 5 -S "$BTC_ENV_OUT_CHAIN"
  printf '%s\n' '--- iptables input faults ---'
  iptables -w 5 -S "$BTC_ENV_IN_CHAIN"
}

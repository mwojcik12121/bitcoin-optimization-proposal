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

_network_log() {
  printf '%s [%s][network] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE_NAME" "$*" >&2
}

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
    _network_log "Network fault functions must run as root inside the container"
    return 1
  fi
  command -v tc >/dev/null || { _network_log "tc is unavailable"; return 1; }
  command -v iptables >/dev/null || { _network_log "iptables is unavailable"; return 1; }
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

network_delay() {
  local delay_ms=$1
  local jitter_ms=${2:-0}
  local correlation=${3:-0}
  _network_log "Applying ${delay_ms}ms delay, ${jitter_ms}ms jitter, ${correlation}% correlation on ${NETWORK_INTERFACE}"
  _network_require_admin
  if [[ "$jitter_ms" == "0" ]]; then
    tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${delay_ms}ms"
  else
    tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${delay_ms}ms" "${jitter_ms}ms" "${correlation}%"
  fi
}

network_latency() {
  local latency_ms=$1
  _network_log "Applying ${latency_ms}ms one-way latency"
  network_delay "$latency_ms" 0 0
}

network_loss() {
  local percent=$1
  local correlation=${2:-0}
  _network_log "Applying ${percent}% packet loss with ${correlation}% correlation"
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem loss "${percent}%" "${correlation}%"
}

network_duplicate() {
  local percent=$1
  local correlation=${2:-0}
  _network_log "Duplicating ${percent}% of packets with ${correlation}% correlation"
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem duplicate "${percent}%" "${correlation}%"
}

network_corrupt() {
  local percent=$1
  local correlation=${2:-0}
  _network_log "Corrupting ${percent}% of packets with ${correlation}% correlation"
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem corrupt "${percent}%" "${correlation}%"
}

network_reorder() {
  local percent=$1
  local correlation=${2:-0}
  local base_delay_ms=${3:-10}
  _network_log "Reordering ${percent}% of packets with ${correlation}% correlation and ${base_delay_ms}ms base delay"
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem delay "${base_delay_ms}ms" reorder "${percent}%" "${correlation}%"
}

network_rate_limit() {
  local rate=$1
  _network_log "Limiting interface rate to ${rate}"
  _network_require_admin
  tc qdisc replace dev "$NETWORK_INTERFACE" root netem rate "$rate"
}

network_impair() {
  local delay_ms=${1:-0}
  local jitter_ms=${2:-0}
  local loss_percent=${3:-0}
  local rate=${4:-}
  local args=(qdisc replace dev "$NETWORK_INTERFACE" root netem)
  _network_log "Applying combined impairment: delay=${delay_ms}ms jitter=${jitter_ms}ms loss=${loss_percent}% rate=${rate:-unlimited}"
  _network_require_admin
  (( delay_ms > 0 )) && args+=(delay "${delay_ms}ms" "${jitter_ms}ms")
  [[ "$loss_percent" != "0" ]] && args+=(loss "${loss_percent}%")
  [[ -n "$rate" ]] && args+=(rate "$rate")
  tc "${args[@]}"
}

network_clear_impairment() {
  _network_log "Clearing traffic-control delay/loss/rate impairment"
  _network_require_admin
  tc qdisc del dev "$NETWORK_INTERFACE" root >/dev/null 2>&1 || true
}

network_partition_peer() {
  local peer=$1
  local ip peer_id
  _network_log "Partitioning this node from ${peer}"
  _network_setup_firewall
  ip=$(_network_peer_ip "$peer")
  if [[ -z "$ip" ]]; then
    _network_log "Could not resolve peer ${peer}"
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

  _network_log "Partition from ${peer} (${ip}) is active"
}

network_heal_peer() {
  local peer=$1
  local ip
  _network_log "Healing partition with ${peer}"
  _network_setup_firewall
  ip=$(_network_peer_ip "$peer")
  if [[ -z "$ip" ]]; then
    _network_log "Could not resolve peer ${peer}"
    return 1
  fi
  while iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_OUT_CHAIN" -d "$ip" -j DROP
  done
  while iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP >/dev/null 2>&1; do
    iptables -w 5 -D "$BTC_ENV_IN_CHAIN" -s "$ip" -j DROP
  done
  _network_btc addnode "${peer}:${P2P_PORT}" onetry >/dev/null 2>&1 || true
  _network_log "Traffic with ${peer} (${ip}) is restored"
}

network_partition_group() {
  local peer
  _network_log "Partitioning this node from peer group: $*"
  for peer in "$@"; do
    network_partition_peer "$peer"
  done
}

##
# @brief Heals this node's partition from every supplied peer and reconnects immediately.
# @param ... Peer node names to restore.
##
network_heal_group() {
  local peer
  _network_log "Healing partition with peer group: $*"
  for peer in "$@"; do
    network_heal_peer "$peer"
  done
}

network_isolate_from_active_nodes() {
  local peer
  local -a peers
  _network_log "Isolating this node from every other active node"
  IFS=',' read -r -a peers <<< "${ACTIVE_NODES:-}"
  for peer in "${peers[@]}"; do
    [[ -n "$peer" && "$peer" != "$NODE_NAME" ]] || continue
    network_partition_peer "$peer"
  done
}

network_blackout() {
  _network_log "Blocking all traffic on ${NETWORK_INTERFACE}"
  _network_setup_firewall
  iptables -w 5 -C "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_OUT_CHAIN" -o "$NETWORK_INTERFACE" -j DROP
  iptables -w 5 -C "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP >/dev/null 2>&1 \
    || iptables -w 5 -A "$BTC_ENV_IN_CHAIN" -i "$NETWORK_INTERFACE" -j DROP
}

network_restore() {
  _network_log "Restoring normal network behavior and removing all mock faults"
  _network_setup_firewall
  tc qdisc del dev "$NETWORK_INTERFACE" root >/dev/null 2>&1 || true
  iptables -w 5 -F "$BTC_ENV_OUT_CHAIN" >/dev/null 2>&1 || true
  iptables -w 5 -F "$BTC_ENV_IN_CHAIN" >/dev/null 2>&1 || true
  _network_btc setnetworkactive true >/dev/null 2>&1 || true
}

network_pause() {
  local seconds=$1
  _network_log "Pausing node networking for ${seconds}s"
  network_blackout
  sleep "$seconds"
  network_restore
}

network_flap_peer() {
  local peer=$1
  local cycles=${2:-3}
  local down_seconds=${3:-2}
  local up_seconds=${4:-2}
  local cycle
  _network_log "Flapping connection to ${peer} for ${cycles} cycle(s)"
  for ((cycle = 1; cycle <= cycles; cycle++)); do
    _network_log "Flap cycle ${cycle}/${cycles}: down"
    network_partition_peer "$peer"
    sleep "$down_seconds"
    _network_log "Flap cycle ${cycle}/${cycles}: up"
    network_heal_peer "$peer"
    sleep "$up_seconds"
  done
}

network_set_active() {
  local active=$1
  _network_log "Setting Bitcoin Core network-active state to ${active}"
  _network_btc setnetworkactive "$active"
}

network_show_faults() {
  _network_log "Showing current traffic-control and firewall fault configuration"
  _network_require_admin
  _network_setup_firewall
  printf '%s\n' '--- tc qdisc ---'
  tc qdisc show dev "$NETWORK_INTERFACE"
  printf '%s\n' '--- iptables output faults ---'
  iptables -w 5 -S "$BTC_ENV_OUT_CHAIN"
  printf '%s\n' '--- iptables input faults ---'
  iptables -w 5 -S "$BTC_ENV_IN_CHAIN"
}

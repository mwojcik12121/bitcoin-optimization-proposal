#!/usr/bin/env bash

_bitcoin_process_pid() {
  local pid=${BITCOIND_PID:-}

  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
    printf '%s\n' "$pid"
    return 0
  fi

  pid=$(pgrep -xo bitcoind 2>/dev/null || true)
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    printf 'Could not find the local bitcoind process.\n' >&2
    return 1
  fi

  printf '%s\n' "$pid"
}

suspend_node_for() {
  local seconds=$1
  local pid resume_pid

  if [[ ! "$seconds" =~ ^[0-9]+([.][0-9]+)?$ || "$seconds" =~ ^0+([.]0+)?$ ]]; then
    printf 'Suspension duration must be greater than zero: %s\n' "$seconds" >&2
    return 2
  fi

  pid=$(_bitcoin_process_pid)
  kill -STOP "$pid"
  (
    sleep "$seconds"
    kill -CONT "$pid" >/dev/null 2>&1 || true
  ) &
  resume_pid=$!
  wait "$resume_pid"
  kill -0 "$pid" >/dev/null 2>&1
}

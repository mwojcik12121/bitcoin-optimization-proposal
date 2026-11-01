#!/usr/bin/env bash

bitcoin_log_timestamp() {
  LC_ALL=C date -u '+%Y-%m-%dT%H:%M:%S.%6NZ'
}

bitcoin_log_token() {
  local value=${1:-test}
  value=${value//[^A-Za-z0-9_]/_}
  printf '%s' "${value:-test}"
}

test_log() {
  local severity=${1:-INFO}
  local component=${2:-test}
  local level node thread
  shift 2 || true

  case "${severity^^}" in
    TRACE) level=trace ;;
    DEBUG) level=debug ;;
    INFO) level=info ;;
    WARN|WARNING) level=warning ;;
    ERR|ERROR) level=error ;;
    *) level=info ;;
  esac

  node=$(bitcoin_log_token "${NODE_NAME:-runner}")
  component=$(bitcoin_log_token "$component")
  if [[ "$node" == "runner" ]]; then
    thread=$component
  else
    thread="${node}_${component}"
  fi

  printf '%s [%s] [test:%s] %s\n' \
    "$(bitcoin_log_timestamp)" \
    "$thread" \
    "$level" \
    "$*" >&2
}

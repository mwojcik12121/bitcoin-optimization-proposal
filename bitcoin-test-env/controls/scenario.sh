#!/usr/bin/env bash

source /controls/logging.sh
source /controls/actions.sh
source /controls/info.sh
source /controls/network.sh
source /controls/process.sh

SCENARIO_DURATION_SECONDS=${SCENARIO_DURATION_SECONDS:-180}
SCENARIO_WARMUP_SECONDS=${SCENARIO_WARMUP_SECONDS:-20}
INVALID_BLOCK_INTERVAL_SECONDS=${INVALID_BLOCK_INTERVAL_SECONDS:-60}
INVALID_BLOCK_INITIAL_DELAY_SECONDS=${INVALID_BLOCK_INITIAL_DELAY_SECONDS:-15}
SIGNET_CHALLENGE=${SIGNET_CHALLENGE:-51}
P2P_PORT=${P2P_PORT:-38333}

declare -a SCORING_TARGET_NODES=()
declare -a SCORING_TARGET_ADDRESSES=()

scenario_log() {
  local component=$1
  shift
  test_log INFO "$component" "$*"
}

_require_positive_integer() {
  local name=$1
  local value=$2
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s must be a positive integer: %s\n' "$name" "$value" >&2
    return 2
  fi
}

validate_scoring_scenario() {
  local requested_scenario=$1
  local all_nodes=node01,node02,node03,node04,node05,node06,node07,node08

  [[ "$requested_scenario" =~ ^[12]$ ]] || {
    printf 'Only scenarios 1 and 2 are supported.\n' >&2
    return 2
  }
  [[ "$SCENARIO_ID" == "$requested_scenario" ]] || {
    printf 'Scenario wrapper and SCENARIO_ID disagree: %s versus %s\n' \
      "$requested_scenario" "$SCENARIO_ID" >&2
    return 2
  }
  [[ "$ACTIVE_NODES" == "$all_nodes" ]] || {
    printf 'Scenario %s requires all eight nodes: %s\n' "$requested_scenario" "$ACTIVE_NODES" >&2
    return 2
  }
  _require_positive_integer SCENARIO_DURATION_SECONDS "$SCENARIO_DURATION_SECONDS"
  _require_positive_integer SCENARIO_WARMUP_SECONDS "$SCENARIO_WARMUP_SECONDS"
  _require_positive_integer INVALID_BLOCK_INTERVAL_SECONDS "$INVALID_BLOCK_INTERVAL_SECONDS"
  _require_positive_integer INVALID_BLOCK_INITIAL_DELAY_SECONDS "$INVALID_BLOCK_INITIAL_DELAY_SECONDS"
  if (( SCENARIO_DURATION_SECONDS < 60 )); then
    printf 'SCENARIO_DURATION_SECONDS must be at least 60 for recurring activity and faults.\n' >&2
    return 2
  fi
  if [[ "$requested_scenario" == "2" ]] \
      && (( INVALID_BLOCK_INITIAL_DELAY_SECONDS + INVALID_BLOCK_INTERVAL_SECONDS >= SCENARIO_DURATION_SECONDS )); then
    printf 'Scenario 2 timing must allow at least two invalid-block announcements.\n' >&2
    return 2
  fi
}

fund_all_node_wallets() {
  local source_wallet peer address txid
  local funded=0
  local -a active_nodes=()

  [[ "$NODE_NAME" == "node01" ]] || return 0
  source_wallet=$(_default_wallet)
  IFS=',' read -r -a active_nodes <<< "$ACTIVE_NODES"
  scenario_log funding "funding every peer wallet before activity starts"
  for peer in "${active_nodes[@]}"; do
    [[ "$peer" != "$NODE_NAME" ]] || continue
    address=$(remote_new_address "$peer" "scenario${SCENARIO_ID}-funding")
    txid=$(send_to_address "$address" 2 "$source_wallet")
    [[ "$txid" =~ ^[0-9a-f]{64}$ ]]
    funded=$((funded + 1))
    scenario_log funding "funded peer=${peer} amount=2 txid=${txid}"
  done
  [[ "$funded" -eq 7 ]]
  scenario_log funding "confirming all seven funding transactions"
  mine_blocks 1 "$source_wallet" >/dev/null
}

prepare_transaction_targets() {
  local peer address attempt
  local -a active_nodes=()

  IFS=',' read -r -a active_nodes <<< "$ACTIVE_NODES"
  SCORING_TARGET_NODES=()
  SCORING_TARGET_ADDRESSES=()
  for peer in "${active_nodes[@]}"; do
    [[ "$peer" != "$NODE_NAME" ]] || continue
    address=
    for ((attempt = 1; attempt <= 20; attempt++)); do
      if address=$(remote_new_address "$peer" \
          "scenario${SCENARIO_ID}-activity-from-${NODE_NAME}" 2>/dev/null); then
        break
      fi
      sleep 1
    done
    if [[ -z "$address" ]]; then
      printf 'Could not obtain a transaction address from %s.\n' "$peer" >&2
      return 1
    fi
    SCORING_TARGET_NODES+=("$peer")
    SCORING_TARGET_ADDRESSES+=("$address")
  done
  [[ ${#SCORING_TARGET_NODES[@]} -eq 7 ]]
}

run_activity_loop() {
  local start_epoch=$1
  local end_epoch=$2
  local wallet node_number target_index target_node target_address txid block_hash now
  local transaction_attempts=0 transaction_successes=0 mining_attempts=0 mining_successes=0
  local ping_attempts=0 ping_successes=0 next_mine_epoch next_ping_epoch

  wallet=$(_default_wallet)
  node_number=$((10#$NODE_ID))
  next_mine_epoch=$((start_epoch + node_number * 2))
  next_ping_epoch=$start_epoch
  target_index=$((node_number % ${#SCORING_TARGET_NODES[@]}))

  scenario_log activity \
    "loop started end_epoch=${end_epoch} transaction_interval=3s mining_interval=32s"
  while (( $(date +%s) < end_epoch )); do
    target_node=${SCORING_TARGET_NODES[$target_index]}
    target_address=${SCORING_TARGET_ADDRESSES[$target_index]}
    transaction_attempts=$((transaction_attempts + 1))
    if txid=$(send_to_address "$target_address" 0.001 "$wallet" 2>/dev/null) \
        && [[ "$txid" =~ ^[0-9a-f]{64}$ ]]; then
      transaction_successes=$((transaction_successes + 1))
      scenario_log activity "transaction peer=${target_node} txid=${txid}"
    else
      scenario_log activity "transaction peer=${target_node} result=temporary-failure"
    fi
    target_index=$(( (target_index + 1) % ${#SCORING_TARGET_NODES[@]} ))

    now=$(date +%s)
    if (( now >= next_mine_epoch && now < end_epoch )); then
      mining_attempts=$((mining_attempts + 1))
      if block_hash=$(mine_blocks 1 "$wallet" 2>/dev/null) \
          && [[ "$block_hash" =~ ^[0-9a-f]{64}$ ]]; then
        mining_successes=$((mining_successes + 1))
        scenario_log activity "mined block=${block_hash}"
      else
        scenario_log activity "mining result=temporary-failure"
      fi
      next_mine_epoch=$((next_mine_epoch + 32))
      if (( next_mine_epoch <= now )); then
        next_mine_epoch=$((now + 32))
      fi
    fi
    now=$(date +%s)
    if (( now >= next_ping_epoch && now < end_epoch )); then
      ping_attempts=$((ping_attempts + 1))
      if bitcoin_rpc ping >/dev/null 2>&1; then
        ping_successes=$((ping_successes + 1))
        scenario_log activity "queued P2P ping for latency sampling"
      else
        scenario_log activity "P2P ping result=temporary-failure"
      fi
      next_ping_epoch=$((next_ping_epoch + 10))
      if (( next_ping_epoch <= now )); then
        next_ping_epoch=$((now + 10))
      fi
    fi
    sleep 3
  done

  scenario_log activity \
    "loop complete transactions=${transaction_successes}/${transaction_attempts} mined=${mining_successes}/${mining_attempts} pings=${ping_successes}/${ping_attempts}"
  (( transaction_successes >= 2 && mining_successes >= 2 && ping_successes >= 2 ))
}

_bounded_fault_sleep() {
  local requested_seconds=$1
  local end_epoch=$2
  local now remaining

  now=$(date +%s)
  remaining=$((end_epoch - now))
  (( remaining > 0 )) || return 1
  if (( requested_seconds > remaining )); then
    requested_seconds=$remaining
  fi
  sleep "$requested_seconds"
  (( $(date +%s) < end_epoch ))
}

run_odd_node_fault_loop() (
  local end_epoch=$1
  local cycle=0
  local delay_count=0 blackout_count=0 process_failure_count=0

  trap 'network_restore' EXIT
  while (( $(date +%s) < end_epoch )); do
    cycle=$((cycle + 1))
    scenario_log faults \
      "cycle=${cycle} state=delay delay_ms=900 jitter_ms=250 loss_percent=4 rate=2mbit"
    network_impair 900 250 4 2mbit
    delay_count=$((delay_count + 1))
    _bounded_fault_sleep 10 "$end_epoch" || break

    network_clear_impairment
    scenario_log faults "cycle=${cycle} state=network-interruption duration_seconds=4"
    network_blackout
    blackout_count=$((blackout_count + 1))
    _bounded_fault_sleep 4 "$end_epoch" || break
    network_restore

    scenario_log faults "cycle=${cycle} state=process-failure duration_seconds=4"
    if (( $(date +%s) + 4 < end_epoch )); then
      suspend_node_for 4
      process_failure_count=$((process_failure_count + 1))
    else
      break
    fi

    scenario_log faults "cycle=${cycle} state=healthy duration_seconds=12"
    _bounded_fault_sleep 12 "$end_epoch" || break
  done
  scenario_log faults \
    "fault loop complete cycles=${cycle} delays=${delay_count} interruptions=${blackout_count} process_failures=${process_failure_count}"
  (( delay_count >= 2 && blackout_count >= 2 && process_failure_count >= 2 ))
)

wait_for_activity_release() {
  local release_file=/run/bitcoin-env/activity.start
  local activity_epoch

  scenario_log scenario "preparation complete; waiting for synchronized activity release"
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

run_invalid_block_loop() (
  local start_epoch=$1
  local end_epoch=$2
  local block_hash block_hex next_announcement sender_pid fifo
  local queued=0
  local sender_status=0
  local -a peers=()
  local -a active_nodes=()

  IFS=',' read -r -a active_nodes <<< "$ACTIVE_NODES"
  for peer in "${active_nodes[@]}"; do
    [[ "$peer" != "$NODE_NAME" ]] && peers+=("$peer")
  done
  [[ ${#peers[@]} -eq 7 ]]

  block_hash=$(bitcoin_rpc getblockhash 200)
  block_hex=$(bitcoin_rpc getblock "$block_hash" 0)
  [[ "$block_hex" =~ ^[0-9a-fA-F]+$ ]]

  fifo=/run/bitcoin-env/invalid-block-candidates.fifo
  rm -f "$fifo"
  mkfifo "$fifo"
  trap 'exec 8>&- 2>/dev/null || true; if [[ -n "${sender_pid:-}" ]]; then kill "$sender_pid" >/dev/null 2>&1 || true; wait "$sender_pid" >/dev/null 2>&1 || true; fi; rm -f "$fifo"' EXIT
  python3 /controls/announce_invalid_block.py \
    --challenge "$SIGNET_CHALLENGE" \
    --port "$P2P_PORT" \
    --minimum-candidates 2 \
    "${peers[@]}" < "$fifo" &
  sender_pid=$!
  exec 8>"$fifo"

  next_announcement=$((start_epoch + INVALID_BLOCK_INITIAL_DELAY_SECONDS))
  while (( next_announcement < end_epoch )); do
    wait_until_epoch "$next_announcement"
    kill -0 "$sender_pid"
    printf '%s\n' "$block_hex" >&8
    queued=$((queued + 1))
    scenario_log invalid-block \
      "queued announcement=${queued} base_block=${block_hash} peers=${#peers[@]}"
    next_announcement=$((next_announcement + INVALID_BLOCK_INTERVAL_SECONDS))
  done

  exec 8>&-
  if wait "$sender_pid"; then
    sender_status=0
  else
    sender_status=$?
  fi
  sender_pid=
  rm -f "$fifo"
  trap - EXIT
  scenario_log invalid-block "announcement loop complete queued=${queued}"
  (( queued >= 2 && sender_status == 0 ))
)

run_peer_scoring_scenario() {
  local requested_scenario=$1
  local activity_start_epoch end_epoch wallet status=0
  local activity_pid fault_pid= invalid_pid=

  validate_scoring_scenario "$requested_scenario"
  assert_initial_state
  wait_for_peer_count 7 180
  wait_until_epoch "$SCENARIO_START_EPOCH"
  scenario_log scenario "preparing scenario=${requested_scenario}"

  fund_all_node_wallets
  wallet=$(_default_wallet)
  if ! wait_for_spendable_balance "$wallet" 0.5 90; then
    scenario_log funding "wallet=${wallet} did not become spendable"
    return 1
  fi
  prepare_transaction_targets
  activity_start_epoch=$(wait_for_activity_release)
  end_epoch=$((activity_start_epoch + SCENARIO_DURATION_SECONDS))
  scenario_log scenario \
    "start scenario=${requested_scenario} activity_start=${activity_start_epoch} end=${end_epoch}"
  wait_until_epoch "$activity_start_epoch"

  run_activity_loop "$activity_start_epoch" "$end_epoch" &
  activity_pid=$!
  if [[ "$NODE_ID" =~ ^0[1357]$ ]]; then
    run_odd_node_fault_loop "$end_epoch" &
    fault_pid=$!
  fi
  if [[ "$requested_scenario" == "2" && "$NODE_ID" == "05" ]]; then
    run_invalid_block_loop "$activity_start_epoch" "$end_epoch" &
    invalid_pid=$!
  fi

  if ! wait "$activity_pid"; then
    status=1
  fi
  if [[ -n "$fault_pid" ]] && ! wait "$fault_pid"; then
    status=1
  fi
  if [[ -n "$invalid_pid" ]] && ! wait "$invalid_pid"; then
    status=1
  fi

  if [[ "$NODE_ID" =~ ^0[1357]$ ]]; then
    network_restore
  fi
  if ! wait_for_regular_peer_count 7 60; then
    scenario_log scenario "regular peer mesh did not recover to seven connections"
    status=1
  fi
  if ! wait_for_common_tip 60; then
    scenario_log scenario "nodes did not converge on one best-block hash"
    status=1
  fi
  if ! validate_chain; then
    scenario_log scenario "local chain verification failed"
    status=1
  fi
  scenario_log scenario "complete scenario=${requested_scenario} status=${status}"
  return "$status"
}

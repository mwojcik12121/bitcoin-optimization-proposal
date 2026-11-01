#!/usr/bin/env bash
# SCENARIO_TITLE: ACP behavior: reorganization during wallet signing
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=reorg_during_signing_observation
readonly FANOUT_OUTPUTS=1000
readonly FANOUT_AMOUNT=0.001
declare -ar RACE_PERCENTAGES=(5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 98)
readonly RACE_ATTEMPTS=${#RACE_PERCENTAGES[@]}
readonly LEGACY_CONTROL_ATTEMPTS=1
readonly TOTAL_RACE_ATTEMPTS=$((RACE_ATTEMPTS + LEGACY_CONTROL_ATTEMPTS))
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + 1 + 2 * TOTAL_RACE_ATTEMPTS + 1))

RACE_INPUTS=
FANOUT_TXID=
RACE_ACTIVE_SEEN=false
RACE_RUNNING_AT_SUBMIT=false
RACE_REORG_BEFORE_RETURN=false

plain_race_options() {
  printf '%s\n' "$RACE_INPUTS" | jq -c \
    --arg change_address "$ACP_CHANGE_ADDRESS" \
    '{
      fee_rate: 1,
      add_to_wallet: false,
      add_inputs: false,
      inputs: .,
      change_address: $change_address,
      change_position: 1,
      replaceable: true
    }'
}

conditioned_race_options() {
  local block_hash=$1

  printf '%s\n' "$RACE_INPUTS" | jq -c \
    --arg block_hash "$block_hash" \
    --arg change_address "$ACP_CHANGE_ADDRESS" \
    '{
      fee_rate: 1,
      add_to_wallet: false,
      add_inputs: false,
      inputs: .,
      change_address: $change_address,
      change_position: 1,
      replaceable: true,
      active_chain_precondition: {
        blockhash: $block_hash,
        min_confirmations: 1
      }
    }'
}

wait_for_active_send() {
  local send_pid=$1
  local deadline=$(( $(date +%s) + 10 ))

  while (( $(date +%s) <= deadline )); do
    if acp_rpc getrpcinfo 2>/dev/null \
        | jq -e '.active_commands | any(.method == "send")' >/dev/null; then
      return 0
    fi
    if ! kill -0 "$send_pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.01
  done
  return 1
}

prepare_fanout() {
  local address_file outputs_json result confirmed_tip unspent_count index

  address_file=$ACP_WORK_DIR/acp-fanout-addresses.txt
  : > "$address_file"
  acp_log fixture "preparing ${FANOUT_OUTPUTS} common-prefix wallet outputs"
  for ((index = 1; index <= FANOUT_OUTPUTS; index++)); do
    acp_wallet_rpc "$ACP_WALLET" getnewaddress "acp-race-${index}" bech32 >> "$address_file"
  done
  outputs_json=$(jq -Rn --argjson amount "$FANOUT_AMOUNT" \
    '[inputs | {key: ., value: $amount}] | from_entries' < "$address_file")

  result=$(acp_wallet_rpc "$ACP_WALLET" -named send \
    "outputs=$outputs_json" 'options={"fee_rate":1}')
  FANOUT_TXID=$(jq -r '.txid // empty' <<<"$result")
  [[ "$FANOUT_TXID" =~ ^[0-9a-f]{64}$ ]] || {
    acp_log fixture "fanout send returned no transaction id result=${result}"
    return 1
  }

  confirmed_tip=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  acp_wait_for_all_tips "$confirmed_tip" 90
  [[ "$(bitcoin_rpc getblockcount)" == "$((BOOTSTRAP_TARGET_HEIGHT + 1))" ]] || return 1

  unspent_count=0
  for ((index = 1; index <= 100; index++)); do
    unspent_count=$(acp_wallet_rpc "$ACP_WALLET" listunspent 1 9999999 \
      | jq --arg txid "$FANOUT_TXID" '[.[] | select(.txid == $txid)] | length')
    (( unspent_count >= FANOUT_OUTPUTS )) && break
    sleep 0.1
  done
  (( unspent_count >= FANOUT_OUTPUTS )) || {
    acp_log fixture "fanout produced only ${unspent_count}/${FANOUT_OUTPUTS} spendable outputs"
    return 1
  }

  RACE_INPUTS=$(acp_wallet_rpc "$ACP_WALLET" listunspent 1 9999999 \
    | jq -c --arg txid "$FANOUT_TXID" --argjson count "$FANOUT_OUTPUTS" \
      '[.[] | select(.txid == $txid) | {txid, vout, sequence: 4294967293}][0:$count]')
  [[ "$(printf '%s\n' "$RACE_INPUTS" | jq 'length')" == "$FANOUT_OUTPUTS" ]] || return 1
  rm -f "$address_file"
  acp_log fixture "fanout ready txid=${FANOUT_TXID} common_tip=${confirmed_tip}"
}

measure_plain_send_ms() {
  local options output_file error_file start_ms end_ms status elapsed_ms

  options=$(plain_race_options)
  output_file=$ACP_WORK_DIR/acp-calibration.out
  error_file=$ACP_WORK_DIR/acp-calibration.err
  rm -f "$output_file" "$error_file"

  start_ms=$(date +%s%3N)
  if printf '%s\n' "outputs=$ACP_SEND_OUTPUTS" "options=$options" \
      | acp_wallet_rpc "$ACP_WALLET" -stdin -named send \
        >"$output_file" 2>"$error_file"; then
    status=0
  else
    status=$?
  fi
  end_ms=$(date +%s%3N)
  [[ "$status" -eq 0 ]] || {
    acp_log fixture "plain calibration send failed status=${status} error=$(acp_compact_file_text "$error_file")"
    return 1
  }
  jq -e '.complete == true and (.hex | type == "string" and length > 0)' \
    "$output_file" >/dev/null || {
    acp_log fixture "plain calibration send did not return a complete signed transaction"
    return 1
  }

  elapsed_ms=$((end_ms - start_ms))
  (( elapsed_ms > 0 )) || elapsed_ms=1
  rm -f "$output_file" "$error_file"
  printf '%s\n' "$elapsed_ms"
}

run_race_attempt() {
  local mode=$1
  local attempt=$2
  local percent=$3
  local calibration_ms=$4
  local common_tip main_anchor hidden_first hidden_tip options before after
  local output_file error_file status_file send_end_file send_pid status
  local start_ms send_end_ms fork_active_ms delay_ms delay_seconds extra_json
  local active_seen=false running_at_submit=false reorg_before_return=false

  common_tip=$(bitcoin_rpc getbestblockhash)
  [[ "$(acp_remote_rpc "$ACP_FORK_NODE" getbestblockhash)" == "$common_tip" ]] || {
    acp_log fixture "fork node is not at the common tip before mode=${mode} attempt=${attempt}"
    return 1
  }

  main_anchor=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  acp_wait_for_node_tip node03 "$main_anchor" 30
  acp_wait_for_node_tip node04 "$main_anchor" 30
  [[ "$(bitcoin_rpc getblockheader "$main_anchor" | jq -r '.confirmations')" == "1" ]] || return 1

  hidden_first=$(acp_mine_remote_one "$ACP_FORK_NODE" "$ACP_FORK_MINING_ADDRESS")
  hidden_tip=$(acp_mine_remote_one "$ACP_FORK_NODE" "$ACP_FORK_MINING_ADDRESS")

  case "$mode" in
    legacy)
      options=$(plain_race_options)
      ;;
    conditioned)
      options=$(conditioned_race_options "$main_anchor")
      ;;
    *)
      test_log ERROR scenario "Unknown race mode: ${mode}"
      return 2
      ;;
  esac

  output_file="$ACP_WORK_DIR/acp-race-${mode}-${attempt}.out"
  error_file="$ACP_WORK_DIR/acp-race-${mode}-${attempt}.err"
  status_file="$ACP_WORK_DIR/acp-race-${mode}-${attempt}.status"
  send_end_file="$ACP_WORK_DIR/acp-race-${mode}-${attempt}.end"
  rm -f "$output_file" "$error_file" "$status_file" "$send_end_file"

  before=$(acp_effect_snapshot "$ACP_WALLET")
  start_ms=$(date +%s%3N)
  (
    set +e
    printf '%s\n' "outputs=$ACP_SEND_OUTPUTS" "options=$options" \
      | acp_wallet_rpc "$ACP_WALLET" -stdin -named send \
        >"$output_file" 2>"$error_file"
    printf '%s\n' "$?" > "$status_file"
    date +%s%3N > "$send_end_file"
  ) &
  send_pid=$!

  if wait_for_active_send "$send_pid"; then
    active_seen=true
  fi

  delay_ms=$((calibration_ms * percent / 100))
  (( delay_ms > 0 )) || delay_ms=1
  delay_seconds=$(awk -v milliseconds="$delay_ms" 'BEGIN {printf "%.3f", milliseconds / 1000}')
  if kill -0 "$send_pid" 2>/dev/null; then
    sleep "$delay_seconds"
  fi
  if kill -0 "$send_pid" 2>/dev/null; then
    running_at_submit=true
  fi

  acp_submit_fork_block "$hidden_first"
  acp_submit_fork_block "$hidden_tip"
  acp_wait_for_node_tip node01 "$hidden_tip" 60
  fork_active_ms=$(date +%s%3N)

  wait "$send_pid" || true
  [[ -s "$status_file" && -s "$send_end_file" ]] || {
    acp_log fixture "wallet RPC did not leave a readable result mode=${mode} attempt=${attempt}"
    return 1
  }
  status=$(cat "$status_file")
  send_end_ms=$(cat "$send_end_file")

  acp_wait_for_node_tip node03 "$hidden_tip" 60
  acp_wait_for_node_tip node04 "$hidden_tip" 60
  [[ "$(bitcoin_rpc getblockheader "$main_anchor" | jq -r '.confirmations')" == "-1" ]] || {
    acp_log fixture "race anchor did not become stale mode=${mode} attempt=${attempt}"
    return 1
  }

  if (( fork_active_ms < send_end_ms )); then
    reorg_before_return=true
  fi

  sleep 1
  after=$(acp_effect_snapshot "$ACP_WALLET")
  extra_json=$(jq -cn \
    --arg mode "$mode" \
    --argjson attempt "$attempt" \
    --argjson delay_percent "$percent" \
    --argjson calibration_ms "$calibration_ms" \
    --argjson request_start_ms "$start_ms" \
    --argjson request_end_ms "$send_end_ms" \
    --argjson fork_active_ms "$fork_active_ms" \
    --argjson active_seen "$active_seen" \
    --argjson running_at_submit "$running_at_submit" \
    --argjson reorg_before_return "$reorg_before_return" \
    --arg anchor "$main_anchor" \
    --arg active_tip "$hidden_tip" \
    '{
      mode: $mode,
      attempt: $attempt,
      delay_percent: $delay_percent,
      calibration_ms: $calibration_ms,
      request_start_ms: $request_start_ms,
      request_end_ms: $request_end_ms,
      elapsed_ms: ($request_end_ms - $request_start_ms),
      fork_active_ms: $fork_active_ms,
      request_seen_active: $active_seen,
      request_running_when_fork_submitted: $running_at_submit,
      reorg_active_before_rpc_return: $reorg_before_return,
      anchor: $anchor,
      active_tip: $active_tip
    }')

  acp_record_send_observation \
    "${mode}_inflight_reorg_${attempt}" "$status" "$output_file" "$error_file" \
    "$before" "$after" "$extra_json"

  RACE_ACTIVE_SEEN=$active_seen
  RACE_RUNNING_AT_SUBMIT=$running_at_submit
  RACE_REORG_BEFORE_RETURN=$reorg_before_return

  rm -f "$output_file" "$error_file" "$status_file" "$send_end_file"
}

run_inflight_reorg_observations() {
  local calibration_file calibration_ms attempt percent outcome summary
  local legacy_outcome legacy_active=false legacy_running=false legacy_reorg_before_return=false
  local conditioned_active_seen=0 conditioned_running_at_submit=0 conditioned_reorg_before_return=0
  local conditioned_success_signed=0 conditioned_success_other=0
  local conditioned_acp_before_signing=0 conditioned_acp_before_release=0
  local conditioned_acp_other=0 conditioned_mentions_acp=0 conditioned_rpc_error=0

  calibration_file=$ACP_WORK_DIR/acp-calibration-ms.txt
  : > "$calibration_file"
  for _ in 1 2 3; do
    measure_plain_send_ms >> "$calibration_file"
  done
  calibration_ms=$(sort -n "$calibration_file" | sed -n '2p')
  [[ "$calibration_ms" =~ ^[1-9][0-9]*$ ]] || return 1
  acp_log behavior \
    "calibration inputs=${FANOUT_OUTPUTS} median_ms=${calibration_ms} samples=$(tr '\n' ',' < "$calibration_file" | sed 's/,$//')"

  run_race_attempt legacy 1 50 "$calibration_ms"
  legacy_outcome=$ACP_LAST_OUTCOME
  legacy_active=$RACE_ACTIVE_SEEN
  legacy_running=$RACE_RUNNING_AT_SUBMIT
  legacy_reorg_before_return=$RACE_REORG_BEFORE_RETURN

  for attempt in "${!RACE_PERCENTAGES[@]}"; do
    percent=${RACE_PERCENTAGES[$attempt]}
    run_race_attempt conditioned "$((attempt + 1))" "$percent" "$calibration_ms"
    outcome=$ACP_LAST_OUTCOME

    [[ "$RACE_ACTIVE_SEEN" == "true" ]] && conditioned_active_seen=$((conditioned_active_seen + 1))
    [[ "$RACE_RUNNING_AT_SUBMIT" == "true" ]] \
      && conditioned_running_at_submit=$((conditioned_running_at_submit + 1))
    [[ "$RACE_REORG_BEFORE_RETURN" == "true" ]] \
      && conditioned_reorg_before_return=$((conditioned_reorg_before_return + 1))

    case "$outcome" in
      success_signed_transaction)
        conditioned_success_signed=$((conditioned_success_signed + 1))
        ;;
      success_*)
        conditioned_success_other=$((conditioned_success_other + 1))
        ;;
      error_active_chain_precondition_before_signing)
        conditioned_acp_before_signing=$((conditioned_acp_before_signing + 1))
        ;;
      error_active_chain_precondition_before_release)
        conditioned_acp_before_release=$((conditioned_acp_before_release + 1))
        ;;
      error_active_chain_precondition)
        conditioned_acp_other=$((conditioned_acp_other + 1))
        ;;
      error_mentions_active_chain_precondition)
        conditioned_mentions_acp=$((conditioned_mentions_acp + 1))
        ;;
      *)
        conditioned_rpc_error=$((conditioned_rpc_error + 1))
        ;;
    esac
  done

  rm -f "$calibration_file"
  summary=$(jq -cn \
    --argjson scenario "$SCENARIO_ID" \
    --argjson calibration_ms "$calibration_ms" \
    --arg legacy_outcome "$legacy_outcome" \
    --argjson legacy_active "$legacy_active" \
    --argjson legacy_running "$legacy_running" \
    --argjson legacy_reorg_before_return "$legacy_reorg_before_return" \
    --argjson attempts "$RACE_ATTEMPTS" \
    --argjson active_seen "$conditioned_active_seen" \
    --argjson running_at_submit "$conditioned_running_at_submit" \
    --argjson reorg_before_return "$conditioned_reorg_before_return" \
    --argjson success_signed "$conditioned_success_signed" \
    --argjson success_other "$conditioned_success_other" \
    --argjson before_signing "$conditioned_acp_before_signing" \
    --argjson before_release "$conditioned_acp_before_release" \
    --argjson acp_other "$conditioned_acp_other" \
    --argjson mentions_acp "$conditioned_mentions_acp" \
    --argjson rpc_error "$conditioned_rpc_error" \
    '{
      scenario: $scenario,
      calibration_ms: $calibration_ms,
      legacy_control: {
        outcome: $legacy_outcome,
        request_seen_active: $legacy_active,
        request_running_when_fork_submitted: $legacy_running,
        reorg_active_before_rpc_return: $legacy_reorg_before_return
      },
      conditioned_attempts: {
        total: $attempts,
        request_seen_active: $active_seen,
        request_running_when_fork_submitted: $running_at_submit,
        reorg_active_before_rpc_return: $reorg_before_return,
        success_signed_transaction: $success_signed,
        success_other: $success_other,
        error_before_signing: $before_signing,
        error_before_release: $before_release,
        error_active_chain_precondition_other: $acp_other,
        error_mentions_active_chain_precondition: $mentions_acp,
        error_rpc_or_other: $rpc_error
      }
    }')
  acp_write_behavior_summary "$summary"
  acp_log scenario \
    "test actions completed observations=${TOTAL_RACE_ATTEMPTS} calibration_ms=${calibration_ms}"
}

main() {
  local activity_start

  acp_begin_scenario "$TEST_NAME"
  acp_prepare_wallet_context

  prepare_fanout
  acp_isolate_fork_node
  [[ "$(acp_remote_rpc "$ACP_FORK_NODE" getbestblockhash)" == "$(bitcoin_rpc getbestblockhash)" ]] || {
    acp_log fixture "fork node and wallet node differ before race testing"
    return 1
  }

  activity_start=$(acp_wait_for_activity_release)
  acp_wait_until_epoch "$activity_start"

  run_inflight_reorg_observations
  acp_finish_orchestrator "$TEST_NAME" "$TERMINAL_HEIGHT"
}

main "$@"

#!/usr/bin/env bash
# SCENARIO_TITLE: ACP behavior: confirmation-boundary requests
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=confirmation_boundary_observation
readonly ANCHOR_CONFIRMATIONS=3
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + ANCHOR_CONFIRMATIONS + 1))

main() {
  local activity_start anchor_hash main_tip confirmations options index
  local legacy_outcome exact_outcome one_short_outcome summary

  acp_begin_scenario "$TEST_NAME"
  acp_prepare_wallet_context

  anchor_hash=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  main_tip=$anchor_hash
  for ((index = 2; index <= ANCHOR_CONFIRMATIONS; index++)); do
    main_tip=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  done
  acp_wait_for_all_tips "$main_tip" 90

  activity_start=$(acp_wait_for_activity_release)
  acp_wait_until_epoch "$activity_start"

  confirmations=$(bitcoin_rpc getblockheader "$anchor_hash" | jq -r '.confirmations')
  [[ "$confirmations" == "$ANCHOR_CONFIRMATIONS" ]] || {
    acp_log fixture \
      "anchor fixture has confirmations=${confirmations} expected=${ANCHOR_CONFIRMATIONS}"
    return 1
  }

  options=$(acp_plain_send_options false)
  acp_observe_send legacy_exact_depth "$ACP_WALLET" "$ACP_SEND_OUTPUTS" "$options"
  legacy_outcome=$ACP_LAST_OUTCOME

  options=$(acp_send_options "$anchor_hash" "$ANCHOR_CONFIRMATIONS" false)
  acp_observe_send conditioned_exact_depth "$ACP_WALLET" "$ACP_SEND_OUTPUTS" "$options"
  exact_outcome=$ACP_LAST_OUTCOME

  options=$(acp_send_options "$anchor_hash" "$((ANCHOR_CONFIRMATIONS + 1))" false)
  acp_observe_send conditioned_one_confirmation_short \
    "$ACP_WALLET" "$ACP_SEND_OUTPUTS" "$options"
  one_short_outcome=$ACP_LAST_OUTCOME

  summary=$(jq -cn \
    --argjson scenario "$SCENARIO_ID" \
    --arg anchor "$anchor_hash" \
    --argjson observed_depth "$confirmations" \
    --arg legacy "$legacy_outcome" \
    --arg exact "$exact_outcome" \
    --arg one_short "$one_short_outcome" \
    '{
      scenario: $scenario,
      anchor: $anchor,
      observed_depth: $observed_depth,
      legacy_request: $legacy,
      conditioned_exact_depth: $exact,
      conditioned_one_short: $one_short
    }')
  acp_write_behavior_summary "$summary"
  acp_log scenario "test actions completed observations=3"

  acp_finish_orchestrator "$TEST_NAME" "$TERMINAL_HEIGHT"
}

main "$@"

#!/usr/bin/env bash
# SCENARIO_TITLE: ACP behavior: stale anchor after reorganization
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=stale_anchor_observation
readonly ANCHOR_CONFIRMATIONS=3
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + ANCHOR_CONFIRMATIONS + 2))

main() {
  local activity_start anchor_hash main_tip hidden_tip confirmations options hash index
  local conditioned_outcome conditioned_effects legacy_outcome legacy_effects summary
  local -a fork_hashes=()

  acp_begin_scenario "$TEST_NAME"
  acp_prepare_wallet_context
  acp_isolate_fork_node

  anchor_hash=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  main_tip=$anchor_hash
  for ((index = 2; index <= ANCHOR_CONFIRMATIONS; index++)); do
    main_tip=$(acp_mine_local_one "$ACP_MINING_ADDRESS")
  done
  acp_wait_for_node_tip node03 "$main_tip" 60
  acp_wait_for_node_tip node04 "$main_tip" 60

  for ((index = 1; index <= ANCHOR_CONFIRMATIONS + 1; index++)); do
    hash=$(acp_mine_remote_one "$ACP_FORK_NODE" "$ACP_FORK_MINING_ADDRESS")
    fork_hashes+=("$hash")
  done
  hidden_tip=${fork_hashes[$ANCHOR_CONFIRMATIONS]}

  activity_start=$(acp_wait_for_activity_release)
  acp_wait_until_epoch "$activity_start"

  confirmations=$(bitcoin_rpc getblockheader "$anchor_hash" | jq -r '.confirmations')
  [[ "$confirmations" == "$ANCHOR_CONFIRMATIONS" ]] || {
    acp_log fixture \
      "application precheck observed confirmations=${confirmations} expected=${ANCHOR_CONFIRMATIONS}"
    return 1
  }
  acp_log behavior \
    "application precheck observed anchor=${anchor_hash} confirmations=${confirmations}"

  for hash in "${fork_hashes[@]}"; do
    acp_submit_fork_block "$hash"
  done
  acp_wait_for_node_tip node01 "$hidden_tip" 60
  acp_wait_for_node_tip node03 "$hidden_tip" 60
  acp_wait_for_node_tip node04 "$hidden_tip" 60
  [[ "$(bitcoin_rpc getblockheader "$anchor_hash" | jq -r '.confirmations')" == "-1" ]] || {
    acp_log fixture "anchor did not become stale after the competing branch was delivered"
    return 1
  }

  # First invoke the request carrying the stale precondition. The result and all
  # wallet, mempool, and relay effects are recorded without judging the outcome.
  options=$(acp_send_options "$anchor_hash" "$ANCHOR_CONFIRMATIONS" true)
  acp_observe_send conditioned_stale_anchor "$ACP_WALLET" "$ACP_SEND_OUTPUTS" "$options"
  conditioned_outcome=$ACP_LAST_OUTCOME
  conditioned_effects=$ACP_LAST_EFFECTS_JSON

  # Then invoke the same payment without the precondition as a control. This is
  # run on every binary, and its actual effects are recorded in the same format.
  options=$(acp_plain_send_options true)
  acp_observe_send legacy_after_stale_precheck "$ACP_WALLET" "$ACP_SEND_OUTPUTS" "$options"
  legacy_outcome=$ACP_LAST_OUTCOME
  legacy_effects=$ACP_LAST_EFFECTS_JSON

  summary=$(jq -cn \
    --argjson scenario "$SCENARIO_ID" \
    --arg anchor "$anchor_hash" \
    --arg active_tip "$hidden_tip" \
    --arg conditioned "$conditioned_outcome" \
    --arg legacy "$legacy_outcome" \
    --argjson conditioned_effects "$conditioned_effects" \
    --argjson legacy_effects "$legacy_effects" \
    '{
      scenario: $scenario,
      stale_anchor: $anchor,
      active_tip: $active_tip,
      conditioned_request: $conditioned,
      conditioned_effects: $conditioned_effects,
      legacy_control: $legacy,
      legacy_effects: $legacy_effects
    }')
  acp_write_behavior_summary "$summary"
  acp_log scenario "test actions completed observations=2"

  acp_finish_orchestrator "$TEST_NAME" "$TERMINAL_HEIGHT"
}

main "$@"

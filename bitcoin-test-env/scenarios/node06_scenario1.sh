#!/usr/bin/env bash
set -Eeuo pipefail
source /controls/actions.sh
source /controls/info.sh
source /controls/network.sh
source /controls/process.sh

assert_initial_state
wait_for_peer_count 7 180
wait_until_epoch "$SCENARIO_START_EPOCH"

PARTITION_HEAL_EPOCH=$((SCENARIO_START_EPOCH + 40))
TRANSACTION_END_EPOCH=$((SCENARIO_START_EPOCH + 60))
WINNING_BRANCH_HEIGHT=212
FINAL_HEIGHT=213

network_partition_group node02 node04 node05 node08
sleep 2

(
  wait_until_epoch $((SCENARIO_START_EPOCH + 6))
  network_flap_peer node01 3 2 1
  wait_until_epoch $((SCENARIO_START_EPOCH + 24))
  network_pause 4
  wait_until_epoch $((SCENARIO_START_EPOCH + 32))
  network_set_active false >/dev/null
  suspend_node_for 3
  network_set_active true >/dev/null
) &
network_interruptions_pid=$!

wait_for_exact_height "$WINNING_BRANCH_HEIGHT" 120
winning_tip=$(bitcoin_rpc getbestblockhash)

wait_until_epoch "$PARTITION_HEAL_EPOCH"
wait "$network_interruptions_pid"
network_heal_group node02 node04 node05 node08
wait_for_peer_count 7 180
wait_for_same_tip node01 180

wait_until_epoch "$TRANSACTION_END_EPOCH"
wait_for_exact_height "$FINAL_HEIGHT" 180
wait_for_same_tip node01 180
winning_confirmations=$(bitcoin_rpc getblockheader "$winning_tip" true | jq -r '.confirmations // -1')
(( winning_confirmations >= 2 ))
validate_chain 4 0 >/dev/null

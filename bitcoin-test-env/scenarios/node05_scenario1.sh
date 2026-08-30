#!/usr/bin/env bash
set -Eeuo pipefail
source /controls/actions.sh
source /controls/info.sh
source /controls/network.sh

assert_initial_state
wait_for_peer_count 7 180
wait_until_epoch "$SCENARIO_START_EPOCH"

PARTITION_HEAL_EPOCH=$((SCENARIO_START_EPOCH + 40))
TRANSACTION_END_EPOCH=$((SCENARIO_START_EPOCH + 60))
LOSING_BRANCH_HEIGHT=210
FINAL_HEIGHT=213

generate_transactions_until_epoch \
  "$TRANSACTION_END_EPOCH" wallet05 node02,node04,node08 0.001 2 &
transaction_pid=$!

network_partition_group node01 node03 node06 node07
sleep 2
wait_for_exact_height "$LOSING_BRANCH_HEIGHT" 120
losing_tip=$(bitcoin_rpc getbestblockhash)

wait_until_epoch "$PARTITION_HEAL_EPOCH"
network_heal_group node01 node03 node06 node07
wait_for_peer_count 7 180
wait_for_same_tip node01 180

wait "$transaction_pid"
wait_for_exact_height "$FINAL_HEIGHT" 180
wait_for_same_tip node01 180
losing_confirmations=$(bitcoin_rpc getblockheader "$losing_tip" true | jq -r '.confirmations // 0')
[[ "$losing_confirmations" == "-1" ]]
validate_chain 4 0 >/dev/null

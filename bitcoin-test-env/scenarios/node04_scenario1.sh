#!/usr/bin/env bash
set -Eeuo pipefail
source /controls/actions.sh
source /controls/info.sh
source /controls/network.sh

assert_initial_state
wait_for_peer_count 7 180
log_peer_connections "full-mesh"

# This miner remains slower for the entire scenario through fixed egress latency.
network_delay 750
wait_until_epoch "$SCENARIO_START_EPOCH"

PARTITION_HEAL_EPOCH=$((SCENARIO_START_EPOCH + 40))
TRANSACTION_END_EPOCH=$((SCENARIO_START_EPOCH + 60))
LOSING_BRANCH_HEIGHT=210
FINAL_HEIGHT=213

network_partition_group node01 node03 node06 node07
sleep 2
log_peer_connections "partitioned"

# Permanently slower miner on partition B: one block every six to seven seconds.
mine_blocks_at_offsets \
  "$SCENARIO_START_EPOCH" "12,19,25,31" wallet-node04 >/dev/null

wait_for_exact_height "$LOSING_BRANCH_HEIGHT" 120
losing_tip=$(bitcoin_rpc getbestblockhash)

wait_until_epoch "$PARTITION_HEAL_EPOCH"
network_heal_group node01 node03 node06 node07
wait_for_peer_count 7 180
log_peer_connections "healed"
wait_for_same_tip node01 180

wait_until_epoch "$TRANSACTION_END_EPOCH"
wait_for_exact_height "$FINAL_HEIGHT" 180
wait_for_same_tip node01 180
losing_confirmations=$(bitcoin_rpc getblockheader "$losing_tip" true | jq -r '.confirmations // 0')
[[ "$losing_confirmations" == "-1" ]]
validate_chain 4 0 >/dev/null

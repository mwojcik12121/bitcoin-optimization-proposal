#!/usr/bin/env bash
set -Eeuo pipefail
source /controls/actions.sh
source /controls/info.sh
source /controls/network.sh

assert_initial_state
wait_for_peer_count 7 180
log_peer_connections "full-mesh"

# This validator remains slower for the entire scenario through fixed egress latency.
network_delay 1250
wait_until_epoch "$SCENARIO_START_EPOCH"

PARTITION_HEAL_EPOCH=$((SCENARIO_START_EPOCH + 40))
TRANSACTION_END_EPOCH=$((SCENARIO_START_EPOCH + 60))
WINNING_BRANCH_HEIGHT=212
FINAL_HEIGHT=213

network_partition_group node02 node04 node05 node08
sleep 2
log_peer_connections "partitioned"
wait_for_exact_height "$WINNING_BRANCH_HEIGHT" 120
winning_tip=$(bitcoin_rpc getbestblockhash)

wait_until_epoch "$PARTITION_HEAL_EPOCH"
network_heal_group node02 node04 node05 node08
wait_for_peer_count 7 180
log_peer_connections "healed"
wait_for_same_tip node01 180

wait_until_epoch "$TRANSACTION_END_EPOCH"
wait_for_exact_height "$FINAL_HEIGHT" 180
wait_for_same_tip node01 180
winning_confirmations=$(bitcoin_rpc getblockheader "$winning_tip" true | jq -r '.confirmations // -1')
(( winning_confirmations >= 2 ))
validate_chain 4 0 >/dev/null

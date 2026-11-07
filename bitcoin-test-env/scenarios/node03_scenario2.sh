#!/usr/bin/env bash
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=stale_anchor_observation
readonly ANCHOR_CONFIRMATIONS=3
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + ANCHOR_CONFIRMATIONS + 2))

acp_run_support "$TEST_NAME" "$TERMINAL_HEIGHT"

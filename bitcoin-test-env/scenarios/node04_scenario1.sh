#!/usr/bin/env bash
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=confirmation_boundary_observation
readonly ANCHOR_CONFIRMATIONS=3
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + ANCHOR_CONFIRMATIONS + 1))

acp_run_support "$TEST_NAME" "$TERMINAL_HEIGHT"

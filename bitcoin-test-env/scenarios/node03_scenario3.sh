#!/usr/bin/env bash
# SCENARIO_TITLE: ACP behavior: reorganization during wallet signing
set -Eeuo pipefail

source /controls/acp_common.sh

readonly TEST_NAME=reorg_during_signing_observation
readonly RACE_ATTEMPTS=20
readonly LEGACY_CONTROL_ATTEMPTS=1
readonly TOTAL_RACE_ATTEMPTS=$((RACE_ATTEMPTS + LEGACY_CONTROL_ATTEMPTS))
readonly TERMINAL_HEIGHT=$((BOOTSTRAP_TARGET_HEIGHT + 1 + 2 * TOTAL_RACE_ATTEMPTS + 1))

acp_run_support "$TEST_NAME" "$TERMINAL_HEIGHT"

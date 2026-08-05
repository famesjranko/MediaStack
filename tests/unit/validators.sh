#!/usr/bin/env bash
# tests/unit/validators.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATORS_TEST_DIR="$SCRIPT_DIR/validators"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="validators"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/validators.sh"

set +e
set +u

WARN_COUNT=0
# Consumed via assert_contains "$LAST_WARN" ... by the sourced topic files below.
# shellcheck disable=SC2034
LAST_WARN=""
UI_CONFIRM_RESPONSE="yes"

ui_log() {
    local level="$1"
    shift
    if [[ "$level" == "warn" ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        LAST_WARN="$*"
    fi
}

ui_confirm() {
    [[ "${UI_CONFIRM_RESPONSE:-yes}" == "yes" ]]
}

sudo() {
    "$@"
}

reset_warn() {
    WARN_COUNT=0
    # Consumed via assert_contains "$LAST_WARN" ... by the sourced topic files below.
    # shellcheck disable=SC2034
    LAST_WARN=""
}

# Topic modules, split out of this file for size: the children are sourced,
# not run as independent suites, so the frozen output and summary remain one
# suite. Keep this order — it is the historical assertion order.
source "$VALIDATORS_TEST_DIR/account.sh"
source "$VALIDATORS_TEST_DIR/ddns.sh"
source "$VALIDATORS_TEST_DIR/storage.sh"
source "$VALIDATORS_TEST_DIR/network.sh"
source "$VALIDATORS_TEST_DIR/misc.sh"
source "$VALIDATORS_TEST_DIR/bandwidth.sh"

scenario_end "$CURRENT_SCENARIO"
summary

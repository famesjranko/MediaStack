#!/usr/bin/env bash
# tests/unit/stack-lifecycle.sh
#
# Regression tests for start_stack's storage guard propagation. Docker and
# lifecycle helpers are shimmed so no host state or containers are touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stack-lifecycle"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u

SCRIPT_DIR="$REPO_ROOT"
EVENTS=()

record_event() {
    EVENTS+=("$1")
}

log_info() { record_event "info:$*"; }
log_ok() { record_event "success:$*"; }
profiles_build_args() {
    record_event profiles
}
service_container_running() { return 1; }
ensure_mediastack_network_config() { record_event network; }
docker() { record_event "docker:$*"; }

# Stage 2 and recovery call their runners conditionally. Keep that shape here
# so errexit cannot mask a missing explicit return from start_stack.
stage2_like() { start_stack; }

storage_guard_before_start() {
    record_event guard
    return 1
}

RC=0
stage2_like || RC=$?
assert_eq "1" "$RC" "start_stack: guard failure propagates through conditional caller"
assert_eq "info:Starting MediaStack... guard" "${EVENTS[*]}" \
    "start_stack: guard failure stops all later lifecycle side effects"
assert_not_contains "${EVENTS[*]}" network "start_stack: guard failure skips network preparation"
assert_not_contains "${EVENTS[*]}" docker: "start_stack: guard failure skips Docker"
assert_not_contains "${EVENTS[*]}" success: "start_stack: guard failure skips success message"

EVENTS=()
storage_guard_before_start() {
    record_event guard
    return 0
}

RC=0
stage2_like || RC=$?
assert_eq "0" "$RC" "start_stack: successful guard permits startup"
assert_contains "${EVENTS[*]}" "guard profiles network docker:compose up -d success:Containers started" \
    "start_stack: successful guard preserves startup order and completion"

scenario_end "$CURRENT_SCENARIO"
summary

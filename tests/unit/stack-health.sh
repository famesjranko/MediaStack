#!/usr/bin/env bash
# tests/unit/stack-health.sh
#
# Pure-bash unit tests for scripts/setup/stack.sh health gating. Docker is
# shimmed so these tests do not start containers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stack-health"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u

SCRIPT_DIR="$REPO_ROOT"
DOCKER_PS_FIXTURE=""
DOCKER_PS_SERVICES=$'jellyfin\nportainer'
LOG_LINES=()

log_ok() { LOG_LINES+=("OK:$*"); }
log_info() { LOG_LINES+=("INFO:$*"); }
log_warn() { LOG_LINES+=("WARN:$*"); }
sleep() { :; }

docker() {
    local args=" $* "
    if [[ "${1:-}" == "compose" && "$args" == *" ps "* && "$args" == *" --services "* ]]; then
        printf '%s\n' "$DOCKER_PS_SERVICES"
        return 0
    fi
    if [[ "${1:-}" == "compose" && "$args" == *" ps "* ]]; then
        printf '%s\n' "$DOCKER_PS_FIXTURE"
        return 0
    fi
    return 0
}

DOCKER_PS_FIXTURE=$'{"Service":"jellyfin","Name":"jellyfin","State":"running","Health":"healthy"}\n{"Service":"portainer","Name":"portainer","State":"exited","Health":""}'
wait_all_healthy >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "wait_all_healthy: exited service fails health gate"
else
    fail "wait_all_healthy: exited service fails health gate" "expected non-zero, got 0"
fi

LOG_LINES=()
DOCKER_PS_FIXTURE=$'{"Service":"jellyfin","Name":"jellyfin","State":"running","Health":"healthy"}\n{"Service":"portainer","Name":"portainer","State":"running","Health":""}'
wait_all_healthy >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "wait_all_healthy: running service without healthcheck is allowed"
else
    fail "wait_all_healthy: running service without healthcheck is allowed" "expected zero, got $rc"
fi

LOG_LINES=()
DOCKER_PS_FIXTURE=$'{"Service":"jellyfin","Name":"jellyfin","State":"running","Health":"healthy"}'
wait_all_healthy jellyfin portainer >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "wait_all_healthy: missing expected service fails health gate"
else
    fail "wait_all_healthy: missing expected service fails health gate" "expected non-zero, got 0"
fi

scenario_end "$CURRENT_SCENARIO"
summary

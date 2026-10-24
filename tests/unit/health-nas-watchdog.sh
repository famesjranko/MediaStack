#!/usr/bin/env bash
# tests/unit/health-nas-watchdog.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="health-nas-watchdog"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/health-containers.sh"

profiles_build_args() { :; }
COMPOSE_CONFIG_OK=1
docker() {
    case " $* " in
        *" config --services "*)
            ((COMPOSE_CONFIG_OK)) || return 1
            printf '%s\n' jellyfin sonarr
            ;;
        *" ps -a --format "*)
            printf '%s\n' \
                'jellyfin|running|healthy|Up 1 minute' \
                'sonarr|exited||Exited (0) 1 minute ago'
            ;;
    esac
}

health_output() { health_containers; }
cause='fail|NAS storage unreachable - NAS-dependent services stopped by the watchdog'

# Given NAS storage and a non-empty watchdog stopped-services marker
# When container health runs
# Then it prints the cause once before the first service verdict
fixture="$TMP_DIR/nas-with-flag"
mkdir -p "$fixture/config/state"
printf '2026-10-23T00:00:00Z\n' >"$fixture/config/state/storage-watchdog-stopped"
export SCRIPT_DIR="$fixture"
export STORAGE_MODE=nas
output="$(health_output)"
assert_eq "$cause" "$(head -n 1 <<<"$output")" "NAS watchdog cause is the first line"
assert_eq "1" "$(grep -cFx "$cause" <<<"$output")" "NAS watchdog cause prints once"
cause_index="$(grep -nFx "$cause" <<<"$output" | cut -d: -f1)"
service_index="$(grep -n '^ok|jellyfin:' <<<"$output" | head -n 1 | cut -d: -f1)"
if [[ -n "$cause_index" && -n "$service_index" ]] && ((cause_index < service_index)); then
    pass "NAS watchdog cause precedes service verdicts"
else
    fail "NAS watchdog cause precedes service verdicts" "cause=$cause_index service=$service_index"
fi

# Given local storage and a non-empty stale watchdog stopped-services marker
# When container health runs
# Then it does not print the NAS watchdog cause
export SCRIPT_DIR="$fixture"
export STORAGE_MODE=local
output="$(health_output)"
assert_not_contains "$output" "$cause" "local storage ignores the watchdog marker"

# Given storage mode is unset and a non-empty stale watchdog stopped-services marker
# When container health runs
# Then it does not print the NAS watchdog cause
export SCRIPT_DIR="$fixture"
unset STORAGE_MODE
output="$(health_output)"
assert_not_contains "$output" "$cause" "unset storage mode ignores the watchdog marker"

# Given NAS storage without a watchdog stopped-services marker
# When container health runs
# Then it does not print the NAS watchdog cause
fixture="$TMP_DIR/nas-without-flag"
mkdir -p "$fixture/config/state"
export SCRIPT_DIR="$fixture"
export STORAGE_MODE=nas
output="$(health_output)"
assert_not_contains "$output" "$cause" "NAS storage without marker has no watchdog cause"

# Given NAS storage and a non-empty watchdog stopped-services marker
# When Compose cannot list services
# Then the cause prints before the Compose skip verdict
COMPOSE_CONFIG_OK=0
export SCRIPT_DIR="$TMP_DIR/nas-with-flag"
export STORAGE_MODE=nas
output="$(health_output)"
assert_eq "$cause" "$(head -n 1 <<<"$output")" "NAS watchdog cause precedes the Compose skip"
assert_contains "$output" "skip|Containers: cannot list the compose services" "Compose failure still reports its skip verdict"

scenario_end "$CURRENT_SCENARIO"
summary

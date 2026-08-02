#!/usr/bin/env bash
# Unit test - tests/lib/cache.sh mirror lifecycle flags.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="cache"
scenario_begin "$CURRENT_SCENARIO"

DOCKER_RUNNING=0
DOCKER_EXISTS=0
DOCKER_RUN_FAIL=0
DOCKER_RM_FAIL=0
DOCKER_START_COUNT=0
DOCKER_RUN_COUNT=0
DOCKER_RM_COUNT=0

docker() {
    case "${1:-}" in
        ps)
            if [[ "${2:-}" == "--format" ]]; then
                if [[ "${3:-}" == "{{.Names}}" ]]; then
                    ((DOCKER_RUNNING)) && printf '%s\n' "$MS_CACHE_MIRROR_NAME"
                    return 0
                fi
                return 0
            fi
            if [[ "${2:-}" == "-a" && "${3:-}" == "--format" && "${4:-}" == "{{.Names}}" ]]; then
                if ((DOCKER_EXISTS || DOCKER_RUNNING)); then
                    printf '%s\n' "$MS_CACHE_MIRROR_NAME"
                fi
                return 0
            fi
            ;;
        start)
            DOCKER_START_COUNT=$((DOCKER_START_COUNT + 1))
            DOCKER_RUNNING=1
            DOCKER_EXISTS=1
            printf '%s\n' "${2:-}"
            return 0
            ;;
        network)
            if [[ "${2:-}" == "inspect" ]]; then
                printf '172.17.0.1\n'
                return 0
            fi
            ;;
        run)
            DOCKER_RUN_COUNT=$((DOCKER_RUN_COUNT + 1))
            ((DOCKER_RUN_FAIL)) && return 1
            DOCKER_RUNNING=1
            DOCKER_EXISTS=1
            printf 'container-id\n'
            return 0
            ;;
        rm)
            if [[ "${2:-}" == "-f" ]]; then
                DOCKER_RM_COUNT=$((DOCKER_RM_COUNT + 1))
                ((DOCKER_RM_FAIL)) && return 1
                DOCKER_RUNNING=0
                DOCKER_EXISTS=0
                return 0
            fi
            ;;
        volume)
            return 0
            ;;
    esac
    printf 'unexpected docker call: %s\n' "$*" >&2
    return 1
}

source "$REPO_ROOT/tests/lib/cache.sh"

reset_cache_fixture() {
    MS_TEST_NO_CACHE=0
    MS_CACHE_MIRROR_STARTED_BY_RUN=0
    MS_CACHE_MIRROR_KEEP=0
    DOCKER_RUNNING=0
    DOCKER_EXISTS=0
    DOCKER_RUN_FAIL=0
    DOCKER_RM_FAIL=0
    DOCKER_START_COUNT=0
    DOCKER_RUN_COUNT=0
    DOCKER_RM_COUNT=0
}

reset_cache_fixture
MS_TEST_NO_CACHE=1
cache_mirror_up
rc=$?
cache_mirror_down
assert_eq "0" "$rc" "cache mirror up succeeds when cache is disabled"
assert_eq "0" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "cache disabled does not mark mirror as runner-owned"
assert_eq "0" "$DOCKER_RM_COUNT" "cache disabled cleanup does not remove mirrors"

reset_cache_fixture
DOCKER_RUNNING=1
DOCKER_EXISTS=1
cache_mirror_up
rc=$?
cache_mirror_down
assert_eq "0" "$rc" "cache mirror up reuses already-running mirror"
assert_eq "0" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "already-running mirror cleanup resets runner-owned flag"
assert_eq "1" "$DOCKER_RM_COUNT" "already-running mirror is removed by default cleanup"

reset_cache_fixture
DOCKER_RUNNING=1
DOCKER_EXISTS=1
MS_CACHE_MIRROR_KEEP=1
cache_mirror_up
rc=$?
cache_mirror_down
assert_eq "0" "$rc" "cache mirror up reuses already-running mirror with keep enabled"
assert_eq "1" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "kept already-running mirror remains marked for this run"
assert_eq "0" "$DOCKER_RM_COUNT" "MS_CACHE_MIRROR_KEEP preserves already-running mirror"

reset_cache_fixture
DOCKER_EXISTS=1
cache_mirror_up
rc=$?
assert_eq "0" "$rc" "cache mirror up starts stopped mirror"
assert_eq "1" "$DOCKER_START_COUNT" "stopped mirror is started"
assert_eq "1" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "started mirror is marked runner-owned"
cache_mirror_down
assert_eq "1" "$DOCKER_RM_COUNT" "runner-owned started mirror is removed on cleanup"
assert_eq "0" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "runner-owned flag resets after cleanup"

reset_cache_fixture
cache_mirror_up
rc=$?
assert_eq "0" "$rc" "cache mirror up creates missing mirror"
assert_eq "1" "$DOCKER_RUN_COUNT" "missing mirror is created"
assert_eq "1" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "created mirror is marked runner-owned"
cache_mirror_down
assert_eq "1" "$DOCKER_RM_COUNT" "runner-owned created mirror is removed on cleanup"
assert_eq "0" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "created mirror flag resets after cleanup"

reset_cache_fixture
DOCKER_RUN_FAIL=1
cache_mirror_up
rc=$?
cache_mirror_down
assert_eq "1" "$rc" "cache mirror up reports create failure"
assert_eq "0" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "failed create is not marked runner-owned"
assert_eq "0" "$DOCKER_RM_COUNT" "failed create cleanup does not remove mirrors"

reset_cache_fixture
cache_mirror_up
DOCKER_RM_FAIL=1
cache_mirror_down
rc=$?
assert_eq "1" "$rc" "cache mirror cleanup reports remove failure"
assert_eq "1" "$DOCKER_RM_COUNT" "failed cleanup attempts to remove runner-owned mirror"
assert_eq "1" "$MS_CACHE_MIRROR_STARTED_BY_RUN" "failed cleanup keeps runner-owned flag set"
assert_eq "1" "$DOCKER_EXISTS" "failed cleanup leaves mirror marked present"

scenario_end "$CURRENT_SCENARIO"
summary

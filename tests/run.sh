#!/usr/bin/env bash
# tests/run.sh — MediaStack E2E test runner.
#
# Usage:
#   ./tests/run.sh                    # runs smoke
#   ./tests/run.sh smoke              # same
#   ./tests/run.sh fresh-install      # full stack, ~15min / ~7GB cold
#   ./tests/run.sh smoke fresh-install
#   ./tests/run.sh --keep <name>      # leave DinD running on failure
#   ./tests/run.sh --no-cache <name>  # skip mirror + host sideload (forces fresh pulls)
#   ./tests/run.sh --no-preload <name> # skip host image sideload
#   ./tests/run.sh --reset-between a b c # reset DinD state (containers/volumes/
#       networks + repo) between scenarios, so unrelated scenarios can share one
#       DinD without state bleed. Images are sideloaded once, not per scenario.
#       Used by tests/battery.sh. Default off (a plain multi-scenario run shares
#       one DinD with no reset, as before).
#
# Env:
#   MS_TEST_STRIP_SERVICES=homepage,npm,fail2ban   # strip these services from
#       the compose inside DinD before `docker compose up`. Scenario files
#       must check this env var and skip their related assertions.
#   MS_TEST_IMAGE_OVERRIDES="wireguard=ghcr.io/wg-easy/wg-easy:16.0.0"  # swap
#       image tags in the DinD compose copy for candidate-image upgrade preflight
#       ("svc=ref" pairs, comma/space separated). A typo (unknown service, empty
#       ref, malformed pair) aborts the run. Host compose is never touched.
#   MS_CACHE_MIRROR_KEEP=1   # keep ms-registry-mirror running after normal exits
#
# Each scenario file in tests/scenarios/<name>.sh must define run_scenario().
# See tests/README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

# --- Arg parse ---
KEEP_ON_FAIL=0
MS_TEST_NO_CACHE="${MS_TEST_NO_CACHE:-0}"
MS_TEST_SKIP_PRELOAD="${MS_TEST_SKIP_PRELOAD:-0}"
MS_TEST_STRIP_SERVICES="${MS_TEST_STRIP_SERVICES:-}"
MS_TEST_IMAGE_OVERRIDES="${MS_TEST_IMAGE_OVERRIDES:-}"
MS_TEST_RESET_BETWEEN="${MS_TEST_RESET_BETWEEN:-0}"
SCENARIOS=()
for arg in "$@"; do
    case "$arg" in
        --keep)     KEEP_ON_FAIL=1 ;;
        --no-cache) MS_TEST_NO_CACHE=1 ;;
        --no-preload) MS_TEST_SKIP_PRELOAD=1 ;;
        --reset-between) MS_TEST_RESET_BETWEEN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0 ;;
        --*)        echo "unknown flag: $arg" >&2; exit 2 ;;
        *)          SCENARIOS+=("$arg") ;;
    esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=(smoke)
export KEEP_ON_FAIL MS_TEST_NO_CACHE MS_TEST_SKIP_PRELOAD MS_TEST_STRIP_SERVICES MS_TEST_IMAGE_OVERRIDES MS_TEST_RESET_BETWEEN

# Fail fast (before any DinD work) if a service is both image-overridden and
# stripped — the candidate would be silently removed with the stripped service,
# giving false confidence.
if [[ -n "$MS_TEST_IMAGE_OVERRIDES" && -n "$MS_TEST_STRIP_SERVICES" ]]; then
    _strip_set=" $(echo "$MS_TEST_STRIP_SERVICES" | tr ',' ' ') "
    for _ovr in $(echo "$MS_TEST_IMAGE_OVERRIDES" | tr ',' ' '); do
        _osvc="${_ovr%%=*}"
        [[ -z "$_osvc" ]] && continue   # malformed token — the override validator reports it
        if [[ "$_strip_set" == *" $_osvc "* ]]; then
            echo "service '$_osvc' is in both MS_TEST_IMAGE_OVERRIDES and MS_TEST_STRIP_SERVICES — refusing (override would be stripped)" >&2
            exit 2
        fi
    done
fi

# --- Validate scenarios exist before spinning up DinD ---
AVAILABLE=()
for f in tests/scenarios/*.sh; do
    [[ -f "$f" ]] && AVAILABLE+=("$(basename "$f" .sh)")
done
for s in "${SCENARIOS[@]}"; do
    found=0
    for a in "${AVAILABLE[@]}"; do [[ "$a" == "$s" ]] && found=1; done
    if (( ! found )); then
        echo "unknown scenario: $s" >&2
        echo "available: ${AVAILABLE[*]}" >&2
        exit 2
    fi
done

# --- Load libs ---
# shellcheck source=lib/assert.sh
source tests/lib/assert.sh
# shellcheck source=lib/cache.sh
source tests/lib/cache.sh
# shellcheck source=lib/dind.sh
source tests/lib/dind.sh
# shellcheck source=lib/stack.sh
source tests/lib/stack.sh

# --- Trap cleanup ---
runner_should_keep_dind_after_exit() {
    [[ "${KEEP_ALWAYS:-0}" == "1" ]] && return 0
    [[ "${KEEP_ON_FAIL:-0}" == "1" && "${FAIL_COUNT:-0}" -gt 0 ]]
}

on_exit() {
    local rc=$?
    # $1 lets the INT/TERM traps force a signal exit code; else derive from the
    # triggering status / failures. Disable all traps FIRST so the explicit exit
    # below can't re-enter this handler (double cleanup + duplicate summary).
    local code="${1:-}"
    [[ -z "$code" ]] && code=$(( rc != 0 ? rc : (FAIL_COUNT > 0) ))
    trap - EXIT INT TERM
    dind_down
    if ! runner_should_keep_dind_after_exit; then
        cache_mirror_down || echo "warning: registry mirror cleanup failed" >&2
    fi
    summary
    exit "$code"
}
trap 'on_exit' EXIT
trap 'on_exit 130' INT
trap 'on_exit 143' TERM

# --- Pre-flight: host needs working Docker ---
if ! docker info >/dev/null 2>&1; then
    echo "host docker is not available" >&2
    exit 1
fi

# --- Spin up image cache (mirror) before DinD so dockerd picks it up ---
cache_mirror_up || echo "warning: registry mirror failed to start; falling back to direct pulls" >&2

# --- Spin up DinD, copy repo, strip services, sideload host images ---
dind_up || { echo "DinD failed to start" >&2; exit 1; }
dind_copy_repo
dind_override_images || { echo "image override failed (see [image-override] errors above)" >&2; exit 2; }
dind_strip_services
if [[ "$MS_TEST_SKIP_PRELOAD" == "1" ]]; then
    echo -e "${BLUE}[cache]${NC} host image preload skipped"
else
    cache_preload_into_dind
fi

# --- Run each scenario ---
# Source scenarios in the current shell so their pass/fail updates to the
# shared counters persist. A `return 1` from run_scenario just returns from
# the function — the loop moves on to the next scenario.
_ran_one=0
for s in "${SCENARIOS[@]}"; do
    # --reset-between: restore a pristine DinD before every scenario after the
    # first, so a scenario that doesn't reset itself can't inherit prior state.
    if (( _ran_one )) && [[ "$MS_TEST_RESET_BETWEEN" == "1" ]]; then
        dind_reset
    fi
    _ran_one=1
    scenario_begin "$s"
    unset -f run_scenario 2>/dev/null || true
    # shellcheck disable=SC1090
    source_rc=0
    source "tests/scenarios/${s}.sh" || source_rc=$?
    if (( source_rc != 0 )); then
        fail "scenario source failed" "${s} (source returned $source_rc)"
        scenario_end "$s"
        continue
    fi
    if ! declare -F run_scenario >/dev/null; then
        fail "scenario missing run_scenario" "$s"
        scenario_end "$s"
        continue
    fi
    run_scenario || fail "scenario exited non-zero" "${s} (run_scenario returned $?)"
    scenario_end "$s"
done

# summary + exit handled by trap

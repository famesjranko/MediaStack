#!/usr/bin/env bash
# tests/battery.sh — the canonical full DinD battery.
#
# Runs every tests/scenarios/*.sh scenario. It uses run.sh's --reset-between so
# all scenarios share ONE DinD — images are sideloaded once, and each scenario
# still starts pristine (run.sh clears containers/volumes/networks and restores
# a clean repo between scenarios). That is why no scenario grouping is needed: a
# scenario that does not reset itself (e.g. stage1-lan) still cannot inherit a
# previous scenario's state.
#
# image-override is the one scenario that must run on its OWN DinD: it sets
# MS_TEST_IMAGE_OVERRIDES, which patches the compose for the whole DinD and would
# poison every other scenario. It is a fast --no-preload run.
#
# Usage:
#   ./tests/battery.sh          # run the whole battery
#   ./tests/battery.sh --list   # print the plan, run nothing
#   ./tests/battery.sh -h       # this help
#
# Exit code: non-zero if any scenario fails. Needs working host Docker.
# See tests/README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; BLUE=''; BOLD=''; NC=''
fi

# Every scenario present in this tree (adapts per branch — e.g. main has no
# api-matrix). Nothing is hand-listed, so a new scenario is picked up
# automatically and can never be silently skipped.
mapfile -t ALL_SCENARIOS < <(cd tests/scenarios && ls -1 ./*.sh 2>/dev/null | sed -e 's#^\./##' -e 's#\.sh$##')
if (( ${#ALL_SCENARIOS[@]} == 0 )); then
    echo "battery: no scenarios found under tests/scenarios/" >&2
    exit 2
fi

# image-override must be isolated (its MS_TEST_IMAGE_OVERRIDES patches the whole
# DinD compose). Everything else runs in one --reset-between DinD.
MAIN=()
HAVE_IMAGE_OVERRIDE=0
for s in "${ALL_SCENARIOS[@]}"; do
    if [[ "$s" == "image-override" ]]; then
        HAVE_IMAGE_OVERRIDE=1
    else
        MAIN+=("$s")
    fi
done

echo -e "${BOLD}battery: ${#ALL_SCENARIOS[@]} scenarios${NC}"
echo -e "  main (one DinD, --reset-between, ${#MAIN[@]} scenarios): ${MAIN[*]}"
(( HAVE_IMAGE_OVERRIDE )) && echo -e "  isolated: image-override (own DinD, MS_TEST_IMAGE_OVERRIDES)"
if (( LIST_ONLY )); then
    echo -e "${GREEN}battery: --list only; nothing run.${NC}"
    exit 0
fi

FAILED=0
declare -a RESULTS=()

echo ""
echo -e "${BLUE}${BOLD}━━ battery: main run (${#MAIN[@]} scenarios, one DinD, --reset-between) ━━${NC}"
if bash tests/run.sh --reset-between "${MAIN[@]}"; then
    RESULTS+=("PASS  main (${#MAIN[@]})")
else
    rc=$?
    RESULTS+=("${RED}FAIL  main (run.sh exit ${rc})${NC}")
    FAILED=1
fi

if (( HAVE_IMAGE_OVERRIDE )); then
    echo ""
    echo -e "${BLUE}${BOLD}━━ battery: image-override (isolated DinD) ━━${NC}"
    if MS_TEST_IMAGE_OVERRIDES="wireguard=example.invalid/wg:0" bash tests/run.sh --no-preload image-override; then
        RESULTS+=("PASS  image-override (1)")
    else
        rc=$?
        RESULTS+=("${RED}FAIL  image-override (run.sh exit ${rc})${NC}")
        FAILED=1
    fi
fi

echo ""
echo -e "${BOLD}════════════════ battery summary ════════════════${NC}"
for r in "${RESULTS[@]}"; do echo -e "  $r"; done
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
if (( FAILED )); then
    echo -e "${RED}${BOLD}battery: FAILED${NC}"
    exit 1
fi
echo -e "${GREEN}${BOLD}battery: all scenarios passed${NC}"

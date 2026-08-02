#!/usr/bin/env bash
# tests/check.sh — canonical local check wrapper: one command surface over the
# proven lint, type, unit, wizard, and DinD runners (tests/lint.sh,
# tests/unit.sh, tests/ci-scenarios.sh, tests/run.sh, tests/battery.sh). It
# wraps them; it does not reimplement their file discovery or logic.
#
# Usage:
#   ./tests/check.sh          # default tier
#   ./tests/check.sh fast     # edit-loop checks: shellcheck, shfmt, ruff, mypy,
#                              # secrets. No DinD or service containers.
#   ./tests/check.sh full     # everything, including the complete DinD battery.
#   ./tests/check.sh lint     # single stage: shellcheck sweep only.
#   ./tests/check.sh shfmt    # single stage: shell formatting only.
#   ./tests/check.sh ruff     # single stage: python lint + format check only.
#   ./tests/check.sh mypy     # single stage: type check only.
#   ./tests/check.sh secrets  # single stage: pinned gitleaks over the tree.
#   ./tests/check.sh secrets-history
#                             # single stage: pinned gitleaks over all history.
#   ./tests/check.sh unit     # single stage: tests/unit.sh only.
#   ./tests/check.sh wizard   # single stage: image-free wizard scenarios only.
#   ./tests/check.sh -h       # this help
#
# Tiers are cumulative and cost-ordered:
#   fast    - lint (tests/lint.sh), shell formatting (tests/format.sh), python
#             lint + format (ruff), python types (mypy) and the secret scan
#             over the working tree (tests/secret-scan.sh). It starts no DinD
#             or service containers; ShellCheck uses Docker unless the pinned
#             native version is installed. History is a separate selector.
#   default - fast + tests/unit.sh (adds compose render, host unit tests,
#             shell syntax and Python bytecode) + the image-free
#             wizard-ui scenarios (tests/ci-scenarios.sh via tests/run.sh).
#             This is the PR gate's local equivalent.
#   full    - default + tests/battery.sh (the complete DinD scenario battery).
#
# lint/shfmt/ruff/mypy/secrets/secrets-history/unit/wizard are single-stage
# selectors, not tiers: each
# runs exactly one stage and nothing else, so a caller (CI) can spread the
# pipeline across parallel jobs without a stage running twice. tests/unit.sh
# reruns the shellcheck sweep and the mypy check internally as its own tiers
# 2 and 4; a caller that already ran `lint`/`mypy` as separate jobs sets
# MS_UNIT_SKIP_SHELLCHECK=1 / MS_UNIT_SKIP_MYPY=1 before `./tests/check.sh
# unit` to avoid paying for them twice. tests/unit.sh reports a skipped tier
# as SKIP, never as OK — an unselected stage must stay visibly not-run.
#
# Stages run cheapest-first and stop at the FIRST failure (fail-fast): a
# failing lint stage means the DinD battery never starts. Every failure names
# its tier and the exact underlying command, so it can be re-run in isolation.
#
# Exit code: non-zero if any stage fails, or on an unrecognised tier argument.
# See tests/README.md "Command contract".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 2

if (($# > 1)); then
    echo "check: too many arguments — usage: ./tests/check.sh [fast|default|full|lint|shfmt|ruff|mypy|secrets|secrets-history|unit|wizard]" >&2
    exit 2
fi

arg="${1:-default}"
STAGE=""
case "$arg" in
    -h | --help)
        sed -n '2,/^$/p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    fast | default | full) TIER="$arg" ;;
    lint | shfmt | ruff | mypy | secrets | secrets-history | unit | wizard) STAGE="$arg" ;;
    *)
        echo "check: unknown tier '$arg' — usage: ./tests/check.sh [fast|default|full|lint|shfmt|ruff|mypy|secrets|secrets-history|unit|wizard]" >&2
        exit 2
        ;;
esac

if [[ -t 1 ]]; then
    BLUE=$'\033[0;34m'
    RED=$'\033[0;31m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    BLUE=''
    RED=''
    BOLD=''
    NC=''
fi

# stage <tier> <label> <shown-command> <argv...> — runs one stage and, on a
# non-zero exit, names the tier/label/command and exits immediately (fail-fast:
# no costlier later stage runs after a cheaper one has already failed).
stage() {
    local tier="$1" label="$2" shown_cmd="$3" rc
    shift 3
    echo "${BOLD}${BLUE}== [$tier] $label ==${NC}"
    "$@"
    rc=$?
    if ((rc != 0)); then
        echo "${RED}${BOLD}check: [$tier] FAILED${NC} stage '$label' — command: $shown_cmd (exit $rc)" >&2
        exit "$rc"
    fi
}

# tools.toml [mypy] records this pin; MYPY_CACHE_DIR is set outside the tree
# since mypy self-ignores .mypy_cache/ (invisible to git status).
mypy_type_check() {
    local cache_dir rc
    cache_dir=$(mktemp -d) || return 1
    MYPY_CACHE_DIR="$cache_dir" uv tool run --from mypy==1.20.2 \
        --with types-PyYAML==6.0.12.20260724 mypy .
    rc=$?
    rm -rf "$cache_dir"
    return "$rc"
}

# tools.toml [ruff] records this pin; RUFF_CACHE_DIR is set outside the tree
# since ruff self-ignores .ruff_cache/.
# The lint pass runs first because its findings explain a format diff.
ruff_python_check() {
    local cache_dir rc
    cache_dir=$(mktemp -d) || return 1
    RUFF_CACHE_DIR="$cache_dir" uv tool run ruff@0.15.22 check .
    rc=$?
    if ((rc == 0)); then
        RUFF_CACHE_DIR="$cache_dir" uv tool run ruff@0.15.22 format --check .
        rc=$?
    fi
    rm -rf "$cache_dir"
    return "$rc"
}

# tools.toml [gitleaks] is the single source of truth for the binary; install
# is idempotent and re-verifies the cached pin's sha256 on every run. Blocking
# and not on the left of a pipeline: the gate reconciles its findings against
# tests/secret-scan.expected and returns non-zero on a difference in either
# direction.
secret_scan_gate() {
    local rc
    ./tests/secret-scan.sh install
    rc=$?
    if ((rc == 0)); then
        ./tests/secret-scan.sh gate-tree
        rc=$?
    fi
    return "$rc"
}

# Not in any tier: the history scan re-reads every commit, so its declared
# findings multiply as revisions accumulate and an unrelated edit to a file
# that already carries one turns the tier red. It guards publication, not the
# edit loop - run `./tests/check.sh secrets-history` before any push.
secret_scan_history_gate() {
    local rc
    ./tests/secret-scan.sh install
    rc=$?
    if ((rc == 0)); then
        ./tests/secret-scan.sh gate-history
        rc=$?
    fi
    return "$rc"
}

# Same image-free scenario set + invocation the wizard-ui CI job uses. Fails
# on an empty set rather than letting run.sh fall back to its image-pulling
# default with no scenario arguments.
wizard_scenarios() {
    local scenarios
    local -a scenario_args
    scenarios=$(bash tests/ci-scenarios.sh) || return 1
    [[ -n "${scenarios// /}" ]] || {
        echo "check: ci-scenarios.sh produced no scenarios" >&2
        return 1
    }
    read -r -a scenario_args <<<"$scenarios"
    MS_TEST_SKIP_PRELOAD=1 bash tests/run.sh "${scenario_args[@]}"
}

# Single-stage selector: run exactly one stage and nothing else, then exit.
if [[ -n "$STAGE" ]]; then
    case "$STAGE" in
        lint)
            stage lint "lint: shellcheck" "./tests/lint.sh --severity=warning" \
                ./tests/lint.sh --severity=warning
            ;;
        shfmt)
            stage shfmt "format: shfmt" "./tests/format.sh check" \
                ./tests/format.sh check
            ;;
        ruff)
            stage ruff "python: ruff" \
                "RUFF_CACHE_DIR=<tmp> uv tool run ruff@0.15.22 check . && ... format --check ." \
                ruff_python_check
            ;;
        mypy)
            stage mypy "type: mypy" \
                "MYPY_CACHE_DIR=<tmp> uv tool run --from mypy==1.20.2 --with types-PyYAML==6.0.12.20260724 mypy ." \
                mypy_type_check
            ;;
        secrets)
            stage secrets "secrets: gitleaks tree" \
                "./tests/secret-scan.sh install && ... gate-tree" \
                secret_scan_gate
            ;;
        secrets-history)
            stage secrets-history "secrets: gitleaks history" \
                "./tests/secret-scan.sh install && ... gate-history" \
                secret_scan_history_gate
            ;;
        unit)
            stage unit "unit: tests/unit.sh (compose, host units, syntax, bytecode, types)" \
                "bash tests/unit.sh" bash tests/unit.sh
            ;;
        wizard)
            stage wizard "wizard: image-free scenarios" \
                'MS_TEST_SKIP_PRELOAD=1 bash tests/run.sh $(bash tests/ci-scenarios.sh)' \
                wizard_scenarios
            ;;
    esac
    exit 0
fi

stage fast "lint: shellcheck" "./tests/lint.sh --severity=warning" \
    ./tests/lint.sh --severity=warning
stage fast "format: shfmt" "./tests/format.sh check" \
    ./tests/format.sh check
stage fast "python: ruff" \
    "RUFF_CACHE_DIR=<tmp> uv tool run ruff@0.15.22 check . && ... format --check ." \
    ruff_python_check
stage fast "type: mypy" \
    "MYPY_CACHE_DIR=<tmp> uv tool run --from mypy==1.20.2 --with types-PyYAML==6.0.12.20260724 mypy ." \
    mypy_type_check
stage fast "secrets: gitleaks tree" \
    "./tests/secret-scan.sh install && ... gate-tree" \
    secret_scan_gate
[[ "$TIER" == "fast" ]] && exit 0

stage default "unit: tests/unit.sh (compose, host units, syntax, bytecode, types)" \
    "bash tests/unit.sh" bash tests/unit.sh
stage default "wizard: image-free scenarios" \
    'MS_TEST_SKIP_PRELOAD=1 bash tests/run.sh $(bash tests/ci-scenarios.sh)' \
    wizard_scenarios
[[ "$TIER" == "default" ]] && exit 0

stage full "dind: full battery" "bash tests/battery.sh" bash tests/battery.sh
exit 0

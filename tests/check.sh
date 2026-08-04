#!/usr/bin/env bash
# tests/check.sh — canonical local check wrapper: one command surface over the
# proven lint, type, unit, wizard, and DinD runners (tests/lint.sh,
# tests/unit.sh, tests/ci-scenarios.sh, tests/run.sh, tests/battery.sh). It
# wraps them. The two Python selectors share tracked-file discovery here so
# Ruff and mypy cannot silently inspect different or empty populations.
#
# Usage:
#   ./tests/check.sh          # default tier
#   ./tests/check.sh fast     # static checks: shellcheck, shfmt, ruff, mypy,
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
#   ./tests/check.sh warm-python
#                             # fetch the pinned ruff + mypy toolchains via uv
#                             # (no checks run). Exists so a caller (CI) can
#                             # retry the PyPI download alone, then run the
#                             # real ruff/mypy stage exactly once.
#   ./tests/check.sh install  # fetch + verify every pinned dev tool from
#                              # tools.toml (shellcheck, shfmt, gitleaks) into
#                              # the local tool cache. One-time per machine;
#                              # lets the fast tier run without Docker.
#   ./tests/check.sh -h       # this help
#
# Tiers are cumulative and run in the fixed order below:
#   fast    - lint (tests/lint.sh), shell formatting (tests/format.sh), python
#             lint + format (ruff), python types (mypy) and the secret scan
#             over the working tree (tests/secret-scan.sh). It starts no DinD
#             or service containers; ShellCheck runs from a native or cached
#             pinned binary (`./tests/check.sh install`) and falls back to
#             Docker otherwise. History is a separate selector.
#   default - fast + tests/unit.sh (adds compose render, host unit tests,
#             shell syntax and Python bytecode) + the image-free
#             wizard-ui scenarios (tests/ci-scenarios.sh via tests/run.sh).
#             This is the PR gate's local equivalent.
#   full    - default + tests/battery.sh (the complete DinD scenario battery).
#
# lint/shfmt/ruff/mypy/secrets/secrets-history/unit/wizard/warm-python/install
# are single-stage selectors, not tiers: each
# runs exactly one stage and nothing else, so a caller (CI) can spread the
# pipeline across parallel jobs without a stage running twice. tests/unit.sh
# reruns the shellcheck sweep and the mypy check internally as its own tiers
# 2 and 4; a caller that already ran `lint`/`mypy` as separate jobs sets
# MS_UNIT_SKIP_SHELLCHECK=1 / MS_UNIT_SKIP_MYPY=1 before `./tests/check.sh
# unit` to avoid paying for them twice. The cumulative default/full path does
# this after its fast stages pass. tests/unit.sh reports a skipped tier as
# SKIP, never as OK — an unselected stage must stay visibly not-run.
#
# Stages run in the documented order and stop at the FIRST failure (fail-fast): a
# failing lint stage means the DinD battery never starts. Every failure names
# its tier and the exact underlying command, so it can be re-run in isolation.
#
# Exit code: non-zero if any stage fails, or on an unrecognised tier argument.
# See tests/README.md "Command contract".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 2

if (($# > 1)); then
    echo "check: too many arguments — usage: ./tests/check.sh [fast|default|full|lint|shfmt|ruff|mypy|secrets|secrets-history|unit|wizard|warm-python|install]" >&2
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
    lint | shfmt | ruff | mypy | secrets | secrets-history | unit | wizard | warm-python | install) STAGE="$arg" ;;
    *)
        echo "check: unknown tier '$arg' — usage: ./tests/check.sh [fast|default|full|lint|shfmt|ruff|mypy|secrets|secrets-history|unit|wizard|warm-python|install]" >&2
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

# Populate PYTHON_FILES once per Python selector from the tracked tree. Ruff
# otherwise exits zero over an empty directory, and both tools accepting `.`
# gives the selectors a different population from the tracked-file gates in
# tests/unit.sh.
PYTHON_FILES=()
discover_tracked_python() {
    local files_out files_err rc
    files_out=$(mktemp) || return 1
    files_err=$(mktemp) || {
        rm -f "$files_out"
        return 1
    }

    git ls-files -z '*.py' >"$files_out" 2>"$files_err"
    rc=$?
    if ((rc != 0)); then
        echo "check: python file discovery failed — git ls-files '*.py': $(tr '\n' ' ' <"$files_err")" >&2
        rm -f "$files_out" "$files_err"
        return "$rc"
    fi

    mapfile -d '' -t PYTHON_FILES <"$files_out"
    rm -f "$files_out" "$files_err"
    if ((${#PYTHON_FILES[@]} == 0)); then
        echo "check: python population empty — git ls-files '*.py' matched no files" >&2
        return 1
    fi
}

# Single source for the python tool pins: tools.toml. The CI uv caches key on
# its hash, so a version bump there rotates them. Empty result fails the stage.
tool_pin() {
    local value
    value=$(awk -v section="[$1]" -v key="$2" '
        $0 == section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $1 == key { gsub(/"/, "", $3); print $3; exit }
    ' tools.toml)
    if [[ -z $value ]]; then
        echo "check: pin '$2' missing from tools.toml [$1]" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# MYPY_CACHE_DIR is set outside the tree since mypy self-ignores .mypy_cache/
# (invisible to git status). The accepted config guarantee is asserted rather
# than trusting mypy's permissive default.
mypy_type_check() {
    local cache_dir rc mypy_pin stubs_pin
    discover_tracked_python || return $?
    mypy_pin=$(tool_pin mypy version) || return 1
    stubs_pin=$(tool_pin mypy types_pyyaml_version) || return 1
    if ! awk '
        /^\[/{ in_section = ($0 == "[tool.mypy]") }
        in_section && /^check_untyped_defs[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit !found }
    ' pyproject.toml; then
        echo "check: python types config missing check_untyped_defs — pyproject.toml [tool.mypy] must set check_untyped_defs = true" >&2
        return 1
    fi
    if ! awk '
        /^\[/{ in_section = ($0 == "[tool.mypy]") }
        in_section && /^disallow_untyped_defs[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit !found }
    ' pyproject.toml; then
        echo "check: python types config missing disallow_untyped_defs — pyproject.toml [tool.mypy] must set disallow_untyped_defs = true" >&2
        return 1
    fi
    cache_dir=$(mktemp -d) || return 1
    MYPY_CACHE_DIR="$cache_dir" uv tool run --from "mypy==$mypy_pin" \
        --with "types-PyYAML==$stubs_pin" mypy --python-version 3.9 \
        "${PYTHON_FILES[@]}"
    rc=$?
    rm -rf "$cache_dir"
    return "$rc"
}

# RUFF_CACHE_DIR is set outside the tree since ruff self-ignores .ruff_cache/.
# The lint pass runs first because its findings explain a format diff.
ruff_python_check() {
    local cache_dir rc ruff_pin
    discover_tracked_python || return $?
    ruff_pin=$(tool_pin ruff version) || return 1
    cache_dir=$(mktemp -d) || return 1
    RUFF_CACHE_DIR="$cache_dir" uv tool run "ruff@$ruff_pin" check "${PYTHON_FILES[@]}"
    rc=$?
    if ((rc == 0)); then
        RUFF_CACHE_DIR="$cache_dir" uv tool run "ruff@$ruff_pin" format --check "${PYTHON_FILES[@]}"
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

# Download-only warm-up for the uv-delivered python tools: resolves the pinned
# ruff and mypy toolchains so a caller (CI) can retry PyPI transience here and
# then run the real check stage exactly once — a genuine lint or type failure
# is never retried. Runs no checks; --version proves each tool is executable.
warm_python_tools() {
    local ruff_pin mypy_pin stubs_pin
    ruff_pin=$(tool_pin ruff version) || return 1
    mypy_pin=$(tool_pin mypy version) || return 1
    stubs_pin=$(tool_pin mypy types_pyyaml_version) || return 1
    uv tool run "ruff@$ruff_pin" --version || return 1
    uv tool run --from "mypy==$mypy_pin" --with "types-PyYAML==$stubs_pin" \
        mypy --version
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
                "RUFF_CACHE_DIR=<tmp> uv tool run ruff@<tools.toml [ruff] version> check <tracked-python> && ... format --check <tracked-python>" \
                ruff_python_check
            ;;
        mypy)
            stage mypy "type: mypy" \
                "MYPY_CACHE_DIR=<tmp> uv tool run --from mypy==<tools.toml [mypy] version> --with types-PyYAML==<tools.toml [mypy] types_pyyaml_version> mypy --python-version 3.9 <tracked-python>" \
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
        warm-python)
            stage warm-python "warm: pinned python tools (download only)" \
                "uv tool run ruff@<pin> --version && uv tool run --from mypy==<pin> --with types-PyYAML==<pin> mypy --version" \
                warm_python_tools
            ;;
        install)
            stage install "install: shellcheck" "./tests/lint.sh install" \
                ./tests/lint.sh install
            stage install "install: shfmt" "./tests/format.sh install" \
                ./tests/format.sh install
            stage install "install: gitleaks" "./tests/secret-scan.sh install" \
                ./tests/secret-scan.sh install
            ;;
    esac
    exit 0
fi

stage fast "lint: shellcheck" "./tests/lint.sh --severity=warning" \
    ./tests/lint.sh --severity=warning
stage fast "format: shfmt" "./tests/format.sh check" \
    ./tests/format.sh check
stage fast "python: ruff" \
    "RUFF_CACHE_DIR=<tmp> uv tool run ruff@<tools.toml [ruff] version> check <tracked-python> && ... format --check <tracked-python>" \
    ruff_python_check
stage fast "type: mypy" \
    "MYPY_CACHE_DIR=<tmp> uv tool run --from mypy==<tools.toml [mypy] version> --with types-PyYAML==<tools.toml [mypy] types_pyyaml_version> mypy --python-version 3.9 <tracked-python>" \
    mypy_type_check
stage fast "secrets: gitleaks tree" \
    "./tests/secret-scan.sh install && ... gate-tree" \
    secret_scan_gate
[[ "$TIER" == "fast" ]] && exit 0

stage default "unit: tests/unit.sh (compose, host units, syntax, bytecode)" \
    "MS_UNIT_SKIP_SHELLCHECK=1 MS_UNIT_SKIP_MYPY=1 bash tests/unit.sh" \
    env MS_UNIT_SKIP_SHELLCHECK=1 MS_UNIT_SKIP_MYPY=1 bash tests/unit.sh
stage default "wizard: image-free scenarios" \
    'MS_TEST_SKIP_PRELOAD=1 bash tests/run.sh $(bash tests/ci-scenarios.sh)' \
    wizard_scenarios
[[ "$TIER" == "default" ]] && exit 0

stage full "dind: full battery" "bash tests/battery.sh" bash tests/battery.sh
exit 0

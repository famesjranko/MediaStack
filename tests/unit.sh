#!/usr/bin/env bash
# tests/unit.sh — MediaStack host unit + static-validation runner.
#
# Single source of truth for the host-side "static validation + unit test" tier,
# invoked identically by developers, agents, and CI (same pattern as tests/lint.sh).
#
# Runs the following, aggregating failures (it never aborts on the first one, so
# one run reports every problem):
#   1. shell syntax    — bash -n over every tracked *.sh + the mediastack launcher
#   2. shellcheck      — ./tests/lint.sh --severity=warning (the repo lint gate)
#   3. python bytecode — py_compile over every tracked *.py
#   4. python types    — pinned mypy (tools.toml [mypy]) over every tracked *.py
#   5. compose render  — docker compose config across the profile combinations
#   6. host unit tests — every tests/unit/*.sh, each under a 300s timeout
#   7. publish guards  — scripts/dev/sync-public-selftest.sh (skipped only where
#                        scripts/dev/ is absent; fails if it is present and rg is not)
#
# Tiers 2 and 4 duplicate a stage a caller may already have run as its own gate
# (e.g. CI's lint-shellcheck / type-mypy jobs). Set MS_UNIT_SKIP_SHELLCHECK=1 /
# MS_UNIT_SKIP_MYPY=1 to skip them here; a skipped tier prints SKIP, never OK,
# so an unselected stage is always visibly not-run rather than a false green.
#
# Needs the docker CLI: tier 5 renders the compose file, and tier 2 runs the
# pinned linter as a docker image (via tests/lint.sh). It also needs uv on PATH
# for tier 4. It starts no service containers, but it is NOT a "no Docker" tier.
#
# Under GitHub Actions (GITHUB_ACTIONS set) it emits ::group::/::error::
# annotations; run from a terminal it prints plain headers instead. Exits
# non-zero if any tier fails.
#
# Usage:
#   ./tests/unit.sh        # run the whole tier
#   ./tests/unit.sh -h     # this help
#
# See tests/README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 2

for arg in "$@"; do
    case "$arg" in
        -h | --help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "unit: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# Annotation helpers: GitHub Actions ::group::/::error::, or plain headers on a terminal.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    group() { printf '::group::%s\n' "$1"; }
    endgroup() { printf '::endgroup::\n'; }
    err() { printf '::error title=%s::%s\n' "$1" "$2"; }
else
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
    group() { printf '%s== %s ==%s\n' "${BOLD}${BLUE}" "$1" "$NC"; }
    endgroup() { :; }
    err() { printf '%sERROR [%s]%s %s\n' "$RED" "$1" "$NC" "$2" >&2; }
fi

fail=0

# Discovery must fail loudly. `git ls-files` can exit nonzero after emitting a
# partial listing, and a subshell pipeline would accept that as the population.
DISCOVER_OUT=$(mktemp) || exit 1
DISCOVER_ERR=$(mktemp) || exit 1
trap 'rm -f "$DISCOVER_OUT" "$DISCOVER_ERR"' EXIT

discover() {
    git ls-files -z "$@" >"$DISCOVER_OUT" 2>"$DISCOVER_ERR"
}

discovery_failed() {
    err "file discovery failed" "git ls-files $* — $(tr '\n' ' ' <"$DISCOVER_ERR")"
}

# --- 1. shell syntax ---------------------------------------------------------
# Same file discovery tests/lint.sh uses, so "what is shell here" has exactly
# one definition.
group "shell syntax"
n=0
discover '*.sh' 'mediastack' || {
    discovery_failed '*.sh' 'mediastack'
    fail=1
}
while IFS= read -r -d '' f; do
    n=$((n + 1))
    if ! bash -n "$f"; then
        err "shell syntax failed" "$f"
        fail=1
    fi
done <"$DISCOVER_OUT"
# Fail closed: an empty population (non-git export) would otherwise check
# nothing and report success.
if ((n == 0)); then
    err "shell syntax population empty" "git ls-files '*.sh' 'mediastack' matched no files — not a git checkout?"
    fail=1
else
    echo "OK: shell syntax ($n files)"
fi
endgroup

# --- 2. shellcheck -----------------------------------------------------------
group "shellcheck"
if [[ "${MS_UNIT_SKIP_SHELLCHECK:-0}" == "1" ]]; then
    echo "SKIP: shellcheck (MS_UNIT_SKIP_SHELLCHECK=1 — run by a separate caller)"
elif ! ./tests/lint.sh --severity=warning; then
    err "shellcheck found warnings" "run ./tests/lint.sh --severity=warning"
    fail=1
fi
endgroup

# --- 3. python bytecode ------------------------------------------------------
group "python bytecode"
n=0
discover '*.py' || {
    discovery_failed '*.py'
    fail=1
}
while IFS= read -r -d '' f; do
    n=$((n + 1))
    if ! python3 -m py_compile "$f"; then
        err "python compile failed" "$f"
        fail=1
    fi
done <"$DISCOVER_OUT"
if ((n == 0)); then
    err "python bytecode population empty" "git ls-files '*.py' matched no files — not a git checkout?"
    fail=1
else
    echo "OK: python bytecode ($n files)"
fi
endgroup

# --- 4. python types ----------------------------------------------------------
# mypy 2.x rejects --python-version 3.9 on the CLI and silently proceeds at 3.10
# when the same value comes from pyproject.toml instead — the pin is load-bearing.
# check_untyped_defs is asserted directly rather than trusted to still be set.
group "python types"
if [[ "${MS_UNIT_SKIP_MYPY:-0}" == "1" ]]; then
    echo "SKIP: python types (MS_UNIT_SKIP_MYPY=1 — run by a separate caller)"
else
    n=0
    discover '*.py' || {
        discovery_failed '*.py'
        fail=1
    }
    mapfile -d '' -t py_files <"$DISCOVER_OUT"
    n=${#py_files[@]}
    if ((n == 0)); then
        err "python types population empty" "git ls-files '*.py' matched no files — not a git checkout?"
        fail=1
    elif ! awk '
        /^\[/{ in_section = ($0 == "[tool.mypy]") }
        in_section && /^check_untyped_defs[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit !found }
    ' pyproject.toml; then
        err "python types config missing check_untyped_defs" "pyproject.toml [tool.mypy] must set check_untyped_defs = true"
        fail=1
    elif ! command -v uv >/dev/null 2>&1; then
        err "python types cannot run" "install uv — mypy is invoked via 'uv tool run --from mypy==1.20.2 ...' (tools.toml [mypy])"
        fail=1
    else
        # Cache dir outside the tree: mypy self-ignores .mypy_cache/, invisible to
        # plain git status, so a stray one under the repo would go unnoticed.
        mypy_cache=$(mktemp -d) || {
            err "python types" "mktemp -d for MYPY_CACHE_DIR failed"
            fail=1
        }
        if [[ -n "${mypy_cache:-}" ]]; then
            if ! MYPY_CACHE_DIR="$mypy_cache" uv tool run --from mypy==1.20.2 \
                --with types-PyYAML==6.0.12.20260724 mypy --python-version 3.9 \
                "${py_files[@]}"; then
                err "python types found errors" \
                    "run: uv tool run --from mypy==1.20.2 --with types-PyYAML==6.0.12.20260724 mypy ."
                fail=1
            else
                echo "OK: python types ($n files)"
            fi
            rm -rf "$mypy_cache"
        fi
    fi
fi
endgroup

# --- 5. compose render -------------------------------------------------------
# --env-file .env.example: a developer's real .env is never read, moved, or
# clobbered, so a hard kill (uncatchable SIGKILL) has nothing to orphan.
group "compose render"
if [[ ! -f .env.example ]]; then
    err "compose render failed" ".env.example missing — cannot render compose"
    fail=1
else
    for args in \
        "" \
        "--profile proxy" \
        "--profile remote" \
        "--profile proxy --profile remote" \
        "--profile subtitles" \
        "--profile autoheal"; do
        label="${args:-default}"
        # shellcheck disable=SC2086  # intentional word-split into compose flags
        if docker compose --env-file .env.example $args config --quiet; then
            echo "OK: compose $label"
        else
            err "compose render failed" "$label"
            fail=1
        fi
    done
fi
endgroup

# --- 6. host unit tests ------------------------------------------------------
shopt -s nullglob
unit_tests=(tests/unit/*.sh)
shopt -u nullglob
if ((${#unit_tests[@]} == 0)); then
    err "host unit population empty" "tests/unit/*.sh matched no files"
    fail=1
else
    echo "OK: host unit tests (${#unit_tests[@]} files)"
    for f in "${unit_tests[@]}"; do
        name="$(basename "$f" .sh)"
        group "unit: $name"
        # Per-test timeout so a stuck test (e.g. a non-TTY re-prompt loop that never
        # reaches EOF) fails fast instead of hanging the run.
        timeout 300 bash "$f"
        rc=$?
        endgroup
        if ((rc != 0)); then
            if ((rc == 124)); then
                err "unit timed out" "$name (exceeded 300s — likely a hang)"
            else
                err "unit failed" "$name"
            fi
            fail=1
        fi
    done
fi

# --- 7. sync-public publish guards -------------------------------------------
# Absence is the legitimate skip: the public mirror strips scripts/dev/ but runs this same unit.sh.
group "sync-public guards"
if [[ ! -e scripts/dev/sync-public-selftest.sh ]]; then
    echo "SKIP: sync-public selftest (scripts/dev/sync-public-selftest.sh absent — public mirror)"
elif [[ ! -x scripts/dev/sync-public-selftest.sh ]]; then
    err "sync-public selftest is not executable" "chmod +x scripts/dev/sync-public-selftest.sh"
    fail=1
elif ! command -v rg >/dev/null 2>&1; then
    err "sync-public selftest cannot run" "install ripgrep (rg) — the publish guards need it"
    fail=1
else
    timeout 300 scripts/dev/sync-public-selftest.sh
    rc=$?
    if ((rc != 0)); then
        if ((rc == 124)); then
            err "sync-public selftest timed out" "exceeded 300s — likely a hang"
        else
            err "sync-public selftest failed" "scripts/dev/sync-public-selftest.sh"
        fi
        fail=1
    fi
fi
endgroup

exit "$fail"

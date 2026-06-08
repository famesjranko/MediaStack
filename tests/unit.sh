#!/usr/bin/env bash
# tests/unit.sh — MediaStack host unit + static-validation runner.
#
# The single source of truth for the host-side "static validation + unit test"
# tier, invoked identically by developers, agents, and CI — the same pattern as
# tests/lint.sh. The PR-check workflow calls this instead of inlining the loop,
# so there is exactly one definition to keep green.
#
# Runs the following, aggregating failures (it never aborts on the first one, so
# one run reports every problem):
#   1. shell syntax    — bash -n over every tracked *.sh + the mediastack launcher
#   2. shellcheck      — ./tests/lint.sh --severity=warning (the repo lint gate)
#   3. python bytecode — py_compile over every tracked *.py
#   4. compose render  — docker compose config across the profile combinations
#   5. host unit tests — every tests/unit/*.sh, each under a 300s timeout
#
# Needs the docker CLI: tier 4 renders the compose file, and tier 2 runs the
# pinned linter as a docker image (via tests/lint.sh). It starts no service
# containers, but it is NOT a "no Docker" tier.
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
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unit: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Annotation helpers. GitHub Actions folds ::group::/::endgroup:: and surfaces
# ::error:: in the run summary; a plain terminal gets readable headers instead.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    group()    { printf '::group::%s\n' "$1"; }
    endgroup() { printf '::endgroup::\n'; }
    err()      { printf '::error title=%s::%s\n' "$1" "$2"; }
else
    if [[ -t 1 ]]; then
        BLUE=$'\033[0;34m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    else
        BLUE=''; RED=''; BOLD=''; NC=''
    fi
    group()    { printf '%s== %s ==%s\n' "${BOLD}${BLUE}" "$1" "$NC"; }
    endgroup() { :; }
    err()      { printf '%sERROR [%s]%s %s\n' "$RED" "$1" "$NC" "$2" >&2; }
fi

fail=0

# --- 1. shell syntax ---------------------------------------------------------
# Same file discovery tests/lint.sh uses, so "what is shell here" has exactly
# one definition.
group "shell syntax"
while IFS= read -r -d '' f; do
    if ! bash -n "$f"; then
        err "shell syntax failed" "$f"
        fail=1
    fi
done < <(git ls-files -z '*.sh' 'mediastack')
endgroup

# --- 2. shellcheck -----------------------------------------------------------
# Regression gate: fail on any shellcheck WARNING or ERROR. Config + curated
# suppressions live in .shellcheckrc; tests/lint.sh pins the engine (0.11.0).
group "shellcheck"
if ! ./tests/lint.sh --severity=warning; then
    err "shellcheck found warnings" "run ./tests/lint.sh --severity=warning"
    fail=1
fi
endgroup

# --- 3. python bytecode ------------------------------------------------------
group "python bytecode"
while IFS= read -r -d '' f; do
    if ! python3 -m py_compile "$f"; then
        err "python compile failed" "$f"
        fail=1
    fi
done < <(git ls-files -z '*.py')
endgroup

# --- 4. compose render -------------------------------------------------------
# Render with --env-file .env.example so a developer's real .env is never read,
# moved, or clobbered: there is no stand-in to restore and nothing a hard kill
# (uncatchable SIGKILL, which a trap cannot cover) could orphan.
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

# --- 5. host unit tests ------------------------------------------------------
for f in tests/unit/*.sh; do
    name="$(basename "$f" .sh)"
    group "unit: $name"
    # Per-test timeout so a stuck test (e.g. a non-TTY re-prompt loop that never
    # reaches EOF) fails fast instead of hanging the run.
    timeout 300 bash "$f"
    rc=$?
    endgroup
    if (( rc != 0 )); then
        if (( rc == 124 )); then
            err "unit timed out" "$name (exceeded 300s — likely a hang)"
        else
            err "unit failed" "$name"
        fi
        fail=1
    fi
done

exit "$fail"

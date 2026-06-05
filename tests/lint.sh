#!/usr/bin/env bash
# tests/lint.sh — MediaStack shell lint runner (shellcheck).
#
# Single source of truth for "is the shell clean", invoked identically by
# developers, agents, and CI. The repo-specific flags live in .shellcheckrc
# (repo root) which shellcheck reads automatically — so this runner only has to
# pick a shellcheck and hand it the file set.
#
# Usage:
#   ./tests/lint.sh                          # lint every tracked *.sh + mediastack
#   ./tests/lint.sh scripts/lib/validators.sh  # lint only the named file(s)
#   ./tests/lint.sh --severity=error         # passthrough: only fail on errors
#   ./tests/lint.sh --severity=warning scripts/setup/stack.sh
#
# Pins the shellcheck version (SC_VERSION) so developers, agents, and CI all
# analyse with the EXACT same engine — different shellcheck versions disagree on
# which warnings fire, which would make the gate non-reproducible (e.g. the
# GitHub runner's native 0.9.0 vs a newer local build). A native shellcheck is
# used only when it matches the pinned version; otherwise the pinned docker image
# runs. Exits non-zero on findings at or above the chosen severity.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Pinned, never floated to :stable/:latest. To bump: change this, then re-run
# `./tests/lint.sh --severity=warning` and confirm the tree is still clean.
SC_VERSION="0.11.0"
SC_IMAGE="koalaman/shellcheck:v${SC_VERSION}"

# Split args: shellcheck passthrough flags (anything starting with -) vs. files.
sc_flags=()
files=()
for arg in "$@"; do
    case "$arg" in
        -*) sc_flags+=("$arg") ;;
        *)  files+=("$arg") ;;
    esac
done

# Default file set: every tracked shell file. Same discovery the CI shell-syntax
# loop uses (git ls-files -z '*.sh' 'mediastack'), so "what is shell here" has
# exactly one definition.
if (( ${#files[@]} == 0 )); then
    mapfile -d '' -t files < <(git ls-files -z '*.sh' 'mediastack')
fi

if (( ${#files[@]} == 0 )); then
    echo "lint: no shell files to check"
    exit 0
fi

# Use a native shellcheck ONLY when it is exactly the pinned version; otherwise
# fall back to the pinned docker image, so the analysing engine is identical
# everywhere. CI's runner ships an older native shellcheck, so CI takes the
# docker path too — byte-for-byte the same as local.
native_version=""
if command -v shellcheck >/dev/null 2>&1; then
    native_version="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
fi

if [[ "$native_version" == "$SC_VERSION" ]]; then
    exec shellcheck "${sc_flags[@]}" "${files[@]}"
elif command -v docker >/dev/null 2>&1; then
    exec docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt "$SC_IMAGE" \
        "${sc_flags[@]}" "${files[@]}"
else
    echo "lint: need docker, or shellcheck $SC_VERSION natively, on PATH" >&2
    exit 2
fi

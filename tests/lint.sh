#!/usr/bin/env bash
# tests/lint.sh — MediaStack shell lint runner (shellcheck), pinned in
# tools.toml [shellcheck].
#
# Single source of truth for "is the shell clean", invoked identically by
# developers, agents, and CI. The repo-specific flags live in .shellcheckrc
# (repo root) which shellcheck reads automatically — so this runner only has to
# pick a shellcheck and hand it the file set.
#
# Usage:
#   ./tests/lint.sh install                  # fetch + verify the pinned engine
#   ./tests/lint.sh                          # lint every tracked *.sh + mediastack
#   ./tests/lint.sh scripts/lib/validators.sh  # lint only the named file(s)
#   ./tests/lint.sh --severity=error         # passthrough: only fail on errors
#   ./tests/lint.sh --severity=warning scripts/setup/stack.sh
#
# The pin exists so developers, agents, and CI all analyse with the EXACT same
# engine — different shellcheck versions disagree on which warnings fire, which
# would make the gate non-reproducible (e.g. the GitHub runner's native 0.9.0
# vs a newer local build). Engine resolution order:
#   1. native shellcheck, only when it is exactly the pinned version;
#   2. the cached pinned binary from `./tests/lint.sh install`, re-hashed on
#      every run — a version string is self-reported, the sha256 is not;
#   3. the pinned docker image.
# Every rung is the same engine version; 1 and 2 are just cheaper deliveries.
# Exits non-zero on findings at or above the chosen severity.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

TOOLS_TOML="$REPO_ROOT/tools.toml"
TOOL_CACHE="${MS_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mediastack-tools}"

die() {
    echo "lint: $1" >&2
    exit 2
}

# Section-scoped reader for the flat key = "value" form tools.toml uses.
pin() {
    local key="$1" value
    [ -r "$TOOLS_TOML" ] || die "unreadable pin manifest: $TOOLS_TOML"
    value=$(awk -F' *= *' -v key="$key" '
        /^\[/ { in_section = ($0 == "[shellcheck]"); next }
        in_section && $1 == key { gsub(/"/, "", $2); print $2; exit }
    ' "$TOOLS_TOML")
    [ -n "$value" ] || die "tools.toml [shellcheck] is missing $key"
    printf '%s\n' "$value"
}

SC_VERSION="$(pin version)" || exit 2
SC_BINARY_SHA256="$(pin binary_sha256)" || exit 2
SC_IMAGE="koalaman/shellcheck:v${SC_VERSION}"
SC_CACHED="$TOOL_CACHE/shellcheck-$SC_VERSION/shellcheck"

sha256_of() {
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1) || die "sha256sum failed: $1"
    printf '%s\n' "$got"
}

install_engine() {
    local url archive_sha dir tmp

    if [ -x "$SC_CACHED" ] && [ "$(sha256_of "$SC_CACHED")" = "$SC_BINARY_SHA256" ]; then
        printf 'shellcheck %s (cached, sha256 verified)\n' "$SC_VERSION"
        return 0
    fi

    url="$(pin url)" || exit 2
    archive_sha="$(pin sha256)" || exit 2
    dir="$TOOL_CACHE/shellcheck-$SC_VERSION"
    tmp=$(mktemp -d) || die "mktemp failed"

    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$tmp/shellcheck.tar.xz" "$url" \
        || die "download failed: $url"
    [ "$(sha256_of "$tmp/shellcheck.tar.xz")" = "$archive_sha" ] \
        || die "archive sha256 mismatch — tools.toml [shellcheck] does not describe $url"
    tar -xJf "$tmp/shellcheck.tar.xz" -C "$tmp" \
        || die "extraction failed: $tmp/shellcheck.tar.xz"
    [ "$(sha256_of "$tmp/shellcheck-v$SC_VERSION/shellcheck")" = "$SC_BINARY_SHA256" ] \
        || die "binary sha256 mismatch — tools.toml [shellcheck] does not describe the extracted binary"

    mkdir -p "$dir" || die "cannot create $dir"
    install -m 0755 "$tmp/shellcheck-v$SC_VERSION/shellcheck" "$SC_CACHED" \
        || die "install failed: $SC_CACHED"
    rm -rf "$tmp"
    printf 'shellcheck %s installed at %s\n' "$SC_VERSION" "$SC_CACHED"
}

if [[ "${1:-}" == "install" ]]; then
    (($# == 1)) || die "install takes no further arguments"
    install_engine
    exit 0
fi

# Split args: shellcheck passthrough flags (anything starting with -) vs. files.
# Default severity matches the CI gate (--severity=warning): a bare ./tests/lint.sh
# gives the same pass/fail as CI. Pass --severity=error/style/info to override.
sc_flags=()
files=()
has_severity=false
for arg in "$@"; do
    case "$arg" in
        --severity=*)
            sc_flags+=("$arg")
            has_severity=true
            ;;
        -*) sc_flags+=("$arg") ;;
        *) files+=("$arg") ;;
    esac
done
[[ "$has_severity" == "false" ]] && sc_flags=("--severity=warning" "${sc_flags[@]}")

# Default file set: every tracked shell file. Same discovery the CI shell-syntax
# loop uses (git ls-files -z '*.sh' 'mediastack'), so "what is shell here" has
# exactly one definition.
if ((${#files[@]} == 0)); then
    # Via temp files, not a pipeline: command substitution eats the NUL
    # separators, and a subshell would hide a nonzero exit behind a partial list.
    discover_out=$(mktemp) && discover_err=$(mktemp) || exit 2
    trap 'rm -f "$discover_out" "$discover_err"' EXIT
    if ! git ls-files -z '*.sh' 'mediastack' >"$discover_out" 2>"$discover_err"; then
        echo "lint: file discovery failed — git ls-files '*.sh' 'mediastack':" \
            "$(tr '\n' ' ' <"$discover_err")" >&2
        exit 2
    fi
    mapfile -d '' -t files <"$discover_out"
fi

# Fail closed on an empty population: a non-git export (release tarball, docker
# COPY without .git, git archive) would otherwise lint nothing and exit 0.
if ((${#files[@]} == 0)); then
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "lint: $REPO_ROOT is not a git repository — file discovery" \
            "(git ls-files '*.sh' 'mediastack') found nothing; lint cannot run here" >&2
    else
        echo "lint: git ls-files '*.sh' 'mediastack' matched no tracked shell files" >&2
    fi
    exit 2
fi

# Rung 1: a native shellcheck, ONLY when it is exactly the pinned version.
native_version=""
if command -v shellcheck >/dev/null 2>&1; then
    native_version="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
fi
if [[ "$native_version" == "$SC_VERSION" ]]; then
    exec shellcheck "${sc_flags[@]}" "${files[@]}"
fi

# Rung 2: the cached pin from `./tests/lint.sh install`, re-hashed on every
# run — a stale or tampered cache falls through rather than analysing.
if [ -x "$SC_CACHED" ] && [ "$(sha256_of "$SC_CACHED")" = "$SC_BINARY_SHA256" ]; then
    exec "$SC_CACHED" "${sc_flags[@]}" "${files[@]}"
fi

# Rung 3: the pinned docker image — byte-for-byte the same engine, slower start.
if command -v docker >/dev/null 2>&1; then
    exec docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt "$SC_IMAGE" "${sc_flags[@]}" "${files[@]}"
fi

echo "lint: need shellcheck $SC_VERSION natively, the cached pin" \
    "(run: ./tests/lint.sh install), or docker on PATH" >&2
exit 2

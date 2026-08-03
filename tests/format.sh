#!/usr/bin/env bash
# tests/format.sh — shell formatter gate, pinned in tools.toml [shfmt].
#
#   ./tests/format.sh install        fetch + verify the pin
#   ./tests/format.sh check [files]  diff mode: 0 clean, 1 differences
#   ./tests/format.sh write [files]  rewrite in place
#
# Discovery is `git ls-files '*.sh' 'mediastack'`, the same definition of "what
# is shell here" tests/lint.sh and the unit tier use — not shfmt's own directory
# walk, which would also read a live install's generated config under a
# developer's working tree.
#
# Exit codes: 0 clean, 1 differences, 2 tool, discovery or usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_TOML="$REPO_ROOT/tools.toml"
TOOL_CACHE="${MS_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mediastack-tools}"

# The layout flags are the format contract itself; changing one here without
# changing tools.toml [shfmt] silently reformats the tree under a stale pin.
SHFMT_FLAGS=(-ln bash -i 4 -ci -bn)

die() {
    printf 'FORMAT-ERROR\t%s\n' "$1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  tests/format.sh install        fetch + verify the pin
  tests/format.sh check [files]  diff mode: 0 clean, 1 differences
  tests/format.sh write [files]  rewrite in place

Exit codes: 0 clean, 1 differences, 2 tool, discovery or usage error.
EOF
}

# Section-scoped reader for the flat key = "value" form tools.toml uses.
pin() {
    local key="$1" value
    [ -r "$TOOLS_TOML" ] || die "unreadable pin manifest: $TOOLS_TOML"
    value=$(awk -F' *= *' -v key="$key" '
        /^\[/ { in_section = ($0 == "[shfmt]"); next }
        in_section && $1 == key { gsub(/"/, "", $2); print $2; exit }
    ' "$TOOLS_TOML")
    [ -n "$value" ] || die "tools.toml [shfmt] is missing $key"
    printf '%s\n' "$value"
}

VERSION="$(pin version)" || exit 2
BINARY_SHA256="$(pin sha256)" || exit 2
SHFMT="$TOOL_CACHE/shfmt-$VERSION/shfmt"

sha256_of() {
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1) || die "sha256sum failed: $1"
    printf '%s\n' "$got"
}

install_formatter() {
    local source dir tmp

    if [ -x "$SHFMT" ] && [ "$(sha256_of "$SHFMT")" = "$BINARY_SHA256" ]; then
        printf 'shfmt %s (cached, sha256 verified)\n' "$VERSION"
        return 0
    fi

    source="$(pin source)" || exit 2
    dir="$TOOL_CACHE/shfmt-$VERSION"
    tmp=$(mktemp -d) || die "mktemp failed"
    # A die below would otherwise strand the downloaded binary in /tmp.
    # shellcheck disable=SC2064  # expand now: $tmp is a local, gone at EXIT
    trap "rm -rf '$tmp'" EXIT

    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$tmp/shfmt" "$source" \
        || die "download failed: $source"
    [ "$(sha256_of "$tmp/shfmt")" = "$BINARY_SHA256" ] \
        || die "sha256 mismatch — tools.toml [shfmt] does not describe $source"

    mkdir -p "$dir" || die "cannot create $dir"
    install -m 0755 "$tmp/shfmt" "$SHFMT" || die "install failed: $SHFMT"
    rm -rf "$tmp"
    printf 'shfmt %s installed at %s\n' "$VERSION" "$SHFMT"
}

# The cached binary is re-hashed on every run: a version string is self-reported
# and a three-line shell script can print one. A missing or mismatched cache
# re-fetches rather than failing, so the gate is runnable from a clean checkout.
require_formatter() {
    if [ ! -x "$SHFMT" ] || [ "$(sha256_of "$SHFMT")" != "$BINARY_SHA256" ]; then
        install_formatter >&2
    fi
    [ "$("$SHFMT" --version 2>/dev/null)" = "v$VERSION" ] \
        || die "cached formatter is not v$VERSION - run: $0 install"
    # shfmt silently prefers .editorconfig over every flag above, so the pin
    # would stop meaning what it says the day one is added.
    [ ! -e "$REPO_ROOT/.editorconfig" ] \
        || die ".editorconfig overrides the tools.toml [shfmt] flags"
}

# Via a temp file, not a pipeline: command substitution eats the NUL separators,
# and a subshell would hide a nonzero exit behind a partial list.
discover() {
    local out
    out=$(mktemp) || die "mktemp failed"
    git -C "$REPO_ROOT" ls-files -z '*.sh' 'mediastack' >"$out" 2>/dev/null \
        || die "file discovery failed: git ls-files '*.sh' 'mediastack'"
    mapfile -d '' -t FILES <"$out"
    rm -f "$out"
    # Fail closed on an empty population: a non-git export would otherwise
    # format nothing and exit 0.
    ((${#FILES[@]} > 0)) || die "no tracked shell files under $REPO_ROOT"
}

run_shfmt() {
    local mode="$1" rc
    shift
    FILES=("$@")
    ((${#FILES[@]} > 0)) || discover
    require_formatter
    cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"
    "$SHFMT" "${SHFMT_FLAGS[@]}" "$mode" -- "${FILES[@]}"
    rc=$?
    # shfmt exits 1 both for "differences found" and for a parse error; the
    # difference is on stderr, so only the caller's contract is normalised here.
    ((rc <= 1)) || die "shfmt exited $rc"
    if [ "$mode" = -d ] && ((rc == 1)); then
        printf 'format: run ./tests/format.sh write\n' >&2
    fi
    return "$rc"
}

FILES=()
case "${1:-}" in
    install) install_formatter ;;
    check)
        shift
        run_shfmt -d "$@"
        ;;
    write)
        shift
        run_shfmt -w "$@"
        ;;
    -h | --help | help) usage ;;
    *)
        usage >&2
        die "unknown mode: ${1:-<none>}"
        ;;
esac

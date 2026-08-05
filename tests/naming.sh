#!/usr/bin/env bash
# Filename-casing gate: tracked *.sh basenames must be kebab-case, tracked
# *.py basenames must be snake_case (docs/conventions.md "Identifier and
# file naming"). tests/shell-naming.allowlist is a shrink-only ratchet of the
# offenders that predate this gate — mirrors tests/shell-line-cap.sh's
# allowlist semantics but with no per-file value to track, so it is a plain
# path list: an entry may only be removed, never added, and a listed path
# that is no longer tracked or now conforms is a stale entry that fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/tests/shell-naming.allowlist"
SH_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*\.sh$'
PY_PATTERN='^[a-z0-9_]+\.py$'

die() {
    printf 'naming: %s\n' "$1" >&2
    exit 2
}

tracked_file_list=$(mktemp) || die "cannot create tracked-file list"
base_allowlist=$(mktemp) || die "cannot create base allowlist"
trap 'rm -f "$tracked_file_list" "$base_allowlist"' EXIT

base_ref=""
if base_ref=$(git -C "$REPO_ROOT" rev-parse HEAD^ 2>/dev/null); then
    :
else
    base_ref=HEAD
fi

if ! git -C "$REPO_ROOT" ls-files -z '*.sh' '*.py' >"$tracked_file_list"; then
    die "tracked file discovery failed"
fi

tracked_files=()
mapfile -d '' -t tracked_files <"$tracked_file_list"
((${#tracked_files[@]} > 0)) || die "tracked population is empty"

declare -A offending=()
for file in "${tracked_files[@]}"; do
    base="$(basename "$file")"
    case "$file" in
        *.sh)
            [[ "$base" =~ $SH_PATTERN ]] || offending["$file"]=1
            ;;
        *.py)
            [[ "$base" =~ $PY_PATTERN ]] || offending["$file"]=1
            ;;
    esac
done

declare -A tracked_set=()
for file in "${tracked_files[@]}"; do
    tracked_set["$file"]=1
done

base_allowlist_exists=false
if git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/shell-naming.allowlist" 2>/dev/null; then
    base_allowlist_exists=true
    git -C "$REPO_ROOT" show "$base_ref:tests/shell-naming.allowlist" >"$base_allowlist" \
        || die "cannot read base allowlist"
fi

declare -A base_allowed=()
while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -z "$file" ]] && continue
    base_allowed["$file"]=1
done <"$base_allowlist"

declare -A allowed=()
if [[ -e "$ALLOWLIST" ]]; then
    [[ -r "$ALLOWLIST" ]] || die "allowlist is unreadable: $ALLOWLIST"
    while IFS= read -r file || [[ -n "$file" ]]; do
        [[ -z "$file" ]] && continue
        [[ -z "${allowed["$file"]+present}" ]] \
            || die "duplicate allowlist entry: $file"
        [[ -n "${tracked_set["$file"]+tracked}" ]] \
            || die "stale allowlist entry (file is not tracked): $file"
        [[ -n "${offending["$file"]+offending}" ]] \
            || die "stale allowlist entry (file now conforms): $file"
        if [[ "$base_allowlist_exists" == true && -z "${base_allowed["$file"]+baseline}" ]]; then
            die "new allowlist entry is not permitted: $file"
        fi
        allowed["$file"]=1
    done <"$ALLOWLIST"
fi

fail=0
for file in "${!offending[@]}"; do
    [[ -n "${allowed["$file"]+allowlisted}" ]] && continue
    printf 'naming: %s does not match the required casing for its extension — see docs/conventions.md "Identifier and file naming"\n' "$file" >&2
    fail=1
done

((fail == 0)) || exit 1

# -----------------------------------------------------------------------------
# Declared function-prefix gate: a module under scripts/ opts in by putting a
# `<prefix>_*` token on its `# Owns:` line (first 5 lines) — see
# docs/conventions.md "Identifier and file naming". Once declared, every
# function def in that file must start with a declared prefix, allowing one
# optional leading `_` for a file-private helper; `main` is the entry-point
# exemption. Fails closed: zero declaring files proves nothing.
# -----------------------------------------------------------------------------
TOKEN_PATTERN='[a-z][a-z0-9_]*_\*'
DEF_PATTERN='^_?[a-z0-9_]+[[:space:]]*\(\)'

prefix_files_list=$(mktemp) || die "cannot create prefix-file list"
trap 'rm -f "$tracked_file_list" "$base_allowlist" "$prefix_files_list"' EXIT
git -C "$REPO_ROOT" ls-files -z 'scripts/*.sh' >"$prefix_files_list" \
    || die "scripts/*.sh discovery failed"

declared_files=()
mapfile -d '' -t declared_candidates <"$prefix_files_list"

prefix_fail=0
for file in "${declared_candidates[@]}"; do
    tokens=$(sed -n '1,5p' "$REPO_ROOT/$file" | grep '^# Owns:' | grep -oE "$TOKEN_PATTERN" | sort -u)
    [[ -n "$tokens" ]] || continue
    declared_files+=("$file")
    pattern=$(sed 's/_\*$//' <<<"$tokens" | paste -sd '|' -)
    while IFS=: read -r lineno defline; do
        name="${defline%%(*}"
        name="${name%%[[:space:]]*}"
        name="${name#_}"
        [[ "$name" == "main" ]] && continue
        if ! [[ "$name" =~ ^($pattern)_ ]]; then
            printf 'naming: %s:%s: %s() does not match declared prefix(es) [%s] — see docs/conventions.md "Identifier and file naming"\n' \
                "$file" "$lineno" "$name" "$(tr '\n' ' ' <<<"$tokens")" >&2
            prefix_fail=1
        fi
    done < <(grep -nE "$DEF_PATTERN" "$REPO_ROOT/$file")
done

if ((${#declared_files[@]} == 0)); then
    die "no scripts/*.sh file declares a function prefix — empty population"
fi

((prefix_fail == 0)) || exit 1

printf 'naming: %s tracked shell/python files checked (%s allowlisted); %s scripts/*.sh files checked for declared function prefixes\n' \
    "${#tracked_files[@]}" "${#allowed[@]}" "${#declared_files[@]}"

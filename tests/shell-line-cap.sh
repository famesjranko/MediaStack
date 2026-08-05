#!/usr/bin/env bash
# Owns the tracked-shell line-cap and allowlist ratchet gate.
# Sources: the git index, tracked file contents, and tests/shell-line-cap.allowlist.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP=500
ALLOWLIST="$REPO_ROOT/tests/shell-line-cap.allowlist"

die() {
    printf 'shell-line-cap: %s\n' "$1" >&2
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

if ! git -C "$REPO_ROOT" ls-files -z '*.sh' 'mediastack' >"$tracked_file_list"; then
    die "tracked shell discovery failed"
fi

tracked_files=()
mapfile -d '' -t tracked_files <"$tracked_file_list"
((${#tracked_files[@]} > 0)) || die "tracked shell population is empty"

declare -A tracked_counts=()
for file in "${tracked_files[@]}"; do
    [[ -f "$REPO_ROOT/$file" ]] || die "tracked shell file is missing: $file"
    tracked_counts["$file"]="$(wc -l <"$REPO_ROOT/$file")"
done

# The allowlist file is gone and every file obeys the cap. An absent
# allowlist means an empty allowed set; if it exists it must be readable,
# and its entries still ratchet (shrink-only, no new entries).
if [[ -e "$ALLOWLIST" ]]; then
    [[ -r "$ALLOWLIST" ]] || die "allowlist is unreadable: $ALLOWLIST"
else
    ALLOWLIST=/dev/null
fi

if git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/shell-line-cap.allowlist" 2>/dev/null; then
    git -C "$REPO_ROOT" show "$base_ref:tests/shell-line-cap.allowlist" >"$base_allowlist" \
        || die "cannot read base allowlist"
else
    : >"$base_allowlist"
fi

base_allowlist_exists=false
if git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/shell-line-cap.allowlist" 2>/dev/null; then
    base_allowlist_exists=true
fi

declare -A base_counts=()
while IFS=$'\t' read -r file recorded extra || [[ -n "$file$recorded$extra" ]]; do
    [[ -z "$file$recorded$extra" ]] && continue
    [[ -n "$file" && "$recorded" =~ ^[0-9]+$ && -z "$extra" ]] \
        || die "malformed base allowlist entry"
    base_counts["$file"]="$recorded"
done <"$base_allowlist"

declare -A allowed_counts=()
while IFS=$'\t' read -r file recorded extra || [[ -n "$file$recorded$extra" ]]; do
    [[ -z "$file$recorded$extra" ]] && continue
    [[ -n "$file" && -n "$recorded" && -z "$extra" ]] \
        || die "malformed allowlist entry"
    [[ "$recorded" =~ ^[0-9]+$ ]] || die "invalid recorded count for $file"
    [[ -z "${allowed_counts["$file"]+present}" ]] \
        || die "duplicate allowlist entry: $file"
    [[ -n "${tracked_counts["$file"]+tracked}" ]] \
        || die "stale allowlist entry (file is not tracked): $file"

    current="${tracked_counts["$file"]}"
    ((current > CAP)) \
        || die "stale allowlist entry (file is at or under $CAP lines): $file"
    if [[ -n "${base_counts["$file"]+baseline}" ]]; then
        ((recorded <= base_counts["$file"])) \
            || die "allowlist count increased for $file"
    elif [[ "$base_allowlist_exists" == true ]]; then
        die "new allowlist entry is not permitted: $file"
    else
        ((recorded == current)) \
            || die "new allowlist entry must record current count: $file"
    fi
    ((current <= recorded)) \
        || die "$file grew from $recorded to $current lines"
    allowed_counts["$file"]="$recorded"
done <"$ALLOWLIST"

for file in "${tracked_files[@]}"; do
    current="${tracked_counts["$file"]}"
    ((current <= CAP)) && continue
    [[ -n "${allowed_counts["$file"]+allowlisted}" ]] \
        || die "$file is $current lines (cap $CAP); shrink it — see docs/conventions.md 'Shell structure' for the split strategy"
done

printf 'shell-line-cap: %s tracked shell files checked (cap %s)\n' \
    "${#tracked_files[@]}" "$CAP"

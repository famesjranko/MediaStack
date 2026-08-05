#!/usr/bin/env bash
# Owns the tracked-shell line-cap and allowlist ratchet gate.
# Sources: the git index, tracked file contents, and tests/shell-line-cap.allowlist.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ratchet.sh
source "$REPO_ROOT/tests/lib/ratchet.sh"
CAP=500
ALLOWLIST="$REPO_ROOT/tests/shell-line-cap.allowlist"
# Both ratchet refusals route where the main violation does: relisting a file
# is not a remedy, so the steering names the only one there is.
RATCHET_STEER="the allowlist is a shrink-only grandfather list, never a place to record a new offender — split the file, see docs/conventions.md 'Shell structure' for the split strategy"

die() {
    printf 'shell-line-cap: %s\n' "$1" >&2
    exit 2
}

tracked_file_list=$(mktemp) || die "cannot create tracked-file list"
trap 'rm -f "$tracked_file_list"' EXIT

base_ref="$(ratchet_base_ref "$REPO_ROOT")" || die "cannot resolve a ratchet baseline"

if ! git -C "$REPO_ROOT" ls-files -z '*.sh' 'mediastack' >"$tracked_file_list"; then
    die "tracked shell discovery failed"
fi

tracked_files=()
mapfile -d '' -t tracked_files <"$tracked_file_list"
((${#tracked_files[@]} > 0)) || die "tracked shell population is empty"

declare -A tracked_counts=()
for file in "${tracked_files[@]}"; do
    [[ -f "$REPO_ROOT/$file" ]] || die "tracked shell file is missing: $file"
    # awk NR, not wc -l: a final line without a trailing newline still counts
    tracked_counts["$file"]="$(awk 'END { print NR }' "$REPO_ROOT/$file")"
done

# The allowlist file is gone and every file obeys the cap. An absent
# allowlist means an empty allowed set; if it exists it must be readable,
# and its entries still ratchet (shrink-only, no new entries).
if [[ -e "$ALLOWLIST" ]]; then
    [[ -r "$ALLOWLIST" ]] || die "allowlist is unreadable: $ALLOWLIST"
else
    ALLOWLIST=/dev/null
fi

base_allowlist_exists=false
if git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/shell-line-cap.allowlist" 2>/dev/null; then
    base_allowlist_exists=true
fi

declare -A base_counts=()
ratchet_read_base "$REPO_ROOT" "$base_ref" tests/shell-line-cap.allowlist base_counts

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
            || die "allowlist count increased for $file; $RATCHET_STEER"
    elif [[ "$base_allowlist_exists" == true ]]; then
        die "new allowlist entry is not permitted: $file; $RATCHET_STEER"
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

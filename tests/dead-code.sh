#!/usr/bin/env bash
# Dead-function gate: every shell function defined under scripts/ must have at
# least one reference somewhere in the tracked tree, on a line other than its
# own definition line. A function with none is unreachable and should be
# deleted, not left to bit-rot.
#
# The search is a bare-name grep across every tracked file, not a call-syntax
# match: dynamic dispatch (a name held in a variable, an associative-array
# key, a `declare -F` probe) references a function without ever writing
# `name(...)`, so restricting to call syntax would produce false positives.
# Fails closed: an empty function population proves nothing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

die() {
    printf 'dead-code: %s\n' "$1" >&2
    exit 2
}

DEF_PATTERN='^_?[a-z0-9_]+[[:space:]]*\(\)'

script_files_list=$(mktemp) || die "cannot create scripts/ file list"
all_files_list=$(mktemp) || die "cannot create tracked-file list"
trap 'rm -f "$script_files_list" "$all_files_list"' EXIT

git ls-files -z -- 'scripts/*.sh' >"$script_files_list" \
    || die "scripts/ file discovery failed"
git ls-files -z >"$all_files_list" \
    || die "tracked file discovery failed"

script_files=()
mapfile -d '' -t script_files <"$script_files_list"
((${#script_files[@]} > 0)) || die "scripts/ population is empty"

all_files=()
mapfile -d '' -t all_files <"$all_files_list"

checked=0
fail=0
for file in "${script_files[@]}"; do
    while IFS=: read -r lineno defline; do
        name="${defline%%(*}"
        name="${name%%[[:space:]]*}"
        [[ -z "$name" ]] && continue
        checked=$((checked + 1))
        # Every reference to the bare name, tree-wide, as a whole word — then
        # discount the definition line itself. Any survivor is a real caller.
        hits=$(grep -rnw -- "$name" "${all_files[@]}" | grep -vF "$file:$lineno:")
        if [[ -z "$hits" ]]; then
            printf 'dead-code: %s:%s: %s() has no reference anywhere else in the tree — delete it\n' \
                "$file" "$lineno" "$name" >&2
            fail=1
        fi
    done < <(grep -nE "$DEF_PATTERN" "$file")
done

((checked > 0)) || die "no function definitions found under scripts/ — empty population"

((fail == 0)) || exit 1

printf 'dead-code: %s functions checked across %s scripts/*.sh files\n' "$checked" "${#script_files[@]}"

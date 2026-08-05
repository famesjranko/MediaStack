#!/usr/bin/env bash
# Owns the C901 reconcile, its shrink-only allowlist ratchet, and the
# suppression ban that would otherwise let a function dodge both.
# Sources: a ruff concise-format findings file (argv 1), the git index, and
# tests/python-complexity.allowlist.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/tests/python-complexity.allowlist"

die() {
    printf 'python-complexity: %s\n' "$1" >&2
    exit 2
}

# Ruff already printed the threshold; this says what to do about it.
steer() {
    cat >&2 <<'STEER'

python-complexity: complexity is a symptom, diagnose it before you decompose:
  1. poor structure or logic — deep nesting or repeated branching on the same
     value; restructure it;
  2. one function carrying too many responsibilities — split it along them;
  3. accidental complexity — a simpler solution exists; find that instead.
Raising the cap or suppressing the rule is not one of the three.
See docs/conventions.md 'Complexity cap' for the strategy and the allowlist ratchet.
STEER
}

findings="${1:-}"
[[ -n "$findings" && -r "$findings" ]] || die "unreadable ruff findings file: $findings"

tracked_python=$(mktemp) || die "cannot create tracked-python list"
trap 'rm -f "$tracked_python"' EXIT

base_ref=$(git -C "$REPO_ROOT" rev-parse HEAD^ 2>/dev/null) || base_ref=HEAD

# Same discovery the ruff and mypy selectors use: no new file dodges the ban.
git -C "$REPO_ROOT" ls-files -z '*.py' >"$tracked_python" || die "tracked python discovery failed"
python_files=()
mapfile -d '' -t python_files <"$tracked_python"
((${#python_files[@]} > 0)) || die "tracked python population is empty"

failed=false
complexity_failed=false

# Escape hatches closed: a C901-scoped suppression and a bare un-scoped noqa
# (which silences C901 too). A scoped suppression of another rule stays legal.
for file in "${python_files[@]}"; do
    for hatch in 'a C901 suppression|#[[:space:]]*noqa:[^#]*\bC901\b' \
        'a bare un-scoped noqa|#[[:space:]]*noqa([[:space:]]*$|[[:space:]]+[^:[:space:]])'; do
        grep -HnE "${hatch#*|}" "$REPO_ROOT/$file" >&2 || continue
        printf 'python-complexity: %s carries %s; suppression is not the fix\n' \
            "$file" "${hatch%%|*}" >&2
        failed=true
        complexity_failed=true
    done
done

# Keyed on path AND function: two offenders are both named main. Every
# non-C901 finding passes through untouched.
declare -A observed=() observed_line=()
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([^:]+):[0-9]+:[0-9]+:\ C901\ \`([^\`]+)\`\ is\ too\ complex\ \(([0-9]+)\ \> ]]; then
        key="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"
        observed["$key"]="${BASH_REMATCH[3]}"
        observed_line["$key"]="$line"
    elif [[ -n "$line" && ! "$line" =~ ^(Found\ |\[\*\]) ]]; then
        printf '%s\n' "$line" >&2
        failed=true
    fi
done <"$findings"

# An absent allowlist means an empty allowed set; present, it must be readable.
[[ -e "$ALLOWLIST" ]] || ALLOWLIST=/dev/null
[[ -r "$ALLOWLIST" ]] || die "allowlist is unreadable: $ALLOWLIST"

base_exists=false
git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/python-complexity.allowlist" 2>/dev/null && base_exists=true

declare -A base_scores=()
while IFS=$'\t' read -r file func recorded extra; do
    [[ -z "$file$func$recorded$extra" ]] && continue
    [[ -n "$file" && -n "$func" && "$recorded" =~ ^[0-9]+$ && -z "$extra" ]] || die "malformed base entry"
    base_scores["$file"$'\t'"$func"]="$recorded"
done < <([[ "$base_exists" == true ]] && git -C "$REPO_ROOT" show "$base_ref:tests/python-complexity.allowlist")

declare -A allowed=()
while IFS=$'\t' read -r file func recorded extra || [[ -n "$file$func$recorded$extra" ]]; do
    [[ -z "$file$func$recorded$extra" ]] && continue
    [[ -n "$file" && -n "$func" && -z "$extra" ]] || die "malformed allowlist entry"
    [[ "$recorded" =~ ^[0-9]+$ ]] || die "invalid recorded complexity for $file:$func"
    key="$file"$'\t'"$func"
    [[ -z "${allowed["$key"]+present}" ]] || die "duplicate allowlist entry: $file:$func"
    [[ -n "${observed["$key"]+seen}" ]] || die "stale allowlist entry (function conforms or is gone): $file:$func"
    if [[ -n "${base_scores["$key"]+baseline}" ]]; then
        ((recorded <= base_scores["$key"])) || die "allowlist complexity increased for $file:$func"
    elif [[ "$base_exists" == true ]]; then
        die "new allowlist entry is not permitted: $file:$func"
    else
        ((recorded == observed["$key"])) || die "new entry must record current complexity: $file:$func"
    fi
    allowed["$key"]="$recorded"
done <"$ALLOWLIST"

for key in "${!observed[@]}"; do
    if [[ -n "${allowed["$key"]+allowlisted}" ]] && ((observed["$key"] <= allowed["$key"])); then
        continue
    fi
    printf '%s\n' "${observed_line["$key"]}" >&2 # ruff's own message, verbatim
    failed=true
    complexity_failed=true
done

[[ "$complexity_failed" == true ]] && steer
[[ "$failed" == true ]] && exit 1

printf 'python-complexity: %s tracked python files checked (%s grandfathered functions)\n' \
    "${#python_files[@]}" "${#allowed[@]}"

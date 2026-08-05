#!/usr/bin/env bash
# tests/unit/line-cap-gate.sh
#
# Regression proof for the ratchet refusals in tests/shell-line-cap.sh: a new
# allowlist entry against a tracked baseline, and a recorded count that grew.
# The real allowlist was emptied and deleted, so neither refusal can be
# reproduced against this tree; both are probed against a fabricated allowlist
# in a throwaway repository instead, which is also why nothing here recreates
# one in the tree.
#
# Pure bash + git — no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="line-cap-gate"
scenario_begin "$CURRENT_SCENARIO"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/tests"
# The gate under test is the working-tree copy; it derives its population from
# `git ls-files`, so the fixture has to be a real repository.
cp "$REPO_ROOT/tests/shell-line-cap.sh" "$FIXTURE/tests/shell-line-cap.sh"
GATE="$FIXTURE/tests/shell-line-cap.sh"
ALLOWLIST="$FIXTURE/tests/shell-line-cap.allowlist"

# One grandfathered over-cap file, recorded at its real length.
write_shell() {
    local path="$1" lines="$2" i
    {
        printf '#!/usr/bin/env bash\n'
        for ((i = 2; i <= lines; i++)); do printf ': %s\n' "$i"; done
    } >"$path"
}

write_shell "$FIXTURE/big.sh" 600
printf 'big.sh\t600\n' >"$ALLOWLIST"
git -C "$FIXTURE" init -q .
git -C "$FIXTURE" config user.email line-cap@example.invalid
git -C "$FIXTURE" config user.name line-cap
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -qm "baseline with a grandfathered offender"
git -C "$FIXTURE" commit -q --allow-empty -m "head"

RC=0
OUT=""
run_gate() {
    OUT=$("$GATE" 2>&1)
    RC=$?
}

assert_rc() {
    local expected="$1" name="$2"
    if [[ "$RC" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected rc $expected, got $RC: $OUT"
    fi
}

assert_steering() {
    assert_contains "$OUT" "shrink-only grandfather list" "$1 names the ratchet as shrink-only"
    assert_contains "$OUT" "split the file" "$1 steers to splitting the file"
    assert_contains "$OUT" "docs/conventions.md 'Shell structure'" "$1 points at the split strategy"
}

# --- the grandfathered baseline ---------------------------------------------

run_gate
assert_rc 0 "a recorded offender at its recorded count passes"

# --- a new entry against a tracked baseline ---------------------------------

write_shell "$FIXTURE/other.sh" 601
printf 'other.sh\t601\n' >>"$ALLOWLIST"
git -C "$FIXTURE" add -A
run_gate
assert_rc 2 "a new allowlist entry against a tracked baseline is refused"
assert_contains "$OUT" "new allowlist entry is not permitted" "the refusal names the new entry"
assert_steering "the new-entry refusal"
git -C "$FIXTURE" rm -q --cached other.sh >/dev/null
rm -f "$FIXTURE/other.sh"
printf 'big.sh\t600\n' >"$ALLOWLIST"

# --- a recorded count that grew ---------------------------------------------

write_shell "$FIXTURE/big.sh" 601
printf 'big.sh\t601\n' >"$ALLOWLIST"
run_gate
assert_rc 2 "a recorded count above the baseline is refused"
assert_contains "$OUT" "allowlist count increased" "the refusal names the grown count"
assert_steering "the count-increase refusal"

# --- back to the baseline ---------------------------------------------------

write_shell "$FIXTURE/big.sh" 600
printf 'big.sh\t600\n' >"$ALLOWLIST"
run_gate
assert_rc 0 "shrinking back to the recorded count restores the gate to green"

scenario_end "$CURRENT_SCENARIO"
summary

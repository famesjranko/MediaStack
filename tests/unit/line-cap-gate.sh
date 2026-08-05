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

mkdir -p "$FIXTURE/tests/lib"
# The gate under test is the working-tree copy; it derives its population from
# `git ls-files`, so the fixture has to be a real repository.
cp "$REPO_ROOT/tests/shell-line-cap.sh" "$FIXTURE/tests/shell-line-cap.sh"
cp "$REPO_ROOT/tests/lib/ratchet.sh" "$FIXTURE/tests/lib/ratchet.sh"
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

run_gate() { run_cmd "$GATE"; }

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

# --- a shallow clone with no main fails closed ------------------------------
#
# A depth-1 clone (CI's default checkout) has no origin/main, no main and no
# HEAD^: the baseline would degrade to HEAD — the tree under test — and every
# allowlist entry would look pre-existing. The gate must refuse, not pass.

git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -qm "tip for the shallow probe"
SHALLOW="$FIXTURE-shallow"
git clone -q --depth 1 "file://$FIXTURE" "$SHALLOW" 2>/dev/null
git -C "$SHALLOW" branch -m not-main 2>/dev/null || true
git -C "$SHALLOW" update-ref -d refs/remotes/origin/main 2>/dev/null || true
run_cmd "$SHALLOW/tests/shell-line-cap.sh"
assert_rc 2 "a shallow clone with no reachable main fails closed"
assert_contains "$OUT" "shallow clone" "the refusal names the shallow clone"
rm -rf "$SHALLOW"

scenario_end "$CURRENT_SCENARIO"
summary

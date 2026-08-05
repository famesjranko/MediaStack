#!/usr/bin/env bash
# tests/unit/contracts-gate.sh
#
# Regression proof for the steering on the failure paths of
# tests/contracts/check.py: a call with no contract entry, and a contract entry
# no call reaches. A gate that only names its symptom leaves the reader to
# guess the remedy, so each failure is probed with one fabricated violation and
# asserted to route somewhere.
#
# The fixture is a throwaway copy of the tree from `git archive HEAD`: the
# checker resolves everything relative to its own location, so the real tree is
# never written to. Pure bash + python3 + git — no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-gate"
scenario_begin "$CURRENT_SCENARIO"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

git -C "$REPO_ROOT" archive HEAD | tar -x -C "$FIXTURE" || {
    fail "fixture tree is exported" "git archive failed"
    summary
    exit 1
}
# The checker under test is the working-tree copy, not HEAD's.
cp "$REPO_ROOT/tests/contracts/check.py" "$FIXTURE/tests/contracts/check.py"

# RC/OUT are globals: a command substitution would run the checker in a
# subshell and leave the caller reading a stale exit code.
RC=0
OUT=""
run_gate() {
    OUT=$(cd "$FIXTURE" && python3 tests/contracts/check.py 2>&1)
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

PROBED_CALLER="$FIXTURE/scripts/lib/health.sh"
PROBED_CONTRACT="$FIXTURE/tests/contracts/sonarr.yml"
caller_backup=$(cat "$PROBED_CALLER")
contract_backup=$(cat "$PROBED_CONTRACT")

# --- the clean tree ---------------------------------------------------------

run_gate
assert_rc 0 "the exported tree passes the contract check"

# --- a call with no contract entry ------------------------------------------

printf '\ncontracts_gate_probe() { curl "http://127.0.0.1:1/api/v3/steeringprobe"; }\n' \
    >>"$PROBED_CALLER"
run_gate
assert_rc 1 "an API call no contract covers fails"
assert_contains "$OUT" "missing contract" "the failure names the uncovered call"
assert_contains "$OUT" "has no entry covering it" "the failure explains what missing means"
assert_contains "$OUT" "or the call is malformed" "the failure allows for a malformed call"
assert_contains "$OUT" "tests/contracts/" "the failure names where contract files live"
assert_contains "$OUT" "tests/contracts/README.md" "the failure points at the contract docs"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- a contract entry no call reaches ---------------------------------------

printf '  - method: GET\n    path: /steeringprobe\n    callers: []\n' >>"$PROBED_CONTRACT"
run_gate
assert_rc 1 "a contract entry nothing calls fails"
assert_contains "$OUT" "dead contract entry" "the failure names the dead entry"
assert_contains "$OUT" "the call it covered is gone" "the failure explains what dead means"
assert_contains "$OUT" "delete the entry" "the failure steers to deleting the entry"
assert_contains "$OUT" "tests/contracts/README.md" "the dead-entry failure points at the contract docs"
printf '%s\n' "$contract_backup" >"$PROBED_CONTRACT"

run_gate
assert_rc 0 "restoring both files restores the check to green"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/contracts-gate.sh
#
# Regression proof for the failure paths of tests/contracts/check.py: a call
# with no contract entry, a contract entry no call reaches, a readiness probe
# whose URL cannot be attributed, and schema violations of the optional
# `expect` and `unexercised` keys. A gate that only names its symptom leaves the
# reader to guess the remedy, so each failure is probed with one fabricated
# violation and asserted to route somewhere.
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

export_fixture_tree "$REPO_ROOT" "$FIXTURE"
# The checker and the inventory it reads are the working-tree copies, not HEAD's.
cp "$REPO_ROOT"/tests/contracts/*.py "$REPO_ROOT"/tests/contracts/*.yml "$FIXTURE/tests/contracts/"

# A `cd` first, so this cannot just be run_cmd's argv form.
run_gate() {
    OUT=$(cd "$FIXTURE" && python3 tests/contracts/check.py 2>&1)
    RC=$?
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

printf '  - {id: steering-probe, method: GET, path: /steeringprobe, sends: [], reads: [], callers: []}\n' \
    >>"$PROBED_CONTRACT"
run_gate
assert_rc 1 "a contract entry nothing calls fails"
assert_contains "$OUT" "dead contract entry" "the failure names the dead entry"
assert_contains "$OUT" "the call it covered is gone" "the failure explains what dead means"
assert_contains "$OUT" "delete the entry" "the failure steers to deleting the entry"
assert_contains "$OUT" "tests/contracts/README.md" "the dead-entry failure points at the contract docs"
printf '%s\n' "$contract_backup" >"$PROBED_CONTRACT"

# --- a readiness probe whose URL names no service ---------------------------

# Given a probe that polls a URL from a variable no assignment attributes.
printf '\ncontracts_gate_probe() { wait_for_service "Probe" "$contracts_gate_url"; }\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then it fails, names the probe, and says which URL form it can attribute.
assert_rc 1 "a probe with an unattributable URL fails"
assert_contains "$OUT" "unrecognised probe: scripts/lib/health.sh: wait_for_service" \
    "the failure names the unrecognised probe and its file"
assert_contains "$OUT" "service_local_url NAME" "the failure names the URL form to use"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- an expect status outside 100-599 ---------------------------------------

# Given an entry whose expect list holds a value that is not an HTTP status.
sed -i 's/{id: indexer-list, method: GET,/{id: indexer-list, method: GET, expect: [200, 700],/' \
    "$PROBED_CONTRACT"

# When the gate runs.
run_gate

# Then it fails as a schema error that names the entry.
assert_rc 1 "an expect value outside 100-599 fails"
assert_contains "$OUT" "schema: sonarr indexer-list: expect values must be integers from 100 to 599" \
    "the failure names the entry and the expect rule"
printf '%s\n' "$contract_backup" >"$PROBED_CONTRACT"

# --- an unexercised reason outside the closed set ---------------------------

# Given an entry exempted for a reason that is not in the closed set.
sed -i 's/{id: indexer-list, method: GET,/{id: indexer-list, method: GET, unexercised: flaky,/' \
    "$PROBED_CONTRACT"

# When the gate runs.
run_gate

# Then it fails as a schema error that names the entry and the allowed reasons.
assert_rc 1 "an unexercised reason outside the closed set fails"
assert_contains "$OUT" "schema: sonarr indexer-list: unexercised must be one of" \
    "the failure names the entry and the unexercised rule"
assert_contains "$OUT" "'held-profile', 'launcher-menu', 'nas', 'remote-profile'" \
    "the failure lists the closed set of reasons"
printf '%s\n' "$contract_backup" >"$PROBED_CONTRACT"

run_gate
assert_rc 0 "restoring both files restores the check to green"

scenario_end "$CURRENT_SCENARIO"
summary

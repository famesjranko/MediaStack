#!/usr/bin/env bash
# tests/unit/contracts-gate.sh
#
# Regression proof for the failure paths of tests/contracts/check.py: a call
# with no contract entry, a contract entry no call reaches, a readiness probe
# whose URL cannot be attributed or whose service has no entry, a service URL
# with a braced variable in its suffix, a service URL variable reused in
# another function, and schema violations of the optional `expect` and
# `unexercised` keys. The exec scan is probed the same way: a docker exec with
# no exec entry, an exec entry no call reaches, a container that cannot be
# read, a container variable that names one service, and the dry-run sandbox
# exclusion. A gate that only names its symptom leaves the
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

# --- a readiness probe for a service with no entry --------------------------

# Given a probe that polls the root of a service no contract file lists.
printf '\ncontracts_gate_probe() {\n    wait_for_service "Probe" "$(service_local_url gateprobe)"\n}\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then it fails and names the probe as a missing contract for that service.
assert_rc 1 "a probe of a service without entries fails"
assert_contains "$OUT" "missing contract: scripts/lib/health.sh gateprobe GET /" \
    "the failure names the probed service and route"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- a braced variable inside a service URL suffix --------------------------

# Given a call whose service URL suffix holds a braced variable before a further segment.
printf '\ncontracts_gate_probe() { curl "$(service_local_url sonarr)/api/v3/notification/${gate_id}/test"; }\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then the whole suffix is read, so the call is not taken for the notification entry.
assert_rc 1 "a call to an unlisted route below an id fails"
assert_contains "$OUT" "missing contract: scripts/lib/health.sh sonarr GET /api/v3/notification/{id}/test" \
    "the failure names the full route after the braced variable"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- a service URL variable reused in another function ----------------------

# Given one function that assigns a service URL and another that reuses the name for a call.
printf '\ngate_one() { local gate_url; gate_url="$(service_local_url sonarr)"; }\n' >>"$PROBED_CALLER"
printf 'gate_two() { curl "${gate_url}/api/gatescope"; }\n' >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then the call in the second function is not attributed to Sonarr.
assert_rc 1 "an unlisted call through a reused variable fails"
assert_contains "$OUT" "missing contract: scripts/lib/health.sh GET /api/gatescope" \
    "the failure names the call without a service"
assert_not_contains "$OUT" "sonarr GET /api/gatescope" "the other function's service URL is not used"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- held-profile on a service that is not held -----------------------------

# Given an entry of Sonarr, which is not a held service, exempted as held-profile.
sed -i 's/{id: indexer-list, method: GET,/{id: indexer-list, method: GET, unexercised: held-profile,/' \
    "$PROBED_CONTRACT"

# When the gate runs.
run_gate

# Then it fails as a schema error that names the entry.
assert_rc 1 "held-profile on a service that is not held fails"
assert_contains "$OUT" "schema: sonarr indexer-list: unexercised held-profile is only for held services" \
    "the failure names the entry and the held-profile rule"
printf '%s\n' "$contract_backup" >"$PROBED_CONTRACT"

# --- a docker exec with no exec entry ---------------------------------------

# Given a call that runs a fail2ban binary no exec entry lists.
printf '\ncontracts_gate_probe() { docker exec -u root fail2ban fail2ban-client ping; }\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then it fails and names the caller, the container and the command.
assert_rc 1 "a docker exec no exec entry covers fails"
assert_contains "$OUT" "missing contract: scripts/lib/health.sh exec fail2ban fail2ban-client ping" \
    "the failure names the uncovered exec after its flags"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- an exec entry no call reaches ------------------------------------------

# Given an exec entry for a command nothing runs.
EXEC_CONTRACT="$FIXTURE/tests/contracts/fail2ban.yml"
exec_backup=$(cat "$EXEC_CONTRACT")
printf '  - {id: gate-ping, command: [fail2ban-client, ping], callers: [scripts/lib/health.sh]}\n' \
    >>"$EXEC_CONTRACT"

# When the gate runs.
run_gate

# Then it fails as a dead entry that names the command.
assert_rc 1 "an exec entry nothing runs fails"
assert_contains "$OUT" "dead contract entry: fail2ban gate-ping (exec fail2ban-client ping)" \
    "the failure names the dead exec entry"
printf '%s\n' "$exec_backup" >"$EXEC_CONTRACT"

# --- a docker exec whose container cannot be read ---------------------------

# Given a call into a container held in a variable that no assignment names.
printf '\ncontracts_gate_probe() { docker exec "$gate_box" fail2ban-client reload; }\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then it fails closed as unparseable and says which call form it reads.
assert_rc 1 "a docker exec into an unknown container fails"
assert_contains "$OUT" "unparseable exec: scripts/lib/health.sh: docker exec \"\$gate_box\"" \
    "the failure names the unparseable call"
assert_contains "$OUT" "with a literal container" "the failure names the call form to use"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- a container variable that names one service ----------------------------

# Given a call into a variable assigned the literal name fail2ban in the same function.
printf '\ncontracts_gate_probe() {\n    local box=fail2ban\n    docker exec "$box" fail2ban-client reload\n}\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then the call is attributed to the fail2ban reload entry, so its callers differ.
assert_rc 1 "a docker exec through a service variable is checked"
assert_contains "$OUT" "caller mismatch: fail2ban client-reload" \
    "the variable container resolves to its service entry"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

# --- the dry-run sandbox is excluded only in its own file -------------------

# Given the dry-run sandbox call shape, copied into another file.
DRY_RUN="$FIXTURE/scripts/lib/dry-run.sh"
assert_contains "$(cat "$DRY_RUN")" 'docker exec -u mstest "$cname" mkdir' \
    "the dry-run sandbox exec is in the scanned tree"
printf '\ncontracts_gate_probe() { docker exec -u mstest "$cname" mkdir -p /x; }\n' \
    >>"$PROBED_CALLER"

# When the gate runs.
run_gate

# Then the copy fails as unparseable, while the dry-run file's own calls do not.
assert_rc 1 "the sandbox container outside dry-run.sh fails"
assert_contains "$OUT" "unparseable exec: scripts/lib/health.sh" "the copied call is not excluded"
assert_not_contains "$OUT" "scripts/lib/dry-run.sh" "the dry-run sandbox calls stay excluded"
printf '%s\n' "$caller_backup" >"$PROBED_CALLER"

run_gate
assert_rc 0 "restoring both files restores the check to green"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/naming-gate.sh
#
# Regression proof for the structural checks in tests/naming.sh: the
# service-module shape gate (every scripts/services/<svc>/main.sh defines
# configure_<svc>()) and the import-direction gate (no cross-service source, no
# peer scripts/setup module source). A gate that cannot be shown to fail is a
# gate nobody can trust, so every rule is probed with one fabricated violation.
#
# The fixture is a throwaway git repo built from `git archive HEAD`: the gate
# derives its populations from `git ls-files`, so it needs a real repository,
# and the real tree is never written to. Pure bash + git — no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="naming-gate"
scenario_begin "$CURRENT_SCENARIO"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

git -C "$REPO_ROOT" archive HEAD | tar -x -C "$FIXTURE" || {
    fail "fixture tree is exported" "git archive failed"
    summary
    exit 1
}
# The gate under test is the working-tree copy, not HEAD's.
cp "$REPO_ROOT/tests/naming.sh" "$FIXTURE/tests/naming.sh"
git -C "$FIXTURE" init -q .
git -C "$FIXTURE" config user.email naming@example.invalid
git -C "$FIXTURE" config user.name naming
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -qm "fixture"

# RC/OUT are globals: a command substitution would run the gate in a subshell
# and leave the caller reading a stale exit code.
RC=0
OUT=""
run_gate() {
    OUT=$("$FIXTURE/tests/naming.sh" 2>&1)
    RC=$?
}

reset_fixture() { git -C "$FIXTURE" checkout -q -- .; }

assert_rc() {
    local expected="$1" name="$2"
    if [[ "$RC" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected rc $expected, got $RC: $OUT"
    fi
}

# --- the clean tree ---------------------------------------------------------

run_gate
assert_rc 0 "the clean tree passes every naming gate"
assert_contains "$OUT" "service modules checked for their configurator" \
    "the clean run reports the service-module population"
assert_contains "$OUT" "import edges checked" "the clean run reports the import-edge population"

# ddns-updater and uptime-kuma pass only because the directory hyphen is mapped
# to an underscore; a literal comparison would fail the clean tree above.
assert_file_contains "$FIXTURE/scripts/services/ddns-updater/main.sh" \
    "configure_ddns_updater()" "a hyphenated service directory owns an underscored configurator"

# --- service-module shape ---------------------------------------------------

sed -i 's/^configure_bazarr()/configure_bazarr_renamed()/' \
    "$FIXTURE/scripts/services/bazarr/main.sh"
run_gate
assert_rc 1 "a service module without its configurator fails"
assert_contains "$OUT" "does not define configure_bazarr()" "the failure names the missing configurator"
assert_contains "$OUT" "structure.md" "the failure points at the placement contract"
reset_fixture

sed -i 's/^configure_ddns_updater()/configure_ddns_updater_renamed()/' \
    "$FIXTURE/scripts/services/ddns-updater/main.sh"
run_gate
assert_rc 1 "a hyphenated service module without its configurator fails"
assert_contains "$OUT" "does not define configure_ddns_updater()" \
    "the failure asks for the underscored name, not the directory name"
reset_fixture

# --- import direction -------------------------------------------------------

printf 'source "$SCRIPT_DIR/scripts/services/npm/certs.sh"\n' \
    >>"$FIXTURE/scripts/services/bazarr/main.sh"
run_gate
assert_rc 1 "a service module sourcing another service fails"
assert_contains "$OUT" "may not source another service" "the failure names the cross-service rule"
assert_contains "$OUT" "scripts/services/bazarr/main.sh -> scripts/services/npm/certs.sh" \
    "the failure names the offending edge"
reset_fixture

{
    printf '_NAMING_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'source "$_NAMING_PROBE_DIR/packages.sh"\n'
} >>"$FIXTURE/scripts/setup/checks.sh"
run_gate
assert_rc 1 "a setup module sourcing a peer setup module fails"
assert_contains "$OUT" "may not source a peer scripts/setup module" \
    "the failure names the cross-module rule"
assert_contains "$OUT" "scripts/setup/checks.sh -> scripts/setup/packages.sh" \
    "the failure names the offending setup edge"
reset_fixture

# A module's own concern directory is the sanctioned direction, not a violation.
{
    printf '_NAMING_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'source "$_NAMING_PROBE_DIR/checks/preflight.sh"\n'
} >>"$FIXTURE/scripts/setup/checks.sh"
run_gate
assert_rc 0 "sourcing a module's own concern directory stays clean"
reset_fixture

# The sanctioned-seam list is not a place to leave dead entries.
sed -i '/env_gen_dir\/env-write.sh/d' "$FIXTURE/scripts/setup/env-gen.sh"
run_gate
assert_rc 2 "a sanctioned seam whose import disappeared is a stale entry"
assert_contains "$OUT" "stale sanctioned seam" "the stale entry is named as such"
reset_fixture

run_gate
assert_rc 0 "the fixture is green again after every probe"

expected=19
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

scenario_end "$CURRENT_SCENARIO"
summary

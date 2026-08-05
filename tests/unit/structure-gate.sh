#!/usr/bin/env bash
# tests/unit/structure-gate.sh
#
# Regression proof for tests/structure.sh: the service-module shape gate
# (every scripts/services/<svc>/main.sh defines configure_<svc>()) and the
# import-direction gate (no cross-service source, no peer scripts/setup
# module source, and a non-setup file sourcing a setup module is not a
# violation). A gate that cannot be shown to fail is a gate nobody can
# trust, so every rule is probed with one fabricated violation.
#
# The fixture is a throwaway git repo built from `git archive HEAD`: the gate
# derives its populations from `git ls-files`, so it needs a real repository,
# and the real tree is never written to. Pure bash + git — no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="structure-gate"
scenario_begin "$CURRENT_SCENARIO"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

export_fixture_tree "$REPO_ROOT" "$FIXTURE"
# The gate under test is the working-tree copy, not HEAD's.
cp "$REPO_ROOT/tests/structure.sh" "$FIXTURE/tests/structure.sh"
git -C "$FIXTURE" init -q .
git -C "$FIXTURE" config user.email structure@example.invalid
git -C "$FIXTURE" config user.name structure
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -qm "fixture"

run_gate() { run_cmd "$FIXTURE/tests/structure.sh"; }

reset_fixture() { git -C "$FIXTURE" checkout -q -- .; }

# --- the clean tree ---------------------------------------------------------

run_gate
assert_rc 0 "the clean tree passes every structure gate"
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
    printf '_STRUCTURE_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'source "$_STRUCTURE_PROBE_DIR/packages.sh"\n'
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
    printf '_STRUCTURE_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'source "$_STRUCTURE_PROBE_DIR/checks/preflight.sh"\n'
} >>"$FIXTURE/scripts/setup/checks.sh"
run_gate
assert_rc 0 "sourcing a module's own concern directory stays clean"
reset_fixture

# A non-setup file sourcing a top-level scripts/setup module is the
# sanctioned setup.sh -> scripts/setup/* direction, not a violation — the
# gate only forbids a setup module sourcing a *peer* setup module.
{
    printf '_STRUCTURE_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'source "$_STRUCTURE_PROBE_DIR/../../setup/packages.sh"\n'
} >>"$FIXTURE/scripts/services/bazarr/main.sh"
run_gate
assert_rc 0 "a non-setup module sourcing a setup module is not a violation"
reset_fixture

# The sanctioned-seam list is not a place to leave dead entries.
sed -i '/env_gen_dir\/env-write.sh/d' "$FIXTURE/scripts/setup/env-gen.sh"
run_gate
assert_rc 2 "a sanctioned seam whose import disappeared is a stale entry"
assert_contains "$OUT" "stale sanctioned seam" "the stale entry is named as such"
reset_fixture

run_gate
assert_rc 0 "the fixture is green again after every probe"

expected=20
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

scenario_end "$CURRENT_SCENARIO"
summary

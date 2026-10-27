#!/usr/bin/env bash
# Exercise the real fixture readers rather than stubbing their validation.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/assertions/arr-indexers.sh"
source "$REPO_ROOT/tests/assertions/jackett.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
dind_python() { (cd "$TMP_DIR" && python3 -I - "$@"); }

scenario_begin assertion-fixtures
for fixture in 'indexers: [null]' 'indexers: [{id: fixture, type: typo}]' 'indexers: null' '[]'; do
    # Given a malformed indexer fixture in the scenario checkout.
    printf '%s\n' "$fixture" >"$TMP_DIR/config.yml"

    # When the real Arr fixture reader inspects it.
    result=$(arr_fixture_indexer_total 'general tv')

    # Then malformed data cannot become a zero count and a skipped check.
    assert_contains "$result" 'ERR:' "Arr rejects malformed fixture: $fixture"
done

# Given a fixture whose only entry is not an object.
printf 'indexers: [null]\n' >"$TMP_DIR/config.yml"

# When the real Jackett reader inspects it.
result=$(jackett_fixture_indexer_ids)

# Then it cannot silently discard the entry and skip capability checks.
assert_contains "$result" 'ERR:' 'Jackett rejects non-object indexer entries'

# Given an explicitly empty indexer list.
printf 'indexers: []\n' >"$TMP_DIR/config.yml"

# When each reader inspects it.
arr_result=$(arr_fixture_indexer_total 'general tv')
jackett_result=$(jackett_fixture_indexer_ids)

# Then it remains distinguishable from a failed or malformed fixture.
assert_eq '0' "$arr_result" 'Arr recognises an explicitly empty fixture'
assert_eq 'NONE' "$jackett_result" 'Jackett recognises an explicitly empty fixture'
summary

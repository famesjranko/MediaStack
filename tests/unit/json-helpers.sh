#!/usr/bin/env bash
# tests/unit/json-helpers.sh
#
# Unit tests for scripts/lib/json.sh helpers. No DinD, no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="json-helpers"
echo -e "${CYAN}${BOLD}▶ scenario: json-helpers${NC}"

source "$REPO_ROOT/scripts/lib/json.sh"

set +e
set +u

# ─── json_get ────────────────────────────────────────────────────────────────

assert_eq "bar" "$(echo '{"foo":"bar"}' | json_get foo)" \
    "json_get: string value"

assert_eq "42" "$(echo '{"n":42}' | json_get n)" \
    "json_get: numeric value"

assert_eq "True" "$(echo '{"ok":true}' | json_get ok)" \
    "json_get: boolean true"

assert_eq "False" "$(echo '{"ok":false}' | json_get ok)" \
    "json_get: boolean false"

for INPUT in '{"a":1}' '{"missing":null}' '{}' 'not json' ''; do
    # Given JSON that cannot supply the required field

    # When the scalar extractor reads that field
    OUTPUT=$(json_get missing <<<"$INPUT" 2>/dev/null)
    RC=$?

    # Then it fails and emits no substitute value
    assert_eq 1 "$RC" "json_get rejects unavailable value ($INPUT)"
    assert_eq "" "$OUTPUT" "json_get emits no default ($INPUT)"
done

# ─── json_path ───────────────────────────────────────────────────────────────

assert_eq "val" "$(echo '{"a":{"b":"val"}}' | json_path a.b)" \
    "json_path: 2-level path"

assert_eq "deep" "$(echo '{"a":{"b":{"c":"deep"}}}' | json_path a.b.c)" \
    "json_path: 3-level path"

for INPUT in '{"a":{}}' '{"a":1}' '{"a":{"b":null}}'; do
    # Given an unavailable nested field

    # When the nested extractor reads it
    OUTPUT=$(json_path a.b <<<"$INPUT" 2>/dev/null)
    RC=$?

    # Then no fabricated path value is returned
    assert_eq 1 "$RC" "json_path rejects unavailable nested field ($INPUT)"
    assert_eq "" "$OUTPUT" "json_path emits no default ($INPUT)"
done

assert_eq "42" "$(echo '{"a":{"b":42}}' | json_path a.b)" \
    "json_path: numeric leaf"

assert_eq "False" "$(echo '{"a":{"b":false}}' | json_path a.b)" \
    "json_path: boolean false leaf"

assert_eq "top" "$(echo '{"x":"top"}' | json_path x)" \
    "json_path: single-level (like json_get)"

# ─── json_has_name ───────────────────────────────────────────────────────────

echo '[{"name":"foo"},{"name":"bar"}]' | json_has_name "foo"
assert_eq "0" "$?" "json_has_name: match returns 0"

echo '[{"name":"foo"},{"name":"bar"}]' | json_has_name "baz"
assert_eq "1" "$?" "json_has_name: no match returns 1"

echo '[{"id":"abc"},{"id":"xyz"}]' | json_has_name "xyz" --field id
assert_eq "0" "$?" "json_has_name: --field id"

echo '[{"name":"FOO"}]' | json_has_name "foo" -i
assert_eq "0" "$?" "json_has_name: -i case-insensitive"

echo '[{"name":"FOO"}]' | json_has_name "foo"
assert_eq "1" "$?" "json_has_name: case-sensitive fails"

echo '{"data":[{"name":"inner"}]}' | json_has_name "inner" --key data
assert_eq "0" "$?" "json_has_name: --key drills into nested array"

echo '{"data":[{"name":"other"}]}' | json_has_name "inner" --key data
assert_eq "1" "$?" "json_has_name: --key miss returns 1"

echo '[]' | json_has_name "x"
assert_eq "1" "$?" "json_has_name: empty array returns 1"

echo 'bad json' | json_has_name "x"
assert_eq "1" "$?" "json_has_name: invalid JSON returns 1"

# ─── json_array_nonempty ─────────────────────────────────────────────────────

echo '[{"a":1}]' | json_array_nonempty
assert_eq "0" "$?" "json_array_nonempty: non-empty returns 0"

echo '[1,2,3]' | json_array_nonempty
assert_eq "0" "$?" "json_array_nonempty: scalar array returns 0"

echo '[]' | json_array_nonempty
assert_eq "1" "$?" "json_array_nonempty: empty array returns 1"

echo '{}' | json_array_nonempty
assert_eq "1" "$?" "json_array_nonempty: object returns 1"

echo 'invalid' | json_array_nonempty
assert_eq "1" "$?" "json_array_nonempty: invalid JSON returns 1"

# Given explicit empty inventories, false, zero and nullable API fields
for CASE in \
    '[]|:array' \
    '{}|:object' \
    '{"enabled":false}|enabled:boolean' \
    '{"count":0}|count:integer' \
    '{"firewallIps":null}|firewallIps:nullable-array' \
    '{"size":null}|size:nullable-number' \
    '{"size":0}|size:nullable-number' \
    '{}|size?:nullable-number' \
    '{"size":null}|size?:nullable-number' \
    '{"size":0}|size?:nullable-number' \
    '{"fixture":{"savePath":""}}|*.savePath:string'; do
    # When their declared contract is checked
    json_require "${CASE#*|}" <<<"${CASE%%|*}" >/dev/null 2>&1

    # Then real empty and nullable values remain usable
    assert_eq 0 "$?" "json_require accepts $CASE"
done

# Given wrong field types and incomplete inventories
for CASE in \
    '{}|:array' \
    '[]|:object' \
    '{"enabled":0}|enabled:boolean' \
    '{"count":false}|count:integer' \
    '{}|firewallIps:nullable-array' \
    '{"firewallIps":{}}|firewallIps:nullable-array' \
    '{"size":false}|size:nullable-number' \
    '{"size":"0"}|size:nullable-number' \
    '{"size":false}|size?:nullable-number' \
    '{"fixture":{}}|*.savePath:string' \
    '{"items":[{"id":1},{}]}|items[].id:integer'; do
    # When their declared contract is checked
    OUTPUT=$(json_require "${CASE#*|}" <<<"${CASE%%|*}" 2>/dev/null)
    RC=$?

    # Then no invalid response reaches the caller
    assert_eq 1 "$RC" "json_require rejects $CASE"
    assert_eq "" "$OUTPUT" "json_require emits no invalid response ($CASE)"
done

# ─── summary ─────────────────────────────────────────────────────────────────

summary

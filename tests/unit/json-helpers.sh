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

assert_eq "" "$(echo '{"a":1}' | json_get missing)" \
    "json_get: missing key returns empty"

assert_eq "fallback" "$(echo '{"a":1}' | json_get missing fallback)" \
    "json_get: missing key returns custom default"

assert_eq "fallback" "$(echo '{"k":null}' | json_get k fallback)" \
    "json_get: null value returns default"

assert_eq "" "$(echo '{}' | json_get x)" \
    "json_get: empty object"

assert_eq "oops" "$(echo 'not json' | json_get x oops)" \
    "json_get: invalid JSON returns default"

assert_eq "" "$(echo '' | json_get x)" \
    "json_get: empty input returns empty"

# ─── json_path ───────────────────────────────────────────────────────────────

assert_eq "val" "$(echo '{"a":{"b":"val"}}' | json_path a.b)" \
    "json_path: 2-level path"

assert_eq "deep" "$(echo '{"a":{"b":{"c":"deep"}}}' | json_path a.b.c)" \
    "json_path: 3-level path"

assert_eq "" "$(echo '{"a":{"b":"val"}}' | json_path a.x)" \
    "json_path: missing leaf returns empty"

assert_eq "" "$(echo '{"a":1}' | json_path a.b.c)" \
    "json_path: non-dict intermediate returns empty"

assert_eq "0" "$(echo '{"a":{}}' | json_path a.b 0)" \
    "json_path: missing path returns custom default"

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

# ─── summary ─────────────────────────────────────────────────────────────────

summary

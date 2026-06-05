#!/usr/bin/env bash
# tests/unit/common.sh
#
# Focused unit coverage for shared helpers in scripts/lib/common.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="common"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$TMP_DIR"
CONFIG_FILE="$TMP_DIR/config.yml"
touch "$CONFIG_FILE"

source "$REPO_ROOT/scripts/lib/common.sh"

LAST_WARN=""
log_ok() { :; }
log_info() { :; }
log_warn() { LAST_WARN="$1"; }
log_skip() { :; }
log_error() { :; }

reset_env() {
    printf '%s\n' \
        "TEST_API_KEY=old" \
        "OTHER_KEY=keep" \
        > "$SCRIPT_DIR/.env"
    chmod 600 "$SCRIPT_DIR/.env"
    unset TEST_API_KEY NEW_API_KEY
    LAST_WARN=""
}

source_env_value() {
    local env_path="$1" key="$2"
    (
        set -a
        # shellcheck source=/dev/null
        source "$env_path"
        set +a
        printf '%s' "${!key:-}"
    )
}

reset_env
special_value='abc&def|ghi/jkl'
save_api_key TEST_API_KEY "$special_value"
rc=$?
assert_eq "0" "$rc" "save_api_key: special value write succeeds"
assert_eq "TEST_API_KEY='$special_value'" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "save_api_key: quotes ampersand pipe and slash value"
assert_eq "$special_value" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "save_api_key: written special value is sourceable"
assert_eq "$special_value" "${TEST_API_KEY:-}" "save_api_key: exports updated value"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "save_api_key: preserves unrelated lines"

append_value='https://jellyfin.example.test/a/b?x=1&y=2'
save_api_key NEW_API_KEY "$append_value"
rc=$?
assert_eq "0" "$rc" "save_api_key: append succeeds"
assert_eq "NEW_API_KEY='$append_value'" "$(grep '^NEW_API_KEY=' "$SCRIPT_DIR/.env")" "save_api_key: appends quoted missing key"
assert_eq "$append_value" "$(source_env_value "$SCRIPT_DIR/.env" NEW_API_KEY)" "save_api_key: appended value is sourceable"

reset_env
same_value='abc&def|ghi/jkl'
printf '%s\n' "TEST_API_KEY=$same_value" "OTHER_KEY=keep" > "$SCRIPT_DIR/.env"
save_api_key TEST_API_KEY "$same_value"
rc=$?
assert_eq "0" "$rc" "save_api_key: canonicalizes existing unquoted value"
assert_eq "TEST_API_KEY='$same_value'" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "save_api_key: rewrites existing match as quoted"

reset_env
before=$(<"$SCRIPT_DIR/.env")
save_api_key TEST_API_KEY $'bad\nvalue' >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "save_api_key: rejects newline values"
assert_eq "$before" "$after" "save_api_key: preserves .env on newline rejection"
assert_eq "" "${TEST_API_KEY:-}" "save_api_key: rejected newline value is not exported"
assert_contains "$LAST_WARN" "contains a newline" "save_api_key: newline rejection warns"

reset_env
before=$(<"$SCRIPT_DIR/.env")
save_api_key TEST_API_KEY "bad'value" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "save_api_key: rejects single quote values"
assert_eq "$before" "$after" "save_api_key: preserves .env on single quote rejection"
assert_eq "" "${TEST_API_KEY:-}" "save_api_key: rejected quote value is not exported"
assert_contains "$LAST_WARN" "single quote" "save_api_key: single quote rejection warns"

# ---------------------------------------------------------------------------
# _set_env_var (the launcher's .env writer) — must round-trip nasty values
# byte-exact through a re-source and never disturb unrelated keys. It shares
# the one hardened writer with save_api_key, so the same quoting/atomic
# guarantees apply (#15 / #34 cluster).
# ---------------------------------------------------------------------------
# Stand in the launcher's shoes: it defines _set_env_var inline, so mirror the
# exact current body here pointed at the same shared writer, then exercise it.
_set_env_var() {
    local key="$1" val="$2" file="$SCRIPT_DIR/.env" status
    [[ -f "$file" ]] || return 1
    if ! status=$(_env_write_kv "$file" "$key" "$val"); then
        _env_write_kv_warn "$key" "$status"
        return 1
    fi
}

# A battery of values that an unquoted writer would corrupt or mis-parse.
declare -a NASTY_VALUES=(
    'plain'
    'has spaces here'
    'with"double'
    'dollar$VAR and ${BRACE}'
    'back\slash'
    'hash # mark'
    'equals=sign=here'
    '  leading and trailing  '
    'mix "q" $x \\ # = end'
)
for nasty in "${NASTY_VALUES[@]}"; do
    reset_env
    _set_env_var ROUND_TRIP "$nasty"
    rc=$?
    assert_eq "0" "$rc" "_set_env_var: write succeeds [$nasty]"
    got=$(source_env_value "$SCRIPT_DIR/.env" ROUND_TRIP)
    assert_eq "$nasty" "$got" "_set_env_var: round-trips byte-exact [$nasty]"
    # The pre-existing, unrelated key must survive every write untouched.
    assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: leaves OTHER_KEY untouched [$nasty]"
    assert_eq "TEST_API_KEY=old" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: leaves TEST_API_KEY untouched [$nasty]"
done

# Replace-in-place: re-writing an existing key updates only that line.
reset_env
_set_env_var TEST_API_KEY 'a b $c'
assert_eq "a b \$c" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "_set_env_var: replaces an existing key's value"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: replace leaves unrelated key untouched"
assert_eq "1" "$(grep -c '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: replace does not duplicate the key"

# Append-if-absent: a missing key is added without touching existing lines.
reset_env
_set_env_var BRAND_NEW 'appended value'
assert_eq "appended value" "$(source_env_value "$SCRIPT_DIR/.env" BRAND_NEW)" "_set_env_var: appends a missing key"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: append leaves unrelated key untouched"

# Refusal path: a single quote / newline is rejected and the file is untouched.
reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_var BAD_VAL "has'quote" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_var: rejects single-quote value"
assert_eq "$before" "$after" "_set_env_var: preserves .env on single-quote rejection"

reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_var BAD_VAL $'has\nnewline' >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_var: rejects newline value"
assert_eq "$before" "$after" "_set_env_var: preserves .env on newline rejection"

# Missing .env: write is a no-op failure, not a crash.
reset_env
rm -f "$SCRIPT_DIR/.env"
_set_env_var ANY value >/dev/null 2>&1
assert_eq "1" "$?" "_set_env_var: returns non-zero when .env is absent"

scenario_end "$CURRENT_SCENARIO"
summary

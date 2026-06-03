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

scenario_end "$CURRENT_SCENARIO"
summary

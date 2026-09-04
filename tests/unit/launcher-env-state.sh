#!/usr/bin/env bash
# tests/unit/launcher-env-state.sh
#
# Unit coverage for scripts/launcher/env-state.sh — the launcher's durable .env
# writer and reloader. The production file is sourced directly (no mirrored
# copy of its body), so a change to the writer that these assertions do not
# tolerate fails here rather than passing against a stale hand-copy.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-env-state"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# The launcher's helpers address .env through SCRIPT_DIR, so point it at the
# fixture before sourcing anything that reads it.
SCRIPT_DIR="$TMP_DIR"
CONFIG_FILE="$TMP_DIR/config.yml"
touch "$CONFIG_FILE"

source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/launcher/env-state.sh
source "$REPO_ROOT/scripts/launcher/env-state.sh"

WARNS=()
log_ok() { :; }
log_info() { :; }
log_warn() { WARNS+=("$1"); }
log_skip() { :; }
log_error() { :; }

reset_env() {
    printf '%s\n' "TEST_API_KEY=old" "OTHER_KEY=keep" >"$SCRIPT_DIR/.env"
    WARNS=()
    unset TEST_API_KEY OTHER_KEY ROUND_TRIP BRAND_NEW SECOND_KEY BAD_VAL 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Single pair — nasty values must round-trip byte-exact through a re-source and
# never disturb an unrelated key.
# ---------------------------------------------------------------------------
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
    _set_env_vars ROUND_TRIP "$nasty"
    rc=$?
    assert_eq "0" "$rc" "_set_env_vars: write succeeds [$nasty]"
    got=$(source_env_value "$SCRIPT_DIR/.env" ROUND_TRIP)
    assert_eq "$nasty" "$got" "_set_env_vars: round-trips byte-exact [$nasty]"
    assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: leaves OTHER_KEY untouched [$nasty]"
    assert_eq "TEST_API_KEY=old" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: leaves TEST_API_KEY untouched [$nasty]"
done

# Replace-in-place: re-writing an existing key updates only that line.
reset_env
_set_env_vars TEST_API_KEY 'a b $c'
assert_eq "a b \$c" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "_set_env_vars: replaces an existing key's value"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: replace leaves unrelated key untouched"
assert_eq "1" "$(grep -c '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: replace does not duplicate the key"

# Append-if-absent: a missing key is added without touching existing lines.
reset_env
_set_env_vars BRAND_NEW 'appended value'
assert_eq "appended value" "$(source_env_value "$SCRIPT_DIR/.env" BRAND_NEW)" "_set_env_vars: appends a missing key"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: append leaves unrelated key untouched"

# ---------------------------------------------------------------------------
# Several pairs — one call, all-or-nothing. A two-key setting (e.g. SMB_ENABLED
# + SMB_SHARE_SCOPE) must never be half-written, so a bad value anywhere in the
# set leaves .env exactly as it was and warns once per key.
# ---------------------------------------------------------------------------
reset_env
_set_env_vars TEST_API_KEY 'replaced' BRAND_NEW 'added' SECOND_KEY 'also added'
rc=$?
assert_eq "0" "$rc" "_set_env_vars: multi-pair write succeeds"
assert_eq "replaced" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "_set_env_vars: multi-pair replaces in place"
assert_eq "added" "$(source_env_value "$SCRIPT_DIR/.env" BRAND_NEW)" "_set_env_vars: multi-pair appends the first missing key"
assert_eq "also added" "$(source_env_value "$SCRIPT_DIR/.env" SECOND_KEY)" "_set_env_vars: multi-pair appends the second missing key"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_vars: multi-pair leaves unrelated key untouched"

reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_vars BRAND_NEW 'fine' BAD_VAL "has'quote" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_vars: one bad pair refuses the whole write"
assert_eq "$before" "$after" "_set_env_vars: refused multi-pair write leaves .env byte-identical"
assert_eq "2" "${#WARNS[@]}" "_set_env_vars: refused multi-pair write warns once per key"
assert_contains "${WARNS[*]}" "BRAND_NEW" "_set_env_vars: refusal names the first key"
assert_contains "${WARNS[*]}" "BAD_VAL" "_set_env_vars: refusal names the offending key"

# Refusal paths for a single pair: the file is untouched and the operator warned.
reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_vars BAD_VAL "has'quote" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_vars: rejects single-quote value"
assert_eq "$before" "$after" "_set_env_vars: preserves .env on single-quote rejection"
assert_contains "${WARNS[*]}" "single quote" "_set_env_vars: single-quote rejection warns"

reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_vars BAD_VAL $'has\nnewline' >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_vars: rejects newline value"
assert_eq "$before" "$after" "_set_env_vars: preserves .env on newline rejection"
assert_contains "${WARNS[*]}" "newline" "_set_env_vars: newline rejection warns"

# ---------------------------------------------------------------------------
# Argument shape — a caller that loses a value must not write half a setting.
# ---------------------------------------------------------------------------
reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_vars ODD_KEY value LONE_KEY >/dev/null 2>&1
rc=$?
assert_eq "1" "$rc" "_set_env_vars: odd argument count is refused"
assert_eq "$before" "$(<"$SCRIPT_DIR/.env")" "_set_env_vars: odd argument count writes nothing"

reset_env
_set_env_vars LONE_KEY >/dev/null 2>&1
assert_eq "1" "$?" "_set_env_vars: a key with no value is refused"
reset_env
_set_env_vars >/dev/null 2>&1
assert_eq "1" "$?" "_set_env_vars: no arguments is refused"

# Missing .env: write is a no-op failure, not a crash.
reset_env
rm -f "$SCRIPT_DIR/.env"
_set_env_vars ANY value >/dev/null 2>&1
assert_eq "1" "$?" "_set_env_vars: returns non-zero when .env is absent"

# ---------------------------------------------------------------------------
# _reload_env — brings a just-persisted value into the running shell (that is
# what lets a menu redraw show the new state) and tolerates a missing file.
# ---------------------------------------------------------------------------
reset_env
_set_env_vars ROUND_TRIP 'reloaded value'
unset ROUND_TRIP
_reload_env
assert_eq "0" "$?" "_reload_env: succeeds after a write"
assert_eq "reloaded value" "${ROUND_TRIP:-}" "_reload_env: exports the persisted value into the shell"

rm -f "$SCRIPT_DIR/.env"
_reload_env
assert_eq "0" "$?" "_reload_env: missing .env is not an error"

scenario_end "$CURRENT_SCENARIO"
summary

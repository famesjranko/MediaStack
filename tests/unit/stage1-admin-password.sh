#!/usr/bin/env bash
# tests/unit/stage1-admin-password.sh
#
# Issue #95: the shared admin password must NEVER be auto-generated. Stage 1 collects
# it with NO default (a bare Enter is rejected by validate_admin_password), validated,
# and confirmed by re-entry. This unit pins that contract on _stage1_collect_admin:
#   1. The password prompt is offered with an EMPTY default (no openssl-rand default,
#      no prior-password default) and the typed value is what persists.
#   2. The confirm must match — a mismatch re-prompts; a match accepts.
#   3. The UI_DEMO/DEMO walk-through guard returns a valid placeholder without prompting.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-admin-password"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/validators.sh"
source "$REPO_ROOT/scripts/setup/stages/stage1.sh"

set +e
set +u

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSWORD_DEFAULT_FILE="$TMP_DIR/password-default"
OPENSSL_CALLED_FILE="$TMP_DIR/openssl-called"
CONFIRM_CALLS_FILE="$TMP_DIR/confirm-calls"
DEMO_PROMPT_FILE="$TMP_DIR/demo-prompted"

ui_section() { :; }
ui_log() { :; }
log_error() { :; }

# Spy: #95 forbids auto-generation. If anything reaches for `openssl rand` to seed a
# default, record it so the assertions below can fail loudly.
openssl() {
    if [[ "${1:-}" == "rand" ]]; then
        printf '%s\n' "called" > "$OPENSSL_CALLED_FILE"
        printf '%s\n' "GeneratedShouldNeverBeUsed123"
        return 0
    fi
    command openssl "$@"
}

# Admin username + email still use ui_input_validated; just echo their defaults.
ui_input_validated() {
    printf '%s\n' "${2:-}"
}

# =========================================================================
# Test 1: no default is offered, the typed value persists, openssl is never used
# =========================================================================
# Capture the default the password prompt is offered with; return a user-typed value.
ui_password_validated() {
    local prompt="$1" default="$2"
    if [[ "$prompt" == Admin\ password* ]]; then
        printf '%s\n' "$default" > "$PASSWORD_DEFAULT_FILE"
    fi
    printf '%s\n' "UserTyped-Pw-123456"
}
# Confirm matches the typed value on the first try.
ui_password() { printf '%s\n' "UserTyped-Pw-123456"; }

rm -f "$PASSWORD_DEFAULT_FILE" "$OPENSSL_CALLED_FILE"
# Even with a VALID 12-char prior password set, it must NOT be pre-filled as the default.
_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
_WIZ_PREV_PW="validprior12"
_stage1_collect_admin

assert_eq "" "$(cat "$PASSWORD_DEFAULT_FILE" 2>/dev/null)" "Stage 1 admin password: prompt offers NO default (never pre-filled, never auto-generated)"
if [[ -f "$OPENSSL_CALLED_FILE" ]]; then
    fail "Stage 1 admin password: openssl rand is never used to seed a default" "openssl rand was called"
else
    pass "Stage 1 admin password: openssl rand is never used to seed a default"
fi
assert_eq "UserTyped-Pw-123456" "$_WIZ_ADMIN_PW" "Stage 1 admin password: the user-typed value is what persists"

# =========================================================================
# Test 2: confirm must match — a mismatch re-prompts, a match accepts
# =========================================================================
printf '0\n' > "$CONFIRM_CALLS_FILE"
ui_password_validated() { printf '%s\n' "Match-Me-Pw-1234"; }
# First confirm mismatches; second confirm matches.
ui_password() {
    local n
    n=$(cat "$CONFIRM_CALLS_FILE")
    n=$((n + 1))
    printf '%s\n' "$n" > "$CONFIRM_CALLS_FILE"
    if [[ "$n" -eq 1 ]]; then
        printf '%s\n' "Wrong-Confirm-99"
    else
        printf '%s\n' "Match-Me-Pw-1234"
    fi
}

_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
_stage1_collect_admin

assert_eq "Match-Me-Pw-1234" "$_WIZ_ADMIN_PW" "Stage 1 admin password: only a matching confirm is accepted"
assert_eq "2" "$(cat "$CONFIRM_CALLS_FILE" 2>/dev/null)" "Stage 1 admin password: a mismatched confirm re-prompts (2 confirm reads)"

# =========================================================================
# Test 3: UI_DEMO/DEMO walk-through uses a valid placeholder without prompting
# =========================================================================
rm -f "$DEMO_PROMPT_FILE"
ui_password_validated() { printf '%s\n' "demo-violation" > "$DEMO_PROMPT_FILE"; printf '%s\n' "x"; }
ui_password() { printf '%s\n' "demo-violation" > "$DEMO_PROMPT_FILE"; printf '%s\n' "x"; }

_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
UI_DEMO=1 _stage1_collect_admin

assert_eq "DemoAdminPassword123" "$_WIZ_ADMIN_PW" "Stage 1 admin password: UI_DEMO uses a valid placeholder"
if [[ -f "$DEMO_PROMPT_FILE" ]]; then
    fail "Stage 1 admin password: UI_DEMO never prompts for a password" "a password prompt fired under UI_DEMO"
else
    pass "Stage 1 admin password: UI_DEMO never prompts for a password"
fi

scenario_end "$CURRENT_SCENARIO"
summary

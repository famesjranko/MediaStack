#!/usr/bin/env bash
# tests/unit/stage1-admin-password.sh
#
# Issue #95: the shared admin password must NEVER be auto-generated. Stage 1 collects
# it with NO default (a bare Enter is rejected by validate_admin_password), shows it
# as typed (user preference), and accepts it via a persistent review step (not a
# re-typed confirm). This unit pins that contract on _stage1_collect_admin:
#   1. The password prompt is offered with an EMPTY default (no openssl-rand default,
#      no prior-password default) and the typed value is what persists.
#   2. The review must be accepted — "Re-enter" re-collects; "Use these details" accepts.
#   3. The UI_DEMO/DEMO walk-through returns a valid placeholder without a real prompt.

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
REVIEW_CALLS_FILE="$TMP_DIR/review-calls"

ui_section() { :; }
ui_log() { :; }
log_error() { :; }
ui_kv() { :; }
# The review step accepts on the first pass unless a test overrides ui_choose.
ui_choose() { printf '%s\n' "Use these details"; }

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

# All three admin fields now use ui_input_validated (the password visibly, by
# preference). Capture the password prompt's default; return valid values for
# username/email; honor UI_DEMO (return the demo default, arg 4) so the walk-through
# never blocks. PW_RETURN lets each test pick the "typed" password.
ui_input_validated() {
    local prompt="$1" default="$2" demo="${4:-}"
    if [[ -n "${UI_DEMO:-}" ]]; then
        printf '%s\n' "${demo:-$default}"
        return 0
    fi
    case "$prompt" in
        Admin\ password*) printf '%s\n' "$default" > "$PASSWORD_DEFAULT_FILE"; printf '%s\n' "${PW_RETURN:-UserTyped-Pw-123456}" ;;
        Admin\ username*) printf '%s\n' "${default:-admin}" ;;
        *)                printf '%s\n' "owner@lan.test" ;;
    esac
}

# =========================================================================
# Test 1: no default is offered, the typed value persists, openssl is never used
# =========================================================================
rm -f "$PASSWORD_DEFAULT_FILE" "$OPENSSL_CALLED_FILE"
PW_RETURN="UserTyped-Pw-123456"
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
# Test 2: the review must be accepted — "Re-enter" re-collects, "Use these details" accepts
# =========================================================================
printf '0\n' > "$REVIEW_CALLS_FILE"
PW_RETURN="Match-Me-Pw-1234"
# First review picks "Re-enter" (re-collects); second picks "Use these details".
ui_choose() {
    local n
    n=$(cat "$REVIEW_CALLS_FILE")
    n=$((n + 1))
    printf '%s\n' "$n" > "$REVIEW_CALLS_FILE"
    if [[ "$n" -eq 1 ]]; then
        printf '%s\n' "Re-enter"
    else
        printf '%s\n' "Use these details"
    fi
}

_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
_stage1_collect_admin

assert_eq "Match-Me-Pw-1234" "$_WIZ_ADMIN_PW" "Stage 1 admin password: only an accepted review persists"
assert_eq "2" "$(cat "$REVIEW_CALLS_FILE" 2>/dev/null)" "Stage 1 admin password: Re-enter re-collects then accepts (2 review reads)"

# Restore accept-on-first for the demo test.
ui_choose() { printf '%s\n' "Use these details"; }

# =========================================================================
# Test 3: UI_DEMO/DEMO walk-through uses a valid placeholder without prompting
# =========================================================================
_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
UI_DEMO=1 _stage1_collect_admin

assert_eq "DemoAdminPassword123" "$_WIZ_ADMIN_PW" "Stage 1 admin password: UI_DEMO uses a valid placeholder"

scenario_end "$CURRENT_SCENARIO"
summary

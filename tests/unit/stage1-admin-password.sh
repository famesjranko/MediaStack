#!/usr/bin/env bash
# tests/unit/stage1-admin-password.sh

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

GENERATED_PASSWORD="GeneratedAdminPassword123"
PASSWORD_DEFAULT_FILE="$TMP_DIR/password-default"

ui_section() { :; }
ui_log() { :; }
log_error() { :; }

openssl() {
    if [[ "${1:-}" == "rand" && "${2:-}" == "-base64" ]]; then
        printf '%s\n' "$GENERATED_PASSWORD"
        return 0
    fi
    command openssl "$@"
}

# Admin username + email still use ui_input_validated; just echo their defaults.
ui_input_validated() {
    printf '%s\n' "${2:-}"
}

# The admin PASSWORD is now collected via the masked ui_password_validated wrapper
# (issue #6) rather than ui_input_validated — capture its offered default here.
ui_password_validated() {
    local prompt="$1"
    local default="$2"

    if [[ "$prompt" == "Admin password" ]]; then
        printf '%s\n' "$default" > "$PASSWORD_DEFAULT_FILE"
    fi

    printf '%s\n' "$default"
}

rm -f "$PASSWORD_DEFAULT_FILE"
_WIZ_PREV_USER="admin"
_WIZ_PREV_EMAIL="owner@home.test"
_WIZ_PREV_PW="oldpass1234"
_stage1_collect_admin
assert_eq "$GENERATED_PASSWORD" "$(cat "$PASSWORD_DEFAULT_FILE" 2>/dev/null)" "Stage 1 admin password: invalid 11-char prior password is not offered as default"

rm -f "$PASSWORD_DEFAULT_FILE"
_WIZ_ADMIN_USER=""
_WIZ_ADMIN_EMAIL=""
_WIZ_ADMIN_PW=""
_WIZ_PREV_PW="validpass123"
_stage1_collect_admin
assert_eq "validpass123" "$(cat "$PASSWORD_DEFAULT_FILE" 2>/dev/null)" "Stage 1 admin password: valid 12-char prior password remains the default"

scenario_end "$CURRENT_SCENARIO"
summary

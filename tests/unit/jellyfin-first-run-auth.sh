#!/usr/bin/env bash
# tests/unit/jellyfin-first-run-auth.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="jellyfin-first-run-auth"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/services/jellyfin/main.sh"

BOLD='' NC=''
JELLYFIN_ADMIN_USER="admin"
JELLYFIN_ADMIN_PASSWORD="fixture-password"
AUTH_MODE="reject"
API_KEY_SAVES=0
FOLLOW_UP_CONFIGURATION=0
ERROR_MESSAGES=()
OK_MESSAGES=()
CALLS_FILE="$TMP_DIR/startup-calls"

log_ok() { OK_MESSAGES+=("$1"); }
log_info() { :; }
log_warn() { :; }
log_error() { ERROR_MESSAGES+=("$1"); }
log_skip() { :; }
service_local_url() { printf 'http://jellyfin.fixture'; }
sleep() { :; }
storage_is_manual() { return 0; }
save_jellyfin_api_key() { API_KEY_SAVES=$((API_KEY_SAVES + 1)); }
configure_jellyfin_server_name() { FOLLOW_UP_CONFIGURATION=$((FOLLOW_UP_CONFIGURATION + 1)); }
configure_jellyfin_libraries() { FOLLOW_UP_CONFIGURATION=$((FOLLOW_UP_CONFIGURATION + 1)); }
configure_jellyfin_encoding() { FOLLOW_UP_CONFIGURATION=$((FOLLOW_UP_CONFIGURATION + 1)); }
configure_jellyfin_streaming() { FOLLOW_UP_CONFIGURATION=$((FOLLOW_UP_CONFIGURATION + 1)); }
configure_jellyfin_networking() { FOLLOW_UP_CONFIGURATION=$((FOLLOW_UP_CONFIGURATION + 1)); }

curl() {
    local arg endpoint='' method=GET method_next=0
    for arg in "$@"; do
        if [[ "$method_next" == 1 ]]; then
            method="$arg"
            method_next=0
            continue
        fi
        if [[ "$arg" == '-X' ]]; then
            method_next=1
            continue
        fi
        [[ "$arg" == *'/Startup/'* ]] && endpoint="$arg"
    done
    if [[ "$endpoint" == *'/Startup/Configuration' && "$method" == GET ]]; then
        printf '{}'
        return 0
    fi
    [[ -z "$endpoint" ]] || printf '%s %s\n' "$method" "$endpoint" >>"$CALLS_FILE"
    printf '\n204'
}

curl_header_data_stdin() {
    local arg endpoint=''
    for arg in "$@"; do
        [[ "$arg" == *'/Startup/'* || "$arg" == *'/Users/AuthenticateByName' ]] && endpoint="$arg"
    done
    if [[ "$endpoint" == *'/Users/AuthenticateByName' ]]; then
        [[ "$AUTH_MODE" == accept ]] && printf '{"AccessToken":"fixture-token"}' || return 22
        return 0
    fi
    printf '%s\n' "$endpoint" >>"$CALLS_FILE"
    printf '\n204'
}

reset_fixture() {
    : >"$CALLS_FILE"
    API_KEY_SAVES=0
    FOLLOW_UP_CONFIGURATION=0
    ERROR_MESSAGES=()
    OK_MESSAGES=()
}

# Given a fresh Jellyfin wizard whose configuration requests all succeed.
reset_fixture
AUTH_MODE=reject

# When the admin authentication request is rejected after wizard completion.
configure_jellyfin
rc=$?

# Then the failure blocks saved credentials and all follow-up configuration.
assert_eq "1" "$rc" "first-run rejected authentication returns failure"
assert_file_contains "$CALLS_FILE" "POST http://jellyfin.fixture/Startup/Configuration" \
    "first-run posts startup configuration"
assert_file_contains "$CALLS_FILE" "POST http://jellyfin.fixture/Startup/User" \
    "first-run posts admin user"
assert_file_contains "$CALLS_FILE" "POST http://jellyfin.fixture/Startup/RemoteAccess" \
    "first-run posts remote access"
assert_file_contains "$CALLS_FILE" "POST http://jellyfin.fixture/Startup/Complete" \
    "first-run posts completion"
assert_eq "0" "$API_KEY_SAVES" "first-run rejected authentication saves no API key"
assert_eq "0" "$FOLLOW_UP_CONFIGURATION" "first-run rejected authentication reports no Jellyfin success work"
assert_not_contains "${OK_MESSAGES[*]}" "Admin user created" \
    "first-run rejected authentication does not report an admin created"
assert_not_contains "${OK_MESSAGES[*]}" "Setup wizard completed" \
    "first-run rejected authentication does not report wizard completion"
assert_contains "${ERROR_MESSAGES[*]}" "Jellyfin admin login could not be verified." \
    "first-run rejected authentication gives the approved diagnosis"
assert_contains "${ERROR_MESSAGES[*]}" "./scripts/configure.sh --only jellyfin" \
    "first-run rejected authentication gives the targeted retry"
assert_contains "${ERROR_MESSAGES[*]}" "test ! -e ./config/jellyfin.before-reset" \
    "first-run rejected authentication guards against an existing reset backup"
assert_contains "${ERROR_MESSAGES[*]}" "test ! -L ./config/jellyfin.before-reset" \
    "first-run rejected authentication guards against a linked reset backup"
assert_contains "${ERROR_MESSAGES[*]}" "docker compose stop jellyfin" \
    "first-run rejected authentication stops only Jellyfin before reset"
assert_contains "${ERROR_MESSAGES[*]}" "sudo mv -- ./config/jellyfin ./config/jellyfin.before-reset" \
    "first-run rejected authentication preserves Jellyfin state before reset"
assert_contains "${ERROR_MESSAGES[*]}" "docker compose up -d --no-deps --force-recreate jellyfin" \
    "first-run rejected authentication restarts only Jellyfin after reset"
assert_contains "${ERROR_MESSAGES[*]}" "This loses active users, settings and library state, including watch history." \
    "first-run rejected authentication explains reset data loss"
assert_not_contains "${ERROR_MESSAGES[*]}" "startup wizard is not working as expected" \
    "first-run rejected authentication does not claim an upstream defect"

# Given the same successful wizard responses with a valid authentication token.
reset_fixture
AUTH_MODE=accept

# When the first-run authenticator accepts the submitted admin credentials.
configure_jellyfin
rc=$?

# Then Jellyfin saves its key and continues configuration.
assert_eq "0" "$rc" "first-run accepted authentication succeeds"
assert_eq "1" "$API_KEY_SAVES" "first-run accepted authentication saves an API key"
assert_eq "4" "$FOLLOW_UP_CONFIGURATION" "first-run accepted authentication continues Jellyfin configuration"
assert_eq "0" "${#ERROR_MESSAGES[@]}" "first-run accepted authentication emits no recovery guidance"
assert_contains "${OK_MESSAGES[*]}" "Admin user created: admin" \
    "first-run accepted authentication reports the created admin"
assert_contains "${OK_MESSAGES[*]}" "Setup wizard completed" \
    "first-run accepted authentication reports wizard completion"

scenario_end "$CURRENT_SCENARIO"
summary

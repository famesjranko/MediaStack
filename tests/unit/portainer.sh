#!/usr/bin/env bash
# Focused unit coverage for Portainer configuration drift handling.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="portainer"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CURL_LOG="$TMP_DIR/curl.log"

source "$REPO_ROOT/scripts/lib/json.sh"
# http.sh provides json_body / json_obj (used to build request bodies); the
# real curl / wait_for_service are stubbed below. Matches runtime, where
# configure.sh sources http.sh before the service configurators.
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/services/portainer/main.sh"

BOLD=""
NC=""
JELLYFIN_ADMIN_PASSWORD="shared-portainer-password"
JELLYFIN_ADMIN_USER="mediaadmin"

OK_MESSAGES=()
WARN_MESSAGES=()
SKIP_MESSAGES=()
SAVED_KEYS=()

log_ok() { OK_MESSAGES+=("$1"); }
log_warn() { WARN_MESSAGES+=("$1"); }
log_skip() { SKIP_MESSAGES+=("$1"); }
log_info() { :; }
wait_for_service() { return 0; }
docker() { return 0; }
save_api_key() { SAVED_KEYS+=("$1=$2"); }

reset_fixture() {
    : > "$CURL_LOG"
    OK_MESSAGES=()
    WARN_MESSAGES=()
    SKIP_MESSAGES=()
    SAVED_KEYS=()
    CHECK_HTTP="204"
    AUTH_BODY='{"jwt":"test-jwt"}'
    ENDPOINTS_BODY='[]'
    TOKEN_BODY='{"rawAPIKey":"portainer-api-key"}'
    EP_HTTP="201"
    unset PORTAINER_API_KEY
}

curl() {
    local arg all_args is_check=false is_auth=false is_token=false is_endpoints=false is_endpoint_create=false is_user_update=false
    all_args="$*"
    printf '%s\n' "$*" >> "$CURL_LOG"
    for arg in "$@"; do
        [[ "$arg" == *"/api/users/admin/check"* ]] && is_check=true
        [[ "$arg" == *"/api/auth"* ]] && is_auth=true
        [[ "$arg" == *"/api/users/1/tokens"* ]] && is_token=true
        [[ "$arg" == *"/api/users/1"* ]] && is_user_update=true
        [[ "$arg" == *"/api/endpoints"* ]] && is_endpoints=true
        [[ "$arg" == "Name=local&EndpointCreationType=1" ]] && is_endpoint_create=true
    done

    if $is_check; then
        printf '%s' "$CHECK_HTTP"
    elif $is_auth; then
        if [[ "$all_args" == *'"Username": "admin"'* ]]; then
            printf '%s' "${LEGACY_AUTH_BODY:-$AUTH_BODY}"
        else
            printf '%s' "$AUTH_BODY"
        fi
    elif $is_token; then
        printf '%s' "$TOKEN_BODY"
    elif $is_user_update; then
        printf '%s\n200' "${USER_UPDATE_BODY:-'{\"Id\":1,\"Username\":\"mediaadmin\",\"Role\":1}'}"
    elif $is_endpoint_create; then
        printf '%s' "$EP_HTTP"
    elif $is_endpoints; then
        printf '%s' "$ENDPOINTS_BODY"
    fi
    return 0
}

reset_fixture
AUTH_BODY='{}'
configure_portainer
rc=$?
assert_eq "0" "$rc" "Portainer empty JWT remains non-fatal"
warn_log=$(printf '%s\n' "${WARN_MESSAGES[@]}")
assert_contains "$warn_log" "Portainer authentication did not return a JWT" \
    "Portainer empty JWT logs warning"
assert_contains "$warn_log" "endpoint/API-token setup skipped" \
    "Portainer empty JWT warning names skipped setup"
assert_eq "0" "${#SAVED_KEYS[@]}" "Portainer empty JWT does not save API key"
endpoint_calls=$(grep -c "Name=local&EndpointCreationType=1" "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$endpoint_calls" "Portainer empty JWT does not create endpoint"

reset_fixture
configure_portainer
rc=$?
assert_eq "0" "$rc" "Portainer valid JWT path remains non-fatal"
assert_eq "" "${WARN_MESSAGES[*]:-}" "Portainer valid JWT path does not warn"
assert_eq "PORTAINER_API_KEY=portainer-api-key" "${SAVED_KEYS[0]:-}" \
    "Portainer valid JWT saves Homepage API key"
endpoint_calls=$(grep -c "Name=local&EndpointCreationType=1" "$CURL_LOG" 2>/dev/null || true)
assert_eq "1" "$endpoint_calls" "Portainer valid JWT creates local endpoint when none exist"
assert_contains "${OK_MESSAGES[*]:-}" "Portainer local Docker endpoint created" \
    "Portainer valid JWT logs endpoint creation"

reset_fixture
AUTH_BODY='{}'
LEGACY_AUTH_BODY='{"jwt":"legacy-jwt"}'
configure_portainer
rc=$?
assert_eq "0" "$rc" "Portainer legacy admin rename path remains non-fatal"
assert_contains "$(cat "$CURL_LOG")" "/api/users/1" \
    "Portainer legacy admin rename calls user update API"
assert_contains "$(cat "$CURL_LOG")" '"Username": "mediaadmin"' \
    "Portainer legacy admin rename uses wizard username"
assert_contains "${OK_MESSAGES[*]:-}" "Portainer admin username updated to mediaadmin" \
    "Portainer legacy admin rename logs update"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/bazarr.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="bazarr"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$TMP_DIR"
BOLD=""
NC=""

source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/services/bazarr/main.sh"

OK_MESSAGES=()
WARN_MESSAGES=()
SKIP_MESSAGES=()
DOCKER_COMMANDS=()
WAIT_MESSAGES=()
BAZARR_UNCONFIGURED_SETTINGS='{"sonarr":{"apikey":""},"radarr":{"apikey":""},"general":{"use_sonarr":false}}'
BAZARR_CONFIGURED_SETTINGS='{"sonarr":{"apikey":"sonarr-api-key"},"radarr":{"apikey":"radarr-api-key"},"general":{"use_sonarr":true}}'

log_ok() { OK_MESSAGES+=("$1"); }
log_warn() { WARN_MESSAGES+=("$1"); }
log_skip() { SKIP_MESSAGES+=("$1"); }
log_info() { :; }

env_save_api_key() { return 0; }
service_local_url() {
    [[ "$1" == "bazarr" ]] || return 1
    printf 'http://localhost:6767'
}

api_get_key() {
    case "$1" in
        *sonarr*) printf '%s\n' "sonarr-api-key" ;;
        *radarr*) printf '%s\n' "radarr-api-key" ;;
        *) printf '%s\n' "" ;;
    esac
}

api_fetch_auth() {
    local label="$1" header="$2" key="$3" url="$4"
    printf '%s|%s|%s|%s\n' "$label" "$header" "$key" "$url" \
        >>"$SCRIPT_DIR/api-fetch-auth-calls"

    [[ "$label" == "Bazarr settings" &&
        "$header" == "X-API-KEY" &&
        "$key" == "bazarr-api-key" &&
        "$url" == "http://localhost:6767/api/system/settings" ]] || return 1
    printf '%s\n' "$BAZARR_SETTINGS_RESPONSE"
}

docker() {
    DOCKER_COMMANDS+=("$*")
    return 0
}

wait_for_service() {
    WAIT_MESSAGES+=("$1 $2")
    return 0
}

cfg_bazarr_languages() {
    printf '%s\n' "english"
}

python3() {
    if [[ "${BAZARR_FAIL_CONFIG_WRITE:-}" == "1" &&
        "${1:-}" == "-c" &&
        "${2:-}" == *"with open(config_path, 'w')"* ]]; then
        return 1
    fi
    command python3 "$@"
}

reset_fixture() {
    rm -rf "$SCRIPT_DIR/config"
    mkdir -p \
        "$SCRIPT_DIR/config/bazarr/config" \
        "$SCRIPT_DIR/config/bazarr/db" \
        "$SCRIPT_DIR/config/sonarr" \
        "$SCRIPT_DIR/config/radarr"
    printf '%s\n' \
        "auth:" \
        "  apikey: bazarr-api-key" \
        "sonarr: {}" \
        "radarr: {}" \
        "general:" \
        "  use_sonarr: false" \
        >"$SCRIPT_DIR/config/bazarr/config/config.yaml"
    printf '%s\n' "<Config><ApiKey>sonarr-api-key</ApiKey></Config>" \
        >"$SCRIPT_DIR/config/sonarr/config.xml"
    printf '%s\n' "<Config><ApiKey>radarr-api-key</ApiKey></Config>" \
        >"$SCRIPT_DIR/config/radarr/config.xml"
    OK_MESSAGES=()
    WARN_MESSAGES=()
    SKIP_MESSAGES=()
    DOCKER_COMMANDS=()
    WAIT_MESSAGES=()
    : >"$SCRIPT_DIR/api-fetch-auth-calls"
    BAZARR_SETTINGS_RESPONSE="$BAZARR_UNCONFIGURED_SETTINGS"
    unset BAZARR_FAIL_CONFIG_WRITE
}

# Given unconfigured settings returned through Bazarr's authenticated settings API.
reset_fixture

# When Bazarr configuration writes Sonarr, Radarr, and general settings.
configure_bazarr
rc=$?

# Then it uses the API contract, writes the settings, and restarts Bazarr.
assert_eq "0" "$rc" "Bazarr config write success remains non-fatal"
assert_eq "Bazarr settings|X-API-KEY|bazarr-api-key|http://localhost:6767/api/system/settings" \
    "$(head -n 1 "$SCRIPT_DIR/api-fetch-auth-calls")" \
    "Bazarr reads settings through the authenticated API contract"
ok_log=$(printf '%s\n' "${OK_MESSAGES[@]}")
assert_contains "$ok_log" "Sonarr connected to Bazarr" "Bazarr logs Sonarr connection after successful write"
assert_contains "$ok_log" "Radarr connected to Bazarr" "Bazarr logs Radarr connection after successful write"
assert_contains "$ok_log" "General settings applied" "Bazarr logs general settings after successful write"
assert_eq "compose restart bazarr" "${DOCKER_COMMANDS[0]:-}" "Bazarr restarts after successful config write"
assert_contains "${WAIT_MESSAGES[*]:-}" "Bazarr http://localhost:6767" "Bazarr waits after restart"

config_summary=$(
    python3 - "$SCRIPT_DIR/config/bazarr/config/config.yaml" <<'PY'
import sys, yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
print(data["sonarr"]["apikey"])
print(data["radarr"]["apikey"])
print(data["general"]["use_sonarr"])
PY
)
mapfile -t config_lines <<<"$config_summary"
assert_eq "sonarr-api-key" "${config_lines[0]:-}" "Bazarr writes Sonarr API key to config"
assert_eq "radarr-api-key" "${config_lines[1]:-}" "Bazarr writes Radarr API key to config"
assert_eq "True" "${config_lines[2]:-}" "Bazarr writes general use_sonarr setting"

# Given unconfigured settings returned through Bazarr's authenticated settings API.
reset_fixture
BAZARR_FAIL_CONFIG_WRITE=1

# When Bazarr cannot write its configuration file.
configure_bazarr
rc=$?

# Then it warns without reporting changes or restarting Bazarr.
assert_eq "0" "$rc" "Bazarr config write failure remains non-fatal"
assert_eq "Bazarr settings|X-API-KEY|bazarr-api-key|http://localhost:6767/api/system/settings" \
    "$(head -n 1 "$SCRIPT_DIR/api-fetch-auth-calls")" \
    "Bazarr failed write still reads through the authenticated API contract"
warn_log=$(printf '%s\n' "${WARN_MESSAGES[@]}")
assert_contains "$warn_log" "Failed to write Bazarr config - skipping connection/general settings" \
    "Bazarr warns when config write fails"
failed_ok_count=$(printf '%s\n' "${OK_MESSAGES[@]}" | grep -Ec 'Sonarr connected|Radarr connected|General settings applied' 2>/dev/null || true)
assert_eq "0" "$failed_ok_count" "Bazarr write failure does not log connection/general success"
assert_eq "0" "${#DOCKER_COMMANDS[@]}" "Bazarr write failure does not restart container"
assert_eq "0" "${#WAIT_MESSAGES[@]}" "Bazarr write failure does not wait for restart"

# Given settings that already match the Sonarr, Radarr, and general configuration.
reset_fixture
BAZARR_SETTINGS_RESPONSE="$BAZARR_CONFIGURED_SETTINGS"
config_before=$(sha256sum "$SCRIPT_DIR/config/bazarr/config/config.yaml")

# When Bazarr configuration runs again.
configure_bazarr
rc=$?
config_after=$(sha256sum "$SCRIPT_DIR/config/bazarr/config/config.yaml")

# Then it skips the configured settings without rewriting or restarting Bazarr.
assert_eq "0" "$rc" "Bazarr already-configured settings remain non-fatal"
skip_log=$(printf '%s\n' "${SKIP_MESSAGES[@]}")
assert_contains "$skip_log" "Sonarr already connected to Bazarr" "Bazarr skips configured Sonarr settings"
assert_contains "$skip_log" "Radarr already connected to Bazarr" "Bazarr skips configured Radarr settings"
assert_contains "$skip_log" "General settings already applied" "Bazarr skips configured general settings"
assert_eq "$config_before" "$config_after" "Bazarr does not rewrite configured settings"
assert_eq "0" "${#DOCKER_COMMANDS[@]}" "Bazarr does not restart for configured settings"
assert_eq "0" "${#WAIT_MESSAGES[@]}" "Bazarr does not wait for configured settings"
scenario_end "$CURRENT_SCENARIO"
summary

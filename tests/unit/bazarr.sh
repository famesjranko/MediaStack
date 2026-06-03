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

log_ok() { OK_MESSAGES+=("$1"); }
log_warn() { WARN_MESSAGES+=("$1"); }
log_skip() { SKIP_MESSAGES+=("$1"); }
log_info() { :; }

save_api_key() { return 0; }

get_api_key() {
    case "$1" in
        *sonarr*) printf '%s\n' "sonarr-api-key" ;;
        *radarr*) printf '%s\n' "radarr-api-key" ;;
        *) printf '%s\n' "" ;;
    esac
}

api_fetch() {
    printf '%s\n' '{"sonarr":{"apikey":""},"radarr":{"apikey":""},"general":{"use_sonarr":false}}'
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
    if [[ "${BAZARR_FAIL_CONFIG_WRITE:-}" == "1" \
        && "${1:-}" == "-c" \
        && "${2:-}" == *"with open(config_path, 'w')"* ]]; then
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
        > "$SCRIPT_DIR/config/bazarr/config/config.yaml"
    printf '%s\n' "<Config><ApiKey>sonarr-api-key</ApiKey></Config>" \
        > "$SCRIPT_DIR/config/sonarr/config.xml"
    printf '%s\n' "<Config><ApiKey>radarr-api-key</ApiKey></Config>" \
        > "$SCRIPT_DIR/config/radarr/config.xml"
    OK_MESSAGES=()
    WARN_MESSAGES=()
    SKIP_MESSAGES=()
    DOCKER_COMMANDS=()
    WAIT_MESSAGES=()
    unset BAZARR_FAIL_CONFIG_WRITE
}

reset_fixture
configure_bazarr
rc=$?
assert_eq "0" "$rc" "Bazarr config write success remains non-fatal"
ok_log=$(printf '%s\n' "${OK_MESSAGES[@]}")
assert_contains "$ok_log" "Sonarr connected to Bazarr" "Bazarr logs Sonarr connection after successful write"
assert_contains "$ok_log" "Radarr connected to Bazarr" "Bazarr logs Radarr connection after successful write"
assert_contains "$ok_log" "General settings applied" "Bazarr logs general settings after successful write"
assert_eq "compose restart bazarr" "${DOCKER_COMMANDS[0]:-}" "Bazarr restarts after successful config write"
assert_contains "${WAIT_MESSAGES[*]:-}" "Bazarr http://localhost:6767" "Bazarr waits after restart"

config_summary=$(python3 - "$SCRIPT_DIR/config/bazarr/config/config.yaml" <<'PY'
import sys, yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
print(data["sonarr"]["apikey"])
print(data["radarr"]["apikey"])
print(data["general"]["use_sonarr"])
PY
)
mapfile -t config_lines <<< "$config_summary"
assert_eq "sonarr-api-key" "${config_lines[0]:-}" "Bazarr writes Sonarr API key to config"
assert_eq "radarr-api-key" "${config_lines[1]:-}" "Bazarr writes Radarr API key to config"
assert_eq "True" "${config_lines[2]:-}" "Bazarr writes general use_sonarr setting"

reset_fixture
BAZARR_FAIL_CONFIG_WRITE=1
configure_bazarr
rc=$?
assert_eq "0" "$rc" "Bazarr config write failure remains non-fatal"
warn_log=$(printf '%s\n' "${WARN_MESSAGES[@]}")
assert_contains "$warn_log" "Failed to write Bazarr config - skipping connection/general settings" \
    "Bazarr warns when config write fails"
failed_ok_count=$(printf '%s\n' "${OK_MESSAGES[@]}" | grep -Ec 'Sonarr connected|Radarr connected|General settings applied' 2>/dev/null || true)
assert_eq "0" "$failed_ok_count" "Bazarr write failure does not log connection/general success"
assert_eq "0" "${#DOCKER_COMMANDS[@]}" "Bazarr write failure does not restart container"
assert_eq "0" "${#WAIT_MESSAGES[@]}" "Bazarr write failure does not wait for restart"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/remote-web-state.sh
#
# Contract tests for remote web state publication.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="remote-web-state"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/env_gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u

log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }

env_val_from() {
    local env_path="$1"
    local key="$2"
    python3 - "$env_path" "$key" <<'PY'
import pathlib
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not env_path.exists():
    raise SystemExit(0)
for line in env_path.read_text().splitlines():
    if line.startswith(key + "="):
        value = line.split("=", 1)[1]
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        print(value, end="")
        break
PY
}

seed_write_env_vars() {
    _ENV_TZ="Etc/UTC"
    _ENV_PUID="$(id -u)"
    _ENV_PGID="$(id -g)"
    _ENV_HOST_ADDRESS="192.168.1.10"
    GPU_TYPE="none"
    _WIZ_TZ="Etc/UTC"
    _WIZ_DATA_DIR="/data"
    _WIZ_ADMIN_USER="admin"
    _WIZ_ADMIN_PW="GeneratedPassword123"
    _WIZ_ADMIN_EMAIL="owner@gate.test"
    _WIZ_WG_HOST="example.com"
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR="192.168.1.0/24"
    _WIZ_WG_SERVER_LAN_IP="192.168.1.10"
    _WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD=""
    _WIZ_TORRENT_PORT="6881"
    _WIZ_DL_LIMIT="0"
    _WIZ_UL_LIMIT="0"
    _WIZ_BAZARR_ENABLED="false"
    _WIZ_SMB_ENABLED="false"
    unset _WIZ_DDNS_USER _WIZ_DDNS_PW _WIZ_REMOTE_WEB_STATE
}

new_sandbox() {
    local name="$1"
    SCRIPT_DIR="$TMP_ROOT/$name"
    mkdir -p "$SCRIPT_DIR/config/ddns-updater"
}

# ---------------------------------------------------------------------------
# write_env marker contract
# ---------------------------------------------------------------------------
seed_write_env_vars
new_sandbox "lan"
_WIZ_DOMAIN=""
write_env >/dev/null

assert_eq "example.com" "$(env_val_from "$SCRIPT_DIR/.env" DOMAIN)" "remote state: blank domain writes example.com sentinel"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "remote state: LAN-only write leaves marker empty"

remote_marker_lines=$(grep -v '^#' "$SCRIPT_DIR/.env" | grep -c '^REMOTE_WEB_STATE=' || true)
assert_eq "1" "$remote_marker_lines" "remote state: marker appears exactly once in generated .env"

seed_write_env_vars
new_sandbox "unchecked"
_WIZ_DOMAIN="gate.test"
write_env >/dev/null

assert_eq "gate.test" "$(env_val_from "$SCRIPT_DIR/.env" DOMAIN)" "remote state: real domain is persisted"
assert_eq "unchecked" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "remote state: real domain starts unchecked"
assert_contains "$(grep -v '^#' "$SCRIPT_DIR/.env")" "REMOTE_WEB_STATE=unchecked" "remote state: unchecked marker line is written"

if grep -v '^#' "$SCRIPT_DIR/.env" | grep -q '^REMOTE_WEB_STATE=ready$'; then
    fail "remote state: write_env never auto-promotes to ready"
else
    pass "remote state: write_env never auto-promotes to ready"
fi

seed_write_env_vars
new_sandbox "explicit-ready"
_WIZ_DOMAIN="gate.test"
_WIZ_REMOTE_WEB_STATE="ready"
write_env >/dev/null
assert_eq "ready" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "remote state: explicit ready fixture is preserved"

# ---------------------------------------------------------------------------
# print_access_info contract
# ---------------------------------------------------------------------------
write_access_env() {
    local state="$1"
    local domain="$2"
    SCRIPT_DIR="$TMP_ROOT/access-$state"
    mkdir -p "$SCRIPT_DIR"
    cat >"$SCRIPT_DIR/.env" <<EOF
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=${domain}
REMOTE_WEB_STATE=${state}
EOF
}

JELLYFIN_ADMIN_USER="admin"
NPM_ADMIN_EMAIL="owner@gate.test"
TORRENT_PORT="6881"
WG_PORT="51820"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
GPU_TYPE="none"
SMB_ENABLED="false"
BAZARR_ENABLED="false"

unset REMOTE_WEB_STATE
write_access_env "unchecked" "gate.test"
unchecked_output=$(print_access_info)
assert_contains "$unchecked_output" "Remote access: not yet configured -- choose Features & settings -> Add remote access from the menu" "remote state: unchecked access copy"
if [[ "$unchecked_output" == *"https://jellyfin.gate.test"* || "$unchecked_output" == *"https://seerr.gate.test"* ]]; then
    fail "remote state: unchecked access does not advertise HTTPS URLs"
else
    pass "remote state: unchecked access does not advertise HTTPS URLs"
fi

unset REMOTE_WEB_STATE
write_access_env "ready" "gate.test"
ready_output=$(print_access_info)
assert_contains "$ready_output" "https://jellyfin.gate.test" "remote state: ready prints Jellyfin HTTPS URL"
assert_contains "$ready_output" "https://seerr.gate.test" "remote state: ready prints Seerr HTTPS URL"

unset REMOTE_WEB_STATE
write_access_env "skipped" "gate.test"
skipped_output=$(print_access_info)
assert_contains "$skipped_output" "HTTPS skipped. LAN + VPN work. Choose Features & settings -> Add remote access from the menu to try again." "remote state: skipped access copy"
if [[ "$skipped_output" == *"https://jellyfin.gate.test"* || "$skipped_output" == *"https://seerr.gate.test"* ]]; then
    fail "remote state: skipped access does not advertise HTTPS URLs"
else
    pass "remote state: skipped access does not advertise HTTPS URLs"
fi

unset REMOTE_WEB_STATE
write_access_env "failed" "gate.test"
failed_output=$(print_access_info)
assert_contains "$failed_output" "HTTPS setup failed. LAN + VPN work. Choose Features & settings -> Add remote access from the menu after fixing the issue." "remote state: failed access copy"
if [[ "$failed_output" == *"https://jellyfin.gate.test"* || "$failed_output" == *"https://seerr.gate.test"* ]]; then
    fail "remote state: failed access does not advertise HTTPS URLs"
else
    pass "remote state: failed access does not advertise HTTPS URLs"
fi

# ---------------------------------------------------------------------------
# DEMO=1 + UI_DEMO=1 contract
# ---------------------------------------------------------------------------
seed_write_env_vars
new_sandbox "demo"
export DEMO=1 UI_DEMO=1
_WIZ_DOMAIN=""
write_env >/dev/null
assert_eq "example.com" "$(env_val_from "$SCRIPT_DIR/.env" DOMAIN)" "remote state: DEMO=1 UI_DEMO=1 writes LAN-only domain"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "remote state: DEMO=1 UI_DEMO=1 writes no ready marker"
unset DEMO UI_DEMO

scenario_end "$CURRENT_SCENARIO"
summary

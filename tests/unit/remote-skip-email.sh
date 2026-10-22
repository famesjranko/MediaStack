#!/usr/bin/env bash
# tests/unit/remote-skip-email.sh
#
# Contract: skipping remote access rewrites .env without losing the admin
# email, and Stage 2 install opens the same service-port firewall rules as the
# UFW toggle.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="remote-skip-email"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/setup/stages/stage2.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/env-gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u
log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }
ui_log() { :; }

env_email() {
    sed -n "s/^NPM_ADMIN_EMAIL='\(.*\)'\$/\1/p" "$SCRIPT_DIR/.env"
}

# Given an install whose .env holds the default admin email and the wizard did not run
# When the user skips remote access
# Then the rewritten .env still holds that admin email
SCRIPT_DIR="$TMP_ROOT/skip"
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
_ENV_TZ="Etc/UTC"
_ENV_PUID="$(id -u)"
_ENV_PGID="$(id -g)"
_ENV_HOST_ADDRESS="192.168.1.10"
unset _WIZ_ADMIN_EMAIL _WIZ_PREV_EMAIL
NPM_ADMIN_EMAIL="admin@mediastack.local"
_WIZ_ADMIN_USER="admin"
_WIZ_ADMIN_PW="GeneratedPassword123"
_WIZ_TZ="Etc/UTC"
_WIZ_DATA_DIR="/data"
_stage2_skip_https >/dev/null 2>&1
assert_eq "admin@mediastack.local" "$(env_email)" "skip remote access: NPM_ADMIN_EMAIL is preserved in .env"

# Given Stage 2 install on a host with UFW enabled (and, separately, disabled)
# When the install runs
# Then it opens the service-port rules only when UFW is enabled
STAGE2_CALLS=""
_stage2_seed_wizard_defaults() { :; }
write_env() { :; }
stage2_preserve_stage1_marker() { :; }
_stage2_source_env() { :; }
setup_ufw_wireguard_clients() { :; }
setup_ufw_service_ports() { STAGE2_CALLS+="service_ports "; }
pull_images() { :; }
start_stack() { :; }
wait_all_healthy() { :; }
service_container_running() { return 1; }
f2b_uninstall_reload_watcher() { :; }
_stage2_ddns_unverified() { return 0; }
print_access_info() { :; }
UFW_ENABLED=true _WIZ_WG_ENABLED=true _WIZ_ADMIN_PW=pw _WIZ_JELLYFIN_BITRATE="" UI_DEMO=1 \
    _stage2_install >/dev/null 2>&1 </dev/null
assert_eq "service_ports " "$STAGE2_CALLS" "stage 2 install: UFW on opens the service-port rules"
STAGE2_CALLS=""
UFW_ENABLED=false _WIZ_WG_ENABLED=true _WIZ_ADMIN_PW=pw _WIZ_JELLYFIN_BITRATE="" UI_DEMO=1 \
    _stage2_install >/dev/null 2>&1 </dev/null
assert_eq "" "$STAGE2_CALLS" "stage 2 install: UFW off opens no firewall rules"

scenario_end "$CURRENT_SCENARIO"
summary

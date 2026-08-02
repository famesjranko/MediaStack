#!/usr/bin/env bash
# tests/unit/stage1-marker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-marker"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/env_gen.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

set +e
set +u

SCRIPT_DIR="$TMP_DIR"
_ENV_TZ="Etc/UTC"
_ENV_PUID="$(id -u)"
_ENV_PGID="$(id -g)"
_ENV_HOST_ADDRESS="192.168.1.10"
GPU_TYPE="none"
_WIZ_TZ="Etc/UTC"
_WIZ_DATA_DIR="/data"
_WIZ_ADMIN_USER="admin"
_WIZ_ADMIN_PW="GeneratedPassword123"
_WIZ_ADMIN_EMAIL=""
_WIZ_DOMAIN=""
_WIZ_WG_HOST=""
_WIZ_WG_PORT="51820"
_WIZ_WG_DNS="1.1.1.1"
_WIZ_WG_ACCESS_TIER="full-lan"
_WIZ_WG_LAN_CIDR="192.168.1.0/24"
_WIZ_WG_SERVER_LAN_IP="192.168.1.10"
_WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
_WIZ_WG_PER_CLIENT_FIREWALL="true"
_WIZ_WG_INIT_PASSWORD=""
_WIZ_TORRENT_PORT="6881"
_WIZ_DL_LIMIT="7.5"
_WIZ_UL_LIMIT="1.2"
_WIZ_BAZARR_ENABLED="false"
_WIZ_SMB_ENABLED="false"

write_env

marker_line=$(grep '^STAGE_1_COMPLETE=' "$TMP_DIR/.env")
assert_eq "STAGE_1_COMPLETE=" "$marker_line" "stage1-marker: placeholder written empty"

sed -i 's/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/' "$TMP_DIR/.env"
flipped_line=$(grep '^STAGE_1_COMPLETE=' "$TMP_DIR/.env")
assert_eq "STAGE_1_COMPLETE=1" "$flipped_line" "stage1-marker: sed flip matches placeholder"

SKIP_CAPTURE=""
log_skip() { SKIP_CAPTURE+="$*"$'\n'; }
WIZARD_RAN_INSTALL=false
STAGE_1_COMPLETE=1
EXISTING_INSTALL_DETECTED=false
run_stage1
rc=$?
assert_eq "0" "$rc" "stage1-marker: run_stage1 skips when marker is set"
assert_contains "$SKIP_CAPTURE" "Stage 1 already complete" "stage1-marker: skip message"

# Skip path must mark WIZARD_RAN_INSTALL=true so setup.sh::main()'s
# late install block does not tear down the running stack on a benign
# './setup.sh' re-run.
assert_eq "true" "$WIZARD_RAN_INSTALL" "stage1-marker: skip path sets WIZARD_RAN_INSTALL=true"
assert_contains "$SKIP_CAPTURE" "rebuild from scratch" "stage1-marker: skip path documents rebuild flow"

# Interrupted Stage 1 must not skip solely because earlier preflight detected
# existing container/config evidence. The completion marker is the only Stage 1
# skip authority.
WIZARD_RAN_INSTALL=false
SKIP_CAPTURE=""
STAGE_1_COMPLETE=
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
EXISTING_INSTALL_DETECTED=true
INSTALL_CALLED=false
_wizard_run_discovery() { :; }
_stage1_show_system() { :; }
_stage1_collect_admin() { :; }
_stage1_collect_storage() { :; }
_stage1_collect_subtitles() { :; }
_stage1_collect_smb() { :; }
_stage1_collect_quality() { :; }
_stage1_collect_indexers() { :; }
_stage1_collect_image_channel() { :; }
_stage1_collect_qbit() { :; }
_stage1_collect_security() { :; }
_stage1_confirm() { _STAGE1_CONFIRM_ACTION=Install; }
_stage1_install() {
    INSTALL_CALLED=true
    WIZARD_RAN_INSTALL=true
}
run_stage1
rc=$?
assert_eq "0" "$rc" "stage1-marker: existing-install evidence with empty marker runs Stage 1"
assert_eq "true" "$INSTALL_CALLED" "stage1-marker: existing-install flag alone does not skip Stage 1"
assert_eq "" "$SKIP_CAPTURE" "stage1-marker: existing-install flag alone does not emit skip message"

# BESZEL_AGENT_KEY source-safety: configure.sh populates BESZEL_AGENT_KEY
# with an ssh-ed25519 line of the form 'ssh-ed25519 AAAAC3Nza... comment'
# (three space-separated tokens). Without single-quoting in env_gen.sh,
# `set -a; source .env` would treat the BASE64 chunk as a command and
# fail with exit 127. This test surfaced from the GCP fresh-test cascade
# at Stage 2 setup.sh --remote.
TMP_DIR_BSZL=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_BSZL"' EXIT
SCRIPT_DIR="$TMP_DIR_BSZL"
export BESZEL_AGENT_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTYEfM1mEjek4Hl7wS12cGkTzceIPb0pYtGF8zaWSX5 beszel-agent@host"
write_env

# Render must single-quote the value so the entire ssh-ed25519 line stays
# bound to BESZEL_AGENT_KEY as one token.
beszel_line=$(grep '^BESZEL_AGENT_KEY=' "$TMP_DIR_BSZL/.env")
case "$beszel_line" in
    "BESZEL_AGENT_KEY='ssh-ed25519 AAAAC3"*"beszel-agent@host'")
        pass "stage1-marker (BESZEL): multi-word ed25519 key written as single-quoted literal"
        ;;
    *)
        fail "stage1-marker (BESZEL): multi-word ed25519 key written as single-quoted literal" "got: $beszel_line"
        ;;
esac

# Production failure-mode assertion: sourcing .env under `set -a` must succeed.
(
    set -a
    source "$TMP_DIR_BSZL/.env"
    set +a
) 2>/dev/null
src_rc=$?
assert_eq "0" "$src_rc" "stage1-marker (BESZEL): set -a; source .env succeeds with multi-word key"

unset BESZEL_AGENT_KEY
SCRIPT_DIR="$TMP_DIR"

scenario_end "$CURRENT_SCENARIO"
summary

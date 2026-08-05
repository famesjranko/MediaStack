#!/usr/bin/env bash
# tests/unit/stage2-install.sh
#
# Contract tests for Stage 2 terminal-flow copy and choice labels.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-install"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

# The DDNS password is collected via the shared ui_password_validated primitive
# (which replaced _stage2_password_validated). Source the ui layer so that real
# loop is defined; the ui_password / ui_log stubs below are defined AFTER this source
# and override the real ones, so the validated re-prompt loop runs against the stub
# (no real `read`, deterministic — never a hang on the un-TTY unit path).
source "$REPO_ROOT/scripts/lib/ui.sh"

set +e
set +u

DDNS_UPDATER_UID="$(id -u)"
DDNS_UPDATER_GID="$(id -g)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }
ui_log() {
    local level="$1"
    shift
    if [[ "$level" == "warn" ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        LAST_WARN="$*"
        [[ -n "${LAST_WARN_FILE:-}" ]] && printf '%s\n' "$LAST_WARN" >"$LAST_WARN_FILE"
    fi
}

source "$REPO_ROOT/scripts/setup/env-gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/lib/validators.sh"
env_val_from() {
    local env_path="$1"
    local key="$2"
    python3 - "$env_path" "$key" <<'PY'
import pathlib
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for line in env_path.read_text().splitlines():
    if line.startswith(key + "="):
        value = line.split("=", 1)[1]
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        print(value, end="")
        break
PY
}

seed_stage2_env_vars() {
    SCRIPT_DIR="$TMP_ROOT/env"
    rm -rf "$SCRIPT_DIR"
    mkdir -p "$SCRIPT_DIR/config/ddns-updater"
    _ENV_TZ="Etc/UTC"
    _ENV_PUID="$(id -u)"
    _ENV_PGID="$(id -g)"
    _ENV_HOST_ADDRESS="192.168.1.10"
    # Fixture consumed by the sourced product code under test.
    # shellcheck disable=SC2034
    GPU_TYPE="none"
    _WIZ_TZ="Etc/UTC"
    _WIZ_DATA_DIR="/data"
    _WIZ_ADMIN_USER="admin"
    _WIZ_ADMIN_PW="GeneratedPassword123"
    _WIZ_ADMIN_EMAIL="owner@gate.test"
    _WIZ_DOMAIN="gate.test"
    _WIZ_REMOTE_WEB_STATE="unchecked"
    _WIZ_WG_HOST="gate.test"
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR="10.8.0.0/24"
    _WIZ_WG_SERVER_LAN_IP="192.168.1.10"
    _WIZ_WG_INIT_ALLOWED_IPS="10.8.0.0/24"
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD="GeneratedPassword123"
    _WIZ_DDNS_PROVIDER="dynu"
    _WIZ_DDNS_FIELDS=([password]='dynu"pw\with$chars')
    _WIZ_DDNS_PREFLIGHT_OK="false"
    _WIZ_DDNS_INVALIDATED="false"
    _WIZ_TORRENT_PORT="6881"
    _WIZ_DL_LIMIT="0"
    _WIZ_UL_LIMIT="0"
    _WIZ_BAZARR_ENABLED="false"
    _WIZ_SMB_ENABLED="false"
}

reset_stage2_ddns_prompt_stubs() {
    WARN_COUNT=0
    LAST_WARN=""
    LAST_WARN_FILE="$TMP_ROOT/ddns-last-warn"
    : >"$LAST_WARN_FILE"
    DDNS_PASSWORD_COUNT_FILE="$TMP_ROOT/ddns-password-count"
    printf '0\n' >"$DDNS_PASSWORD_COUNT_FILE"
    _WIZ_DOMAIN="gate.test"
    _WIZ_DDNS_PROVIDER="dynu"
    _WIZ_DDNS_FIELDS=()
    _WIZ_DDNS_PREFLIGHT_OK="false"
    _WIZ_DDNS_INVALIDATED="false"
}

# A static-IP / self-managed-DNS user picks "Yes" (option 2) at the
# static-vs-dynamic gate and skips DDNS entirely — no ephemeral verify, nothing
# persistable, and _WIZ_USES_DDNS records the skip so the DNS-failure menu later
# hides "Re-enter credentials". (Redefines ui_choose for this block only; the
# remaining tests stub _stage2_collect_domain, so the override does not leak.)
reset_stage2_ddns_prompt_stubs
STATIC_IP_VERIFY_CALLED=0
ui_choose() {
    case "$1" in
        Does\ your*) printf 'Yes - static IP, or I keep my own DNS updated (skip DDNS)\n' ;;
        *) printf 'Skip HTTPS for now\n' ;;
    esac
}
ddns_verify_via_container() {
    STATIC_IP_VERIFY_CALLED=1
    return 0
}
_WIZ_USES_DDNS="true"
if _stage2_offer_ddns "false" >/dev/null 2>&1; then
    fail "static-IP choice skips DDNS (offer returns non-zero)"
else
    pass "static-IP choice skips DDNS (offer returns non-zero)"
fi
assert_eq "0" "$STATIC_IP_VERIFY_CALLED" "static-IP choice does not run the ephemeral verify"
assert_eq "false" "$_WIZ_USES_DDNS" "static-IP choice records _WIZ_USES_DDNS=false (menu hides Re-enter Dynu)"
assert_eq "false" "$_WIZ_DDNS_PREFLIGHT_OK" "static-IP choice leaves DDNS creds unpersistable"

seed_stage2_env_vars
mkdir -p "$SCRIPT_DIR/scripts" "$TMP_ROOT/ddns-symlink-target"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
cat >"$SCRIPT_DIR/.env" <<'EOF'
DOMAIN=example.com
REMOTE_WEB_STATE=existing-safe
DDNS_USERNAME='old-user'
DDNS_PASSWORD='old-secret'
STAGE_1_COMPLETE=1
EOF
cp "$SCRIPT_DIR/.env" "$TMP_ROOT/stage2-symlink-existing.env"
rm -rf "$SCRIPT_DIR/config/ddns-updater"
ln -s "$TMP_ROOT/ddns-symlink-target" "$SCRIPT_DIR/config/ddns-updater"
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="good-secret")
_WIZ_DDNS_PREFLIGHT_OK="true"
_WIZ_JELLYFIN_BITRATE=""
STAGE2_SYMLINK_PULLS=0
STAGE2_SYMLINK_STARTS=0
pull_images() { STAGE2_SYMLINK_PULLS=$((STAGE2_SYMLINK_PULLS + 1)); }
start_stack() { STAGE2_SYMLINK_STARTS=$((STAGE2_SYMLINK_STARTS + 1)); }
_stage2_install >/dev/null 2>&1
stage2_symlink_rc=$?
if ((stage2_symlink_rc != 0)); then
    pass "AUDIT: Stage 2 install aborts on symlinked DDNS config directory"
else
    fail "AUDIT: Stage 2 install aborts on symlinked DDNS config directory"
fi
assert_eq "0" "$STAGE2_SYMLINK_PULLS" "AUDIT: symlinked DDNS dir aborts before pull_images"
assert_eq "0" "$STAGE2_SYMLINK_STARTS" "AUDIT: symlinked DDNS dir aborts before start_stack"
assert_eq "no" "$([[ -f "$TMP_ROOT/ddns-symlink-target/config.json" ]] && echo yes || echo no)" "AUDIT: Stage 2 does not write DDNS config through symlinked dir"
if cmp -s "$TMP_ROOT/stage2-symlink-existing.env" "$SCRIPT_DIR/.env"; then
    pass "AUDIT: symlinked DDNS dir abort preserves existing .env"
else
    fail "AUDIT: symlinked DDNS dir abort preserves existing .env"
fi

seed_stage2_env_vars
mkdir -p "$SCRIPT_DIR/scripts" "$TMP_ROOT/ddns-run-stage2-target"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
cat >"$SCRIPT_DIR/.env" <<'EOF'
DOMAIN=example.com
REMOTE_WEB_STATE=existing-safe
DDNS_USERNAME='old-user'
DDNS_PASSWORD='old-secret'
STAGE_1_COMPLETE=1
EOF
cp "$SCRIPT_DIR/.env" "$TMP_ROOT/run-stage2-symlink-existing.env"
rm -rf "$SCRIPT_DIR/config/ddns-updater"
ln -s "$TMP_ROOT/ddns-run-stage2-target" "$SCRIPT_DIR/config/ddns-updater"
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="good-secret")
_WIZ_DDNS_PREFLIGHT_OK="true"
_WIZ_JELLYFIN_BITRATE=""
STAGE2_RUN_STAGE2_PULLS=0
STAGE2_RUN_STAGE2_STARTS=0
pull_images() { STAGE2_RUN_STAGE2_PULLS=$((STAGE2_RUN_STAGE2_PULLS + 1)); }
start_stack() { STAGE2_RUN_STAGE2_STARTS=$((STAGE2_RUN_STAGE2_STARTS + 1)); }
ui_banner() { :; }
_stage2_offer() { printf 'Enable remote access\n'; }
_stage2_collect_domain() { return 0; }
_stage2_port_gate() { return 0; }
_stage2_collect_wireguard() { :; }
_stage2_collect_jellyfin_remote_bitrate() { :; }
_stage2_confirm() { _STAGE2_CONFIRM_ACTION=Install; }
run_stage2 >/dev/null 2>&1
run_stage2_symlink_rc=$?
if ((run_stage2_symlink_rc != 0)); then
    pass "AUDIT: run_stage2 install branch aborts on symlinked DDNS config directory"
else
    fail "AUDIT: run_stage2 install branch aborts on symlinked DDNS config directory"
fi
assert_eq "0" "$STAGE2_RUN_STAGE2_PULLS" "AUDIT: run_stage2 symlinked DDNS dir aborts before pull_images"
assert_eq "0" "$STAGE2_RUN_STAGE2_STARTS" "AUDIT: run_stage2 symlinked DDNS dir aborts before start_stack"
assert_eq "no" "$([[ -f "$TMP_ROOT/ddns-run-stage2-target/config.json" ]] && echo yes || echo no)" "AUDIT: run_stage2 does not write DDNS config through symlinked dir"
if cmp -s "$TMP_ROOT/run-stage2-symlink-existing.env" "$SCRIPT_DIR/.env"; then
    pass "AUDIT: run_stage2 symlinked DDNS dir abort preserves existing .env"
else
    fail "AUDIT: run_stage2 symlinked DDNS dir abort preserves existing .env"
fi
unset DDNS_USERNAME DDNS_PASSWORD

scenario_end "$CURRENT_SCENARIO"
summary

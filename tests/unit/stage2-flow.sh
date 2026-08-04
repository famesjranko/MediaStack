#!/usr/bin/env bash
# tests/unit/stage2-flow.sh
#
# Contract tests for Stage 2 terminal-flow copy and choice labels.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-flow"
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

if ! type stage2_offer_choices >/dev/null 2>&1; then
    stage2_offer_choices() { printf '__not_implemented__'; }
fi
if ! type stage2_dns_retry_choices >/dev/null 2>&1; then
    stage2_dns_retry_choices() { printf '__not_implemented__'; }
fi
if ! type stage2_port_gate_choices >/dev/null 2>&1; then
    stage2_port_gate_choices() { printf '__not_implemented__'; }
fi
if ! type stage2_confirm_choices >/dev/null 2>&1; then
    stage2_confirm_choices() { printf '__not_implemented__'; }
fi
if ! type stage2_le_failure_choices >/dev/null 2>&1; then
    stage2_le_failure_choices() { printf '__not_implemented__'; }
fi
if ! type stage2_skip_summary_copy >/dev/null 2>&1; then
    stage2_skip_summary_copy() { printf '__not_implemented__'; }
fi
if ! type stage2_tell_me_more_copy >/dev/null 2>&1; then
    stage2_tell_me_more_copy() { printf '__not_implemented__'; }
fi

# Offer choices and tell-more copy.
offer_choices="$(stage2_offer_choices)"
assert_contains "$offer_choices" "Enable remote access" "offer includes Enable remote access"
assert_contains "$offer_choices" "Skip for now" "offer includes Skip for now"
assert_contains "$offer_choices" "Tell me more" "offer includes Tell me more"

tell_more="$(stage2_tell_me_more_copy)"
assert_contains "$tell_more" "domain" "tell-me-more explains domain requirement"
assert_contains "$tell_more" "WireGuard" "tell-me-more explains WireGuard"

# Retry/continue/skip choices for gate failures.
dns_choices="$(stage2_dns_retry_choices)"
assert_contains "$dns_choices" "Retry DNS check" "DNS retry choices include Retry DNS check"
assert_contains "$dns_choices" "Skip HTTPS for now" "DNS retry choices include Skip HTTPS for now"

port_choices="$(stage2_port_gate_choices)"
assert_contains "$port_choices" "Retry" "port gate includes Retry"
assert_contains "$port_choices" "Continue with manual verification" "port gate includes manual verification fallback"
assert_contains "$port_choices" "Skip HTTPS for now" "port gate includes Skip HTTPS for now"

le_choices="$(stage2_le_failure_choices)"
assert_contains "$le_choices" "Skip HTTPS for now" "LE gate includes Skip HTTPS for now"
assert_contains "$le_choices" "Exit so I can fix and retry" "LE gate includes fix-and-retry exit"
assert_contains "$le_choices" "Abort setup" "LE gate includes Abort setup"

# Confirm choices.
confirm_choices="$(stage2_confirm_choices)"
assert_contains "$confirm_choices" "Install" "confirm includes Install"
assert_contains "$confirm_choices" "Back" "confirm includes Back"
assert_contains "$confirm_choices" "Skip remote access" "confirm includes Skip remote access"

# Skip copy is the user-facing fallback when ready postconditions fail.
skip_copy="$(stage2_skip_summary_copy)"
assert_contains "$skip_copy" "HTTPS skipped. LAN + VPN work. Choose Features & settings -> Add remote access from the menu to try again." "skip summary matches the expected copy verbatim"

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

source "$REPO_ROOT/scripts/setup/env_gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/lib/validators.sh"

_WIZ_ADMIN_EMAIL=""
_WIZ_PREV_EMAIL=""
NPM_ADMIN_EMAIL="admin@mediastack.local"
_stage2_seed_wizard_defaults
assert_eq "" "$_WIZ_ADMIN_EMAIL" "remote setup blanks LAN-only demo email"

_WIZ_ADMIN_EMAIL=""
_WIZ_PREV_EMAIL=""
NPM_ADMIN_EMAIL="owner@gate.test"
_stage2_seed_wizard_defaults
assert_eq "owner@gate.test" "$_WIZ_ADMIN_EMAIL" "remote setup preserves real email"

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

# v15 wg-easy takes plaintext INIT_PASSWORD; no bcrypt step. The wizard sets
# _WIZ_WG_INIT_PASSWORD from _WIZ_ADMIN_PW inside _stage2_collect_wireguard and
# env_gen.sh persists it. The Stage 2 skip path should leave it empty so the
# remote profile stays inactive.
seed_stage2_env_vars
seed_jf_pw="$_WIZ_ADMIN_PW"
_WIZ_WG_INIT_PASSWORD="$seed_jf_pw"
write_env >/dev/null
assert_eq "$seed_jf_pw" "$(env_val_from "$SCRIPT_DIR/.env" WG_INIT_PASSWORD)" "AUDIT: Stage 2 install path persists WireGuard init password from admin password"

seed_stage2_env_vars
_WIZ_WG_INIT_PASSWORD=""
unset WG_INIT_PASSWORD
STAGE_1_COMPLETE=1
_stage2_skip_https >/dev/null
assert_eq "skipped" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "AUDIT: Stage 2 immediate skip persists skipped state"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" WG_INIT_PASSWORD)" "AUDIT: Stage 2 immediate skip leaves WireGuard init password empty"
_build_profile_args skip_profiles
# Populated by _build_profile_args via its `local -n` nameref output param.
# shellcheck disable=SC2154
case " ${skip_profiles[*]} " in
    *" --profile remote "*) fail "AUDIT: Stage 2 immediate skip leaves remote profile inactive" "profiles=${skip_profiles[*]}" ;;
    *) pass "AUDIT: Stage 2 immediate skip leaves remote profile inactive" ;;
esac
unset DDNS_USERNAME DDNS_PASSWORD

seed_stage2_env_vars
# Persist-decouple: config.json is written on SHAPE-VALID render even
# though the provider was never live-verified (PREFLIGHT_OK stays false from the
# seed). Gating persistence on PREFLIGHT_OK would brick the 5 non-Dynu providers.
write_env >/dev/null
assert_eq "dynu" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "DDNS provider persists to .env (non-secret)"
assert_eq "gate.test" "$(env_val_from "$SCRIPT_DIR/.env" DOMAIN)" "Stage 2 domain persists to .env"
assert_eq "unchecked" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "Stage 2 starts unchecked before install verification"
assert_eq '10.8.0.0/24' "$(env_val_from "$SCRIPT_DIR/.env" WG_INIT_ALLOWED_IPS)" "WireGuard init allowed IPs persist"
assert_eq 'true' "$(env_val_from "$SCRIPT_DIR/.env" WG_PER_CLIENT_FIREWALL)" "WireGuard per-client firewall flag persists"
assert_eq 'full-lan' "$(env_val_from "$SCRIPT_DIR/.env" WG_ACCESS_TIER)" "WG_ACCESS_TIER persists"
assert_eq '10.8.0.0/24' "$(env_val_from "$SCRIPT_DIR/.env" WG_LAN_CIDR)" "WG_LAN_CIDR persists"
assert_eq '192.168.1.10' "$(env_val_from "$SCRIPT_DIR/.env" WG_SERVER_LAN_IP)" "WG_SERVER_LAN_IP persists"
assert_eq 'dynu"pw\with$chars' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["password"])' "$SCRIPT_DIR/config/ddns-updater/config.json")" "DDNS password persists via JSON-safe writer"
assert_eq "${DDNS_UPDATER_UID}:${DDNS_UPDATER_GID} 600" "$(stat -c '%u:%g %a' "$SCRIPT_DIR/config/ddns-updater/config.json")" "AUDIT: DDNS config writer secures file for configured container user"

if grep -q '^PASSWORD=' "$SCRIPT_DIR/.env"; then
    fail "WireGuard plaintext PASSWORD is not written"
else
    pass "WireGuard plaintext PASSWORD is not written"
fi
assert_contains "$(grep '^WG_INIT_PASSWORD=' "$SCRIPT_DIR/.env")" "WG_INIT_PASSWORD='" "WireGuard init password is single-quoted"

DDNS_PERM_CALLS="$TMP_ROOT/ddns-permission-calls"
DDNS_PERM_DIR="$TMP_ROOT/ddns-permission-dir"
mkdir -p "$DDNS_PERM_DIR"
: >"$DDNS_PERM_DIR/config.json"
unset DDNS_UPDATER_UID DDNS_UPDATER_GID
stat() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "%u:%g" ]]; then
        printf '1001:1001\n'
        return 0
    fi
    command stat "$@"
}
chown() {
    printf 'direct chown %s\n' "$*" >>"$DDNS_PERM_CALLS"
    return 1
}
chmod() {
    printf 'direct chmod %s\n' "$*" >>"$DDNS_PERM_CALLS"
    return 1
}
sudo() {
    printf 'sudo %s\n' "$*" >>"$DDNS_PERM_CALLS"
    return 0
}
_ddns_prepare_config_dir "$DDNS_PERM_DIR" >/dev/null 2>&1
_ddns_secure_config_file "$DDNS_PERM_DIR/config.json" >/dev/null 2>&1
DDNS_PERM_LOG="$(cat "$DDNS_PERM_CALLS")"
assert_contains "$DDNS_PERM_LOG" "sudo chown 1000:1000 $DDNS_PERM_DIR" "AUDIT: DDNS config dir repairs non-1000 owner"
assert_contains "$DDNS_PERM_LOG" "sudo chmod 755 $DDNS_PERM_DIR" "AUDIT: DDNS config dir mode remains traversable"
assert_contains "$DDNS_PERM_LOG" "sudo chown 1000:1000 $DDNS_PERM_DIR/config.json" "AUDIT: DDNS config file repairs non-1000 owner"
assert_contains "$DDNS_PERM_LOG" "sudo chmod 600 $DDNS_PERM_DIR/config.json" "AUDIT: DDNS config file stays private but container-readable"
unset -f stat chown chmod sudo
DDNS_UPDATER_UID="$(id -u)"
DDNS_UPDATER_GID="$(id -g)"

# A re-run that SKIPS the DDNS step must leave an existing chmod-600
# config.json byte-untouched (credentials live there now, not in .env). Seed one,
# blank the wizard's collected fields, skip, and assert the file is preserved.
seed_stage2_env_vars
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DDNS_PREFLIGHT_OK="false"
_WIZ_DDNS_INVALIDATED="false"
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
printf '%s\n' '{"settings":[{"provider":"duckdns","domain":"gate.test","token":"keep-me","ip_version":"ipv4"}]}' \
    >"$SCRIPT_DIR/config/ddns-updater/config.json"
cp "$SCRIPT_DIR/config/ddns-updater/config.json" "$TMP_ROOT/ddns-skip-preserve.json"
STAGE_1_COMPLETE=1
_stage2_skip_https >/dev/null
if cmp -s "$TMP_ROOT/ddns-skip-preserve.json" "$SCRIPT_DIR/config/ddns-updater/config.json"; then
    pass "Stage 2 skip leaves an existing DDNS config.json byte-untouched"
else
    fail "Stage 2 skip leaves an existing DDNS config.json byte-untouched"
fi

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

ddns_verify_via_container() {
    return 0
}

# Drive the REAL ui_input_validated loop (ui.sh sourced) through a stubbed
# ui_input primitive so the new VISIBLE field collection is exercised end-to-end:
# Dynu collects password ONLY, so the loop drives a single-quote reject
# then a good value, proving the field loop re-prompts on validator failure.
reset_stage2_ddns_prompt_stubs
DDNS_PW_INPUT_COUNT_FILE="$TMP_ROOT/ddns-pw-input-count"
printf '0\n' >"$DDNS_PW_INPUT_COUNT_FILE"
ui_input() {
    local n
    n=$(cat "$DDNS_PW_INPUT_COUNT_FILE" 2>/dev/null || printf '0')
    n=$((n + 1))
    printf '%s\n' "$n" >"$DDNS_PW_INPUT_COUNT_FILE"
    case "$n" in
        1) printf "bad'quote\n" ;;
        *) printf 'good-secret\n' ;;
    esac
}
_stage2_offer_ddns "true" >/dev/null
assert_eq "good-secret" "${_WIZ_DDNS_FIELDS[password]}" "field loop rejects single quote, keeps good password"
assert_eq "mediastack" "$(bash -c 'source scripts/lib/ddns_providers.sh; declare -A f=([domain]=d.test [password]=x); ddns_render_config_json dynu f' | python3 -c 'import sys,json; print(json.load(sys.stdin)["settings"][0]["username"])')" "Dynu renders the constant username placeholder (no prompt)"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "AUDIT: verify-accepted marks creds verified (messaging tier only)"
assert_eq "2" "$(cat "$DDNS_PW_INPUT_COUNT_FILE")" "password field re-prompts after invalid single quote"
assert_contains "$(cat "$LAST_WARN_FILE")" "single quote" "password validation explains single quote rejection"
unset -f ui_input

BAD_DDNS_SLEEP_COUNT=0
BAD_DDNS_PREFLIGHT_COUNT_FILE="$TMP_ROOT/bad-ddns-preflight-count"
printf '0\n' >"$BAD_DDNS_PREFLIGHT_COUNT_FILE"
ui_confirm() {
    return 0
}
ui_input_validated() {
    case "$1" in
        Your*) printf 'gate.test\n' ;;
        Dynu*) printf 'dynu-user\n' ;;
        *) printf 'value\n' ;;
    esac
}
ui_password() {
    printf 'bad-secret\n'
}
ui_choose() {
    case "$1" in
        Do\ you*) printf 'Yes\n' ;;
        Does\ your*) printf 'No - my IP changes (dynamic)\n' ;; # static/dynamic gate: dynamic -> reach the picker
        Choose*) printf 'Free hostname · Dynu\n' ;;             # provider picker -> Dynu keeps its curl preflight
        Remote*) printf 'Skip HTTPS for now\n' ;;
        *) printf 'Skip HTTPS for now\n' ;;
    esac
}
sleep() {
    # Count only the DNS-propagation waits (sleep 10), not the sub-second frames
    # of the ephemeral-verify spinner's ui_spin — the assertion below is
    # about the auto-retry loop, not the spinner animation.
    [[ "${1:-}" =~ ^[0-9]+$ ]] && ((${1:-0} >= 2)) \
        && BAD_DDNS_SLEEP_COUNT=$((BAD_DDNS_SLEEP_COUNT + 1))
    return 0
}
net_detect_public_ip() {
    _NET_PUBLIC_IP="203.0.113.10"
    return 0
}
ddns_verify_via_container() {
    local calls
    calls=$(cat "$BAD_DDNS_PREFLIGHT_COUNT_FILE" 2>/dev/null || printf '0')
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$BAD_DDNS_PREFLIGHT_COUNT_FILE"
    # Reject: the caller clears the fields and re-prompts (like Dynu badauth before).
    return 1
}
stage2_dns_classify() {
    printf 'no-a'
    return 1
}

seed_stage2_env_vars
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="stale-dynu-password")
_WIZ_DDNS_PREFLIGHT_OK="true"
_WIZ_DDNS_INVALIDATED="false"
_stage2_collect_domain >/dev/null 2>&1
assert_eq "1" "$(cat "$BAD_DDNS_PREFLIGHT_COUNT_FILE")" "AUDIT: bad auth test exercises the ephemeral verify"
assert_eq "0" "$BAD_DDNS_SLEEP_COUNT" "AUDIT: bad auth does not wait for propagation"
# Rejected creds clear _WIZ_DDNS_FIELDS -> the shape-valid gate refuses the write.
if [[ -f "$SCRIPT_DIR/config/ddns-updater/config.json" ]]; then
    fail "AUDIT: bad Dynu auth does not write DDNS config.json"
else
    pass "AUDIT: bad Dynu auth does not write DDNS config.json"
fi

stage2_dns_classify() {
    printf 'ok'
    return 0
}
pull_images() { :; }
start_stack() { :; }
wait_all_healthy() { :; }
print_access_info() { :; }
stage2_le_gate() { return 0; }

printf '0\n' >"$BAD_DDNS_PREFLIGHT_COUNT_FILE"
seed_stage2_env_vars
mkdir -p "$SCRIPT_DIR/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="stale-dynu-password")
_WIZ_DDNS_PREFLIGHT_OK="true"
_WIZ_DDNS_INVALIDATED="false"
_WIZ_JELLYFIN_BITRATE=""
# A coincidental DNS-ok must NOT silently sail past a rejected DDNS login —
# that would leave ddns-updater unconfigured and remote access would break on the
# next IP change. collect_domain routes to the retry menu instead; the ui_choose
# stub picks "Skip HTTPS for now", so it returns non-zero (does not reach install).
if _stage2_collect_domain >/dev/null 2>&1; then
    fail "AUDIT: bad auth + coincidental DNS-ok does NOT silently reach install"
else
    pass "AUDIT: bad auth + coincidental DNS-ok does NOT silently reach install"
fi
assert_eq "1" "$(cat "$BAD_DDNS_PREFLIGHT_COUNT_FILE")" "AUDIT: bad auth path exercises the ephemeral verify"
if [[ -f "$SCRIPT_DIR/config/ddns-updater/config.json" ]]; then
    fail "AUDIT: bad auth does not write DDNS config.json"
else
    pass "AUDIT: bad auth does not write DDNS config.json"
fi

scenario_end "$CURRENT_SCENARIO"
summary

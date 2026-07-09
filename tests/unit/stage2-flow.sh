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

[[ -f "$REPO_ROOT/scripts/setup/stages/stage2.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

# The DDNS password is collected via the shared ui_password_validated primitive
# (issue #6, replacing _stage2_password_validated). Source the ui layer so that real
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

# S2-01: offer choices and tell-more copy.
offer_choices="$(stage2_offer_choices)"
assert_contains "$offer_choices" "Enable remote access" "S2-01: offer includes Enable remote access"
assert_contains "$offer_choices" "Skip for now" "S2-01: offer includes Skip for now"
assert_contains "$offer_choices" "Tell me more" "S2-01: offer includes Tell me more"

tell_more="$(stage2_tell_me_more_copy)"
assert_contains "$tell_more" "domain" "S2-01: tell-me-more explains domain requirement"
assert_contains "$tell_more" "WireGuard" "S2-01: tell-me-more explains WireGuard"

# S2-10: retry/continue/skip choices for gate failures.
dns_choices="$(stage2_dns_retry_choices)"
assert_contains "$dns_choices" "Retry DNS check" "S2-10: DNS retry choices include Retry DNS check"
assert_contains "$dns_choices" "Skip HTTPS for now" "S2-10: DNS retry choices include Skip HTTPS for now"

port_choices="$(stage2_port_gate_choices)"
assert_contains "$port_choices" "Retry" "S2-10: port gate includes Retry"
assert_contains "$port_choices" "Continue with manual verification" "S2-10: port gate includes manual verification fallback"
assert_contains "$port_choices" "Skip HTTPS for now" "S2-10: port gate includes Skip HTTPS for now"

le_choices="$(stage2_le_failure_choices)"
assert_contains "$le_choices" "Skip HTTPS for now" "S2-16: LE gate includes Skip HTTPS for now"
assert_contains "$le_choices" "Exit so I can fix and retry" "S2-16: LE gate includes fix-and-retry exit"
assert_contains "$le_choices" "Abort setup" "S2-16: LE gate includes Abort setup"

# S2-12: confirm choices use approved UI-SPEC labels.
confirm_choices="$(stage2_confirm_choices)"
assert_contains "$confirm_choices" "Install" "S2-12: confirm includes Install"
assert_contains "$confirm_choices" "Back" "S2-12: confirm includes Back"
assert_contains "$confirm_choices" "Skip remote access" "S2-12: confirm includes Skip remote access"

# S2-15: skip copy is the user-facing fallback when ready postconditions fail.
skip_copy="$(stage2_skip_summary_copy)"
assert_contains "$skip_copy" "HTTPS skipped. LAN + VPN work. Choose Features & settings -> Add remote access from the menu to try again." "S2-10: skip summary matches UI-SPEC copy"

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
        [[ -n "${LAST_WARN_FILE:-}" ]] && printf '%s\n' "$LAST_WARN" > "$LAST_WARN_FILE"
    fi
}

source "$REPO_ROOT/scripts/setup/env_gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/lib/validators.sh"

_WIZ_ADMIN_EMAIL=""
_WIZ_PREV_EMAIL=""
NPM_ADMIN_EMAIL="admin@mediastack.local"
_stage2_seed_wizard_defaults
assert_eq "" "$_WIZ_ADMIN_EMAIL" "S2-01: remote setup blanks LAN-only demo email"

_WIZ_ADMIN_EMAIL=""
_WIZ_PREV_EMAIL=""
NPM_ADMIN_EMAIL="owner@gate.test"
_stage2_seed_wizard_defaults
assert_eq "owner@gate.test" "$_WIZ_ADMIN_EMAIL" "S2-01: remote setup preserves real email"

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
# Persist-decouple (#236): config.json is written on SHAPE-VALID render even
# though the provider was never live-verified (PREFLIGHT_OK stays false from the
# seed). Gating persistence on PREFLIGHT_OK would brick the 5 non-Dynu providers.
write_env >/dev/null
assert_eq "dynu" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "04-05: DDNS provider persists to .env (non-secret)"
assert_eq "gate.test" "$(env_val_from "$SCRIPT_DIR/.env" DOMAIN)" "04-05: Stage 2 domain persists to .env"
assert_eq "unchecked" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "04-05: Stage 2 starts unchecked before install verification"
assert_eq '10.8.0.0/24' "$(env_val_from "$SCRIPT_DIR/.env" WG_INIT_ALLOWED_IPS)" "04-05: WireGuard init allowed IPs persist"
assert_eq 'true' "$(env_val_from "$SCRIPT_DIR/.env" WG_PER_CLIENT_FIREWALL)" "04-05: WireGuard per-client firewall flag persists"
assert_eq 'full-lan' "$(env_val_from "$SCRIPT_DIR/.env" WG_ACCESS_TIER)" "ADR-29: WG_ACCESS_TIER persists"
assert_eq '10.8.0.0/24' "$(env_val_from "$SCRIPT_DIR/.env" WG_LAN_CIDR)" "ADR-29: WG_LAN_CIDR persists"
assert_eq '192.168.1.10' "$(env_val_from "$SCRIPT_DIR/.env" WG_SERVER_LAN_IP)" "ADR-29: WG_SERVER_LAN_IP persists"
assert_eq 'dynu"pw\with$chars' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["password"])' "$SCRIPT_DIR/config/ddns-updater/config.json")" "04-05: DDNS password persists via JSON-safe writer"
assert_eq "${DDNS_UPDATER_UID}:${DDNS_UPDATER_GID} 600" "$(stat -c '%u:%g %a' "$SCRIPT_DIR/config/ddns-updater/config.json")" "AUDIT: DDNS config writer secures file for configured container user"

if grep -q '^PASSWORD=' "$SCRIPT_DIR/.env"; then
    fail "04-05: WireGuard plaintext PASSWORD is not written"
else
    pass "04-05: WireGuard plaintext PASSWORD is not written"
fi
assert_contains "$(grep '^WG_INIT_PASSWORD=' "$SCRIPT_DIR/.env")" "WG_INIT_PASSWORD='" "04-05: WireGuard init password is single-quoted"

DDNS_PERM_CALLS="$TMP_ROOT/ddns-permission-calls"
DDNS_PERM_DIR="$TMP_ROOT/ddns-permission-dir"
mkdir -p "$DDNS_PERM_DIR"
: > "$DDNS_PERM_DIR/config.json"
unset DDNS_UPDATER_UID DDNS_UPDATER_GID
stat() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "%u:%g" ]]; then
        printf '1001:1001\n'
        return 0
    fi
    command stat "$@"
}
chown() {
    printf 'direct chown %s\n' "$*" >> "$DDNS_PERM_CALLS"
    return 1
}
chmod() {
    printf 'direct chmod %s\n' "$*" >> "$DDNS_PERM_CALLS"
    return 1
}
sudo() {
    printf 'sudo %s\n' "$*" >> "$DDNS_PERM_CALLS"
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

# C4/#236: a re-run that SKIPS the DDNS step must leave an existing chmod-600
# config.json byte-untouched (credentials live there now, not in .env). Seed one,
# blank the wizard's collected fields, skip, and assert the file is preserved.
seed_stage2_env_vars
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DDNS_PREFLIGHT_OK="false"
_WIZ_DDNS_INVALIDATED="false"
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
printf '%s\n' '{"settings":[{"provider":"duckdns","domain":"gate.test","token":"keep-me","ip_version":"ipv4"}]}' \
    > "$SCRIPT_DIR/config/ddns-updater/config.json"
cp "$SCRIPT_DIR/config/ddns-updater/config.json" "$TMP_ROOT/ddns-skip-preserve.json"
STAGE_1_COMPLETE=1
_stage2_skip_https >/dev/null
if cmp -s "$TMP_ROOT/ddns-skip-preserve.json" "$SCRIPT_DIR/config/ddns-updater/config.json"; then
    pass "C4: Stage 2 skip leaves an existing DDNS config.json byte-untouched"
else
    fail "C4: Stage 2 skip leaves an existing DDNS config.json byte-untouched"
fi

reset_stage2_ddns_prompt_stubs() {
    WARN_COUNT=0
    LAST_WARN=""
    LAST_WARN_FILE="$TMP_ROOT/ddns-last-warn"
    : > "$LAST_WARN_FILE"
    DDNS_PASSWORD_COUNT_FILE="$TMP_ROOT/ddns-password-count"
    printf '0\n' > "$DDNS_PASSWORD_COUNT_FILE"
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
# Dynu collects password ONLY (#248), so the loop drives a single-quote reject
# then a good value, proving the field loop re-prompts on validator failure.
reset_stage2_ddns_prompt_stubs
DDNS_PW_INPUT_COUNT_FILE="$TMP_ROOT/ddns-pw-input-count"
printf '0\n' > "$DDNS_PW_INPUT_COUNT_FILE"
ui_input() {
    local n
    n=$(cat "$DDNS_PW_INPUT_COUNT_FILE" 2>/dev/null || printf '0')
    n=$((n + 1))
    printf '%s\n' "$n" > "$DDNS_PW_INPUT_COUNT_FILE"
    case "$n" in
        1) printf "bad'quote\n" ;;
        *) printf 'good-secret\n' ;;
    esac
}
_stage2_offer_ddns "true" >/dev/null
assert_eq "good-secret" "${_WIZ_DDNS_FIELDS[password]}" "04-05: field loop rejects single quote, keeps good password"
assert_eq "mediastack" "$(bash -c 'source scripts/lib/ddns_providers.sh; declare -A f=([domain]=d.test [password]=x); ddns_render_config_json dynu f' | python3 -c 'import sys,json; print(json.load(sys.stdin)["settings"][0]["username"])')" "04-05: Dynu renders the constant username placeholder (no prompt)"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "AUDIT: verify-accepted marks creds verified (messaging tier only)"
assert_eq "2" "$(cat "$DDNS_PW_INPUT_COUNT_FILE")" "04-05: password field re-prompts after invalid single quote"
assert_contains "$(cat "$LAST_WARN_FILE")" "single quote" "04-05: password validation explains single quote rejection"
unset -f ui_input

BAD_DDNS_SLEEP_COUNT=0
BAD_DDNS_PREFLIGHT_COUNT_FILE="$TMP_ROOT/bad-ddns-preflight-count"
printf '0\n' > "$BAD_DDNS_PREFLIGHT_COUNT_FILE"
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
        Does\ your*) printf 'No - my IP changes (dynamic)\n' ;;  # #94 static/dynamic gate: dynamic -> reach the picker
        Choose*) printf 'Free hostname · Dynu\n' ;;  # #236 provider picker -> Dynu keeps its curl preflight
        Remote*) printf 'Skip HTTPS for now\n' ;;
        *) printf 'Skip HTTPS for now\n' ;;
    esac
}
sleep() {
    # Count only the DNS-propagation waits (sleep 10), not the sub-second frames
    # of the ephemeral-verify spinner (#237's ui_spin) — the assertion below is
    # about the auto-retry loop, not the spinner animation.
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( ${1:-0} >= 2 )) \
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
    printf '%s\n' "$calls" > "$BAD_DDNS_PREFLIGHT_COUNT_FILE"
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

printf '0\n' > "$BAD_DDNS_PREFLIGHT_COUNT_FILE"
seed_stage2_env_vars
mkdir -p "$SCRIPT_DIR/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="stale-dynu-password")
_WIZ_DDNS_PREFLIGHT_OK="true"
_WIZ_DDNS_INVALIDATED="false"
_WIZ_JELLYFIN_BITRATE=""
# M2: a coincidental DNS-ok must NOT silently sail past a rejected DDNS login —
# that would leave ddns-updater unconfigured and remote access would break on the
# next IP change. collect_domain routes to the retry menu instead; the ui_choose
# stub picks "Skip HTTPS for now", so it returns non-zero (does not reach install).
if _stage2_collect_domain >/dev/null 2>&1; then
    fail "AUDIT: bad auth + coincidental DNS-ok does NOT silently reach install (M2)"
else
    pass "AUDIT: bad auth + coincidental DNS-ok does NOT silently reach install (M2)"
fi
assert_eq "1" "$(cat "$BAD_DDNS_PREFLIGHT_COUNT_FILE")" "AUDIT: bad auth path exercises the ephemeral verify"
if [[ -f "$SCRIPT_DIR/config/ddns-updater/config.json" ]]; then
    fail "AUDIT: bad auth does not write DDNS config.json"
else
    pass "AUDIT: bad auth does not write DDNS config.json"
fi

# #94: a static-IP / self-managed-DNS user picks "Yes" (option 2) at the new
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
ddns_verify_via_container() { STATIC_IP_VERIFY_CALLED=1; return 0; }
_WIZ_USES_DDNS="true"
if _stage2_offer_ddns "false" >/dev/null 2>&1; then
    fail "S2-94: static-IP choice skips DDNS (offer returns non-zero)"
else
    pass "S2-94: static-IP choice skips DDNS (offer returns non-zero)"
fi
assert_eq "0" "$STATIC_IP_VERIFY_CALLED" "S2-94: static-IP choice does not run the ephemeral verify"
assert_eq "false" "$_WIZ_USES_DDNS" "S2-94: static-IP choice records _WIZ_USES_DDNS=false (menu hides Re-enter Dynu)"
assert_eq "false" "$_WIZ_DDNS_PREFLIGHT_OK" "S2-94: static-IP choice leaves DDNS creds unpersistable"

seed_stage2_env_vars
mkdir -p "$SCRIPT_DIR/scripts" "$TMP_ROOT/ddns-symlink-target"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
cat > "$SCRIPT_DIR/.env" <<'EOF'
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
if (( stage2_symlink_rc != 0 )); then
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
cat > "$SCRIPT_DIR/.env" <<'EOF'
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
if (( run_stage2_symlink_rc != 0 )); then
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

# ---------------------------------------------------------------------------
# #236: provider picker + field loop orchestration (stage2-flow style; the
# picker/field-loop are stubbed, the real _stage2_offer_ddns flow is driven).
# ---------------------------------------------------------------------------
DDNS_CHOOSE_RET=""
DDNS_INPUT_RET=""
DDNS_VERIFY_RC=0
_WIZ_DOMAIN="gate.test"
ui_choose() { printf '%s\n' "$DDNS_CHOOSE_RET"; }
ui_input_validated() { printf '%s\n' "$DDNS_INPUT_RET"; }
ui_password_validated() { printf '%s\n' "$DDNS_INPUT_RET"; }
# #237: the verify is provider-agnostic and exit-code-valued (0 accept / 1 reject
# / 2 degrade). Drive it via DDNS_VERIFY_RC.
ddns_verify_via_container() { return "${DDNS_VERIFY_RC:-0}"; }

# A token provider whose verify ACCEPTS (exit 0): #237 verifies every provider, so
# PREFLIGHT_OK=true and it is NOT the unchecked terminal — it reaches the LE gate.
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DOMAIN="gate.test"
DDNS_CHOOSE_RET="Free hostname · DuckDNS"
DDNS_INPUT_RET="duck-token-abc"
DDNS_VERIFY_RC=0
_stage2_offer_ddns "true" "pick" >/dev/null
assert_eq "0" "$?" "S2-237: token provider verify-accepted (offer returns 0)"
assert_eq "duckdns" "$_WIZ_DDNS_PROVIDER" "S2-237: picker selects DuckDNS"
assert_eq "duck-token-abc" "${_WIZ_DDNS_FIELDS[token]}" "S2-237: token field collected into the assoc"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "S2-237: non-Dynu verify-accept sets the verified tier"
if _stage2_ddns_unverified; then
    fail "S2-237: verify-accepted is NOT the unchecked terminal (reaches LE)"
else
    pass "S2-237: verify-accepted is NOT the unchecked terminal (reaches LE)"
fi

# Degrade (exit 2 — docker/image unavailable): the shape-valid creds are KEPT and
# the provider lands the honest unchecked terminal (never re-prompt good creds).
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DOMAIN="gate.test"
DDNS_CHOOSE_RET="Free hostname · DuckDNS"
DDNS_INPUT_RET="duck-token-xyz"
DDNS_VERIFY_RC=2
_stage2_offer_ddns "true" "pick" >/dev/null
assert_eq "0" "$?" "S2-237: degrade keeps shape-valid creds (offer returns 0)"
assert_eq "duck-token-xyz" "${_WIZ_DDNS_FIELDS[token]:-}" "S2-237: degrade KEEPS the collected creds (not cleared)"
assert_eq "false" "$_WIZ_DDNS_PREFLIGHT_OK" "S2-237: degrade leaves PREFLIGHT_OK=false (unchecked tier)"
if _stage2_ddns_unverified; then
    pass "S2-237: degrade lands on the honest unchecked terminal"
else
    fail "S2-237: degrade lands on the honest unchecked terminal"
fi

# Clear-then-refill: switching DuckDNS -> Dynu must not leak the token key into
# the Dynu render (the shared field name `token` is the trap the discipline guards).
DDNS_CHOOSE_RET="Free hostname · Dynu"
DDNS_INPUT_RET="alice"
DDNS_VERIFY_RC=0
_stage2_offer_ddns "true" "pick" >/dev/null
assert_eq "dynu" "$_WIZ_DDNS_PROVIDER" "S2-237: picker switches to Dynu"
assert_eq "" "${_WIZ_DDNS_FIELDS[token]:-}" "S2-237: provider switch clears the stale DuckDNS token (no cross-provider leak)"
assert_eq "alice" "${_WIZ_DDNS_FIELDS[password]}" "S2-237: Dynu fields (password) refilled after the switch"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "S2-237: Dynu verify-accept sets the verified tier"
if _stage2_ddns_unverified; then
    fail "S2-237: Dynu verify-accept is verified, not the unchecked terminal"
else
    pass "S2-237: Dynu verify-accept is verified, not the unchecked terminal"
fi

# Escape hatch: the picker's "Skip for now" option backs out of DDNS entirely
# (before the field loop), so a user without creds ready is never trapped.
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DOMAIN="gate.test"
_WIZ_USES_DDNS="true"
DDNS_CHOOSE_RET="$_DDNS_SKIP_LABEL"
if _stage2_offer_ddns "true" "pick" >/dev/null 2>&1; then
    fail "S2-237: picker 'Skip for now' escape hatch backs out (offer returns non-zero)"
else
    pass "S2-237: picker 'Skip for now' escape hatch backs out (offer returns non-zero)"
fi
assert_eq "false" "$_WIZ_USES_DDNS" "S2-237: picker skip sets _WIZ_USES_DDNS=false (no field loop)"
assert_eq "" "$_WIZ_DDNS_PROVIDER" "S2-237: picker skip clears the provider"

# M1 escape hatch: on an interactive TTY, _stage2_escapable_input must offer a
# graceful back-out (empty submission OR repeated validation failure) instead of
# the wizard-killing valve. Force the interactive path and stub the primitives.
_stage2_is_interactive() { return 0; }
M1_INPUT=""
ui_input() { printf '%s' "$M1_INPUT"; }
# (a) empty submission + skip -> back out (rc 2)
M1_INPUT=""
ui_choose() { printf 'Skip DDNS for now\n'; }
_stage2_escapable_input "DuckDNS API token" "" validate_ddns_token "Skip DDNS for now" >/dev/null 2>&1
assert_eq "2" "$?" "M1: empty field + skip backs out of the input loop (rc 2)"
# (b) a valid value returns it, trimmed (no escape menu)
M1_INPUT="  duck-token-abc  "
m1_out=$(_stage2_escapable_input "DuckDNS API token" "" validate_ddns_token "Skip DDNS for now" 2>/dev/null); m1_rc=$?
assert_eq "0" "$m1_rc" "M1: a valid value collects (rc 0)"
assert_eq "duck-token-abc" "$m1_out" "M1: collected value is whitespace-trimmed"
# (c) finding 5 — a recalled DEFAULT that can't validate must not become a
# Ctrl-C-only trap: after 3 rejections the escape is offered even with a default.
M1_INPUT=""   # Enter keeps the (invalid) default each time
ui_choose() { printf 'Skip DDNS for now\n'; }   # pick skip when the valve fires
_stage2_escapable_input "Cloudflare Zone ID" "not-32-hex" validate_zone_id "Skip DDNS for now" >/dev/null 2>&1
assert_eq "2" "$?" "M1/finding5: an invalid pre-filled default escapes after repeated rejects (rc 2)"
# (d) via _stage2_offer_ddns: empty field + skip -> offer backs out, USES_DDNS=false
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""; _WIZ_DDNS_FIELDS=(); _WIZ_DOMAIN="gate.test"; _WIZ_USES_DDNS="true"
DDNS_CHOOSE_RET="Free hostname · DuckDNS"
ui_choose() { case "$1" in Nothing*|That\ value*) printf 'Skip DDNS for now\n' ;; *) printf '%s\n' "$DDNS_CHOOSE_RET" ;; esac; }
M1_INPUT=""
if _stage2_offer_ddns "true" "pick" >/dev/null 2>&1; then
    fail "M1: empty field escape backs out of _stage2_offer_ddns (returns non-zero)"
else
    pass "M1: empty field escape backs out of _stage2_offer_ddns (returns non-zero)"
fi
assert_eq "false" "$_WIZ_USES_DDNS" "M1: field-loop escape sets _WIZ_USES_DDNS=false"
unset -f _stage2_is_interactive ui_input ui_choose

# Shape-valid persist: a non-Dynu provider writes config.json even though it was
# never live-verified (PREFLIGHT_OK=false) — never a config-less dead remote.
seed_stage2_env_vars
_WIZ_DDNS_PROVIDER="duckdns"
_WIZ_DDNS_FIELDS=([token]="persist-token")
_WIZ_DDNS_PREFLIGHT_OK="false"
write_env >/dev/null
ddns_cfg="$SCRIPT_DIR/config/ddns-updater/config.json"
assert_eq "persist-token" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["token"])' "$ddns_cfg")" "S2-236: non-Dynu shape-valid creds persist to config.json (PREFLIGHT_OK=false)"
assert_eq "duckdns" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["provider"])' "$ddns_cfg")" "S2-236: config.json records the selected provider"
assert_eq "duckdns" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "S2-236: non-secret DDNS_PROVIDER persists to .env"

# State-leak: switching duckdns -> dynu and re-persisting leaves NO token key.
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="s3cret")
write_env >/dev/null
if python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["settings"][0]; sys.exit(0 if "token" not in s else 1)' "$ddns_cfg"; then
    pass "S2-236: re-persist after provider switch leaves no stale token key in config.json"
else
    fail "S2-236: re-persist after provider switch leaves no stale token key in config.json"
fi

# Consistency (diff-review finding): after a badauth/skip clears the fields,
# write_env must keep .env DDNS_PROVIDER in sync with the preserved config.json
# (the prior provider), not adopt the now-stale in-memory _WIZ_DDNS_PROVIDER.
seed_stage2_env_vars
ddns_cfg="$SCRIPT_DIR/config/ddns-updater/config.json"
_WIZ_DDNS_PROVIDER="duckdns"; _WIZ_DDNS_FIELDS=([token]="keep-tok")
write_env >/dev/null                              # persists duckdns + config.json
_WIZ_DDNS_PROVIDER="dynu"; _WIZ_DDNS_FIELDS=()     # badauth/skip: provider stale, fields cleared
write_env >/dev/null
assert_eq "duckdns" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "S2-236: cleared-fields write_env keeps .env DDNS_PROVIDER matching the preserved config.json"
assert_eq "duckdns" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["provider"])' "$ddns_cfg")" "S2-236: cleared-fields write_env preserves the prior config.json provider"

unset -f ui_choose ui_input_validated ui_password_validated ddns_verify_via_container

# Plan 04-04 controller shell contract.
stage2_path="$REPO_ROOT/scripts/setup/stages/stage2.sh"
if [[ -f "$stage2_path" ]]; then
    stage2_source="$(cat "$stage2_path")"
else
    stage2_source=""
fi

assert_contains "$stage2_source" "run_stage2()" "04-04: run_stage2 controller exists"
assert_contains "$stage2_source" "MediaStack - Remote Access" "04-04: Remote access banner title"
assert_contains "$stage2_source" "HTTPS + WireGuard in a few minutes (longer on first DNS setup)" "04-04: Stage 2 banner subtitle"
assert_contains "$stage2_source" "_stage2_install()" "04-04: install function exists"
assert_contains "$stage2_source" 'MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard' "04-05: NPM remote attempt is process-scoped (Dynu=1; unverified non-Dynu=0)"
assert_contains "$stage2_source" "type ui_spin" "S2-16: Stage 2 remote attempt falls back when UI spinner is not loaded"
assert_contains "$stage2_source" '_stage2_le_ready_hosts' "04-05: ready promotion checks NPM disk/proxy postconditions"
assert_contains "$stage2_source" '_stage2_probe_https_ready "https://$fqdn"' "04-05: ready promotion checks live HTTPS"
assert_contains "$stage2_source" "_stage2_set_remote_state ready" "04-05: install can promote ready after postconditions"
assert_contains "$stage2_source" "_stage2_set_remote_state failed" "S2-16: install records failed state after cert failure"
assert_contains "$stage2_source" "stage2_le_gate" "S2-16: install delegates certificate postconditions to LE gate"
assert_contains "$stage2_source" "config/state/npm-cert-status-last.json" "S2-16: LE gate exposes persistent cert status path"
assert_contains "$stage2_source" "stage2_le_failure_copy" "S2-16: LE classifications have user-facing copy helper"

recovery_path="$REPO_ROOT/scripts/setup/recovery.sh"
if [[ -f "$recovery_path" ]]; then
    recovery_source_non_comments="$(grep -v '^[[:space:]]*#' "$recovery_path" || true)"
    if [[ "$recovery_source_non_comments" == *"MEDIASTACK_NPM_ATTEMPT_REMOTE=1"* ]]; then
        fail "REC-02: recovery does not own MEDIASTACK_NPM_ATTEMPT_REMOTE"
    else
        pass "REC-02: recovery does not own MEDIASTACK_NPM_ATTEMPT_REMOTE"
    fi
else
    fail "REC-02: recovery source exists"
fi

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/stage2-ddns.sh
#
# Contract tests for Stage 2 terminal-flow copy and choice labels.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-ddns"
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

ddns_verify_via_container() {
    return 0
}
# ---------------------------------------------------------------------------

# Provider picker + field loop orchestration (stage2-flow style; the
# picker/field-loop are stubbed, the real _stage2_offer_ddns flow is driven).
# ---------------------------------------------------------------------------
DDNS_CHOOSE_RET=""
DDNS_INPUT_RET=""
DDNS_VERIFY_RC=0
_WIZ_DOMAIN="gate.test"
ui_choose() { printf '%s\n' "$DDNS_CHOOSE_RET"; }
ui_input_validated() { printf '%s\n' "$DDNS_INPUT_RET"; }
ui_password_validated() { printf '%s\n' "$DDNS_INPUT_RET"; }
# The verify is provider-agnostic and exit-code-valued (0 accept / 1 reject
# / 2 degrade). Drive it via DDNS_VERIFY_RC.
ddns_verify_via_container() { return "${DDNS_VERIFY_RC:-0}"; }

# A token provider whose verify ACCEPTS (exit 0): every provider is verified, so
# PREFLIGHT_OK=true and it is NOT the unchecked terminal — it reaches the LE gate.
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DOMAIN="gate.test"
DDNS_CHOOSE_RET="Free hostname · DuckDNS"
DDNS_INPUT_RET="duck-token-abc"
DDNS_VERIFY_RC=0
_stage2_offer_ddns "true" "pick" >/dev/null
assert_eq "0" "$?" "token provider verify-accepted (offer returns 0)"
assert_eq "duckdns" "$_WIZ_DDNS_PROVIDER" "picker selects DuckDNS"
assert_eq "duck-token-abc" "${_WIZ_DDNS_FIELDS[token]}" "token field collected into the assoc"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "non-Dynu verify-accept sets the verified tier"
if _stage2_ddns_unverified; then
    fail "verify-accepted is NOT the unchecked terminal (reaches LE)"
else
    pass "verify-accepted is NOT the unchecked terminal (reaches LE)"
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
assert_eq "0" "$?" "degrade keeps shape-valid creds (offer returns 0)"
assert_eq "duck-token-xyz" "${_WIZ_DDNS_FIELDS[token]:-}" "degrade KEEPS the collected creds (not cleared)"
assert_eq "false" "$_WIZ_DDNS_PREFLIGHT_OK" "degrade leaves PREFLIGHT_OK=false (unchecked tier)"
if _stage2_ddns_unverified; then
    pass "degrade lands on the honest unchecked terminal"
else
    fail "degrade lands on the honest unchecked terminal"
fi

# Clear-then-refill: switching DuckDNS -> Dynu must not leak the token key into
# the Dynu render (the shared field name `token` is the trap the discipline guards).
DDNS_CHOOSE_RET="Free hostname · Dynu"
DDNS_INPUT_RET="alice"
DDNS_VERIFY_RC=0
_stage2_offer_ddns "true" "pick" >/dev/null
assert_eq "dynu" "$_WIZ_DDNS_PROVIDER" "picker switches to Dynu"
assert_eq "" "${_WIZ_DDNS_FIELDS[token]:-}" "provider switch clears the stale DuckDNS token (no cross-provider leak)"
assert_eq "alice" "${_WIZ_DDNS_FIELDS[password]}" "Dynu fields (password) refilled after the switch"
assert_eq "true" "$_WIZ_DDNS_PREFLIGHT_OK" "Dynu verify-accept sets the verified tier"
if _stage2_ddns_unverified; then
    fail "Dynu verify-accept is verified, not the unchecked terminal"
else
    pass "Dynu verify-accept is verified, not the unchecked terminal"
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
    fail "picker 'Skip for now' escape hatch backs out (offer returns non-zero)"
else
    pass "picker 'Skip for now' escape hatch backs out (offer returns non-zero)"
fi
assert_eq "false" "$_WIZ_USES_DDNS" "picker skip sets _WIZ_USES_DDNS=false (no field loop)"
assert_eq "" "$_WIZ_DDNS_PROVIDER" "picker skip clears the provider"

# Escape hatch: on an interactive TTY, _stage2_escapable_input must offer a
# graceful back-out (empty submission OR repeated validation failure) instead of
# the wizard-killing valve. Force the interactive path and stub the primitives.
_stage2_is_interactive() { return 0; }
M1_INPUT=""
ui_input() { printf '%s' "$M1_INPUT"; }
# (a) empty submission + skip -> back out (rc 2)
M1_INPUT=""
ui_choose() { printf 'Skip DDNS for now\n'; }
_stage2_escapable_input "DuckDNS API token" "" validate_ddns_token "Skip DDNS for now" >/dev/null 2>&1
assert_eq "2" "$?" "empty field + skip backs out of the input loop (rc 2)"
# (b) a valid value returns it, trimmed (no escape menu)
M1_INPUT="  duck-token-abc  "
m1_out=$(_stage2_escapable_input "DuckDNS API token" "" validate_ddns_token "Skip DDNS for now" 2>/dev/null)
m1_rc=$?
assert_eq "0" "$m1_rc" "a valid value collects (rc 0)"
assert_eq "duck-token-abc" "$m1_out" "collected value is whitespace-trimmed"
# (c) a recalled DEFAULT that can't validate must not become a
# Ctrl-C-only trap: after 3 rejections the escape is offered even with a default.
M1_INPUT=""                                   # Enter keeps the (invalid) default each time
ui_choose() { printf 'Skip DDNS for now\n'; } # pick skip when the valve fires
_stage2_escapable_input "Cloudflare Zone ID" "not-32-hex" validate_zone_id "Skip DDNS for now" >/dev/null 2>&1
assert_eq "2" "$?" "an invalid pre-filled default escapes after repeated rejects (rc 2)"
# (d) via _stage2_offer_ddns: empty field + skip -> offer backs out, USES_DDNS=false
reset_stage2_ddns_prompt_stubs
_WIZ_DDNS_PROVIDER=""
_WIZ_DDNS_FIELDS=()
_WIZ_DOMAIN="gate.test"
_WIZ_USES_DDNS="true"
DDNS_CHOOSE_RET="Free hostname · DuckDNS"
ui_choose() { case "$1" in Nothing* | That\ value*) printf 'Skip DDNS for now\n' ;; *) printf '%s\n' "$DDNS_CHOOSE_RET" ;; esac }
M1_INPUT=""
if _stage2_offer_ddns "true" "pick" >/dev/null 2>&1; then
    fail "empty field escape backs out of _stage2_offer_ddns (returns non-zero)"
else
    pass "empty field escape backs out of _stage2_offer_ddns (returns non-zero)"
fi
assert_eq "false" "$_WIZ_USES_DDNS" "field-loop escape sets _WIZ_USES_DDNS=false"
unset -f _stage2_is_interactive ui_input ui_choose

# Shape-valid persist: a non-Dynu provider writes config.json even though it was
# never live-verified (PREFLIGHT_OK=false) — never a config-less dead remote.
seed_stage2_env_vars
_WIZ_DDNS_PROVIDER="duckdns"
_WIZ_DDNS_FIELDS=([token]="persist-token")
_WIZ_DDNS_PREFLIGHT_OK="false"
write_env >/dev/null
ddns_cfg="$SCRIPT_DIR/config/ddns-updater/config.json"
assert_eq "persist-token" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["token"])' "$ddns_cfg")" "non-Dynu shape-valid creds persist to config.json (PREFLIGHT_OK=false)"
assert_eq "duckdns" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["provider"])' "$ddns_cfg")" "config.json records the selected provider"
assert_eq "duckdns" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "non-secret DDNS_PROVIDER persists to .env"

# State-leak: switching duckdns -> dynu and re-persisting leaves NO token key.
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=([password]="s3cret")
write_env >/dev/null
if python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["settings"][0]; sys.exit(0 if "token" not in s else 1)' "$ddns_cfg"; then
    pass "re-persist after provider switch leaves no stale token key in config.json"
else
    fail "re-persist after provider switch leaves no stale token key in config.json"
fi

# Consistency (diff-review finding): after a badauth/skip clears the fields,
# write_env must keep .env DDNS_PROVIDER in sync with the preserved config.json
# (the prior provider), not adopt the now-stale in-memory _WIZ_DDNS_PROVIDER.
seed_stage2_env_vars
ddns_cfg="$SCRIPT_DIR/config/ddns-updater/config.json"
_WIZ_DDNS_PROVIDER="duckdns"
_WIZ_DDNS_FIELDS=([token]="keep-tok")
write_env >/dev/null # persists duckdns + config.json
_WIZ_DDNS_PROVIDER="dynu"
_WIZ_DDNS_FIELDS=() # badauth/skip: provider stale, fields cleared
write_env >/dev/null
assert_eq "duckdns" "$(env_val_from "$SCRIPT_DIR/.env" DDNS_PROVIDER)" "cleared-fields write_env keeps .env DDNS_PROVIDER matching the preserved config.json"
assert_eq "duckdns" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"][0]["provider"])' "$ddns_cfg")" "cleared-fields write_env preserves the prior config.json provider"

unset -f ui_choose ui_input_validated ui_password_validated ddns_verify_via_container

# Stage 2 controller shell contract.
stage2_path="$REPO_ROOT/scripts/setup/stages/stage2.sh"
if [[ -f "$stage2_path" ]]; then
    stage2_source="$(cat "$stage2_path")"
else
    stage2_source=""
fi

assert_contains "$stage2_source" "run_stage2()" "run_stage2 controller exists"
assert_contains "$stage2_source" "MediaStack - Remote Access" "Remote access banner title"
assert_contains "$stage2_source" "HTTPS + WireGuard in a few minutes (longer on first DNS setup)" "Stage 2 banner subtitle"
install_source="$(cat "$REPO_ROOT/scripts/setup/stage2/install.sh")"
le_source="$(cat "$REPO_ROOT/scripts/setup/stage2/le.sh")"
common_source="$(cat "$REPO_ROOT/scripts/setup/stage2/common.sh")"
assert_contains "$install_source" "_stage2_install()" "install function exists"
assert_contains "$install_source" 'MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard' "NPM remote attempt is process-scoped (Dynu=1; unverified non-Dynu=0)"
assert_contains "$install_source" "type ui_spin" "Stage 2 remote attempt falls back when UI spinner is not loaded"
assert_contains "$le_source" '_stage2_le_ready_hosts' "ready promotion checks NPM disk/proxy postconditions"
assert_contains "$le_source" '_stage2_probe_https_ready "https://$fqdn"' "ready promotion checks live HTTPS"
assert_contains "$le_source" "_stage2_set_remote_state ready" "install can promote ready after postconditions"
assert_contains "$le_source" "_stage2_set_remote_state failed" "install records failed state after cert failure"
assert_contains "$le_source" "stage2_le_gate" "install delegates certificate postconditions to LE gate"
assert_contains "$common_source" "config/state/npm-cert-status-last.json" "LE gate exposes persistent cert status path"
assert_contains "$le_source" "stage2_le_failure_copy" "LE classifications have user-facing copy helper"

recovery_path="$REPO_ROOT/scripts/setup/recovery.sh"
if [[ -f "$recovery_path" ]]; then
    recovery_source_non_comments="$(grep -v '^[[:space:]]*#' "$recovery_path" || true)"
    if [[ "$recovery_source_non_comments" == *"MEDIASTACK_NPM_ATTEMPT_REMOTE=1"* ]]; then
        fail "recovery does not own MEDIASTACK_NPM_ATTEMPT_REMOTE"
    else
        pass "recovery does not own MEDIASTACK_NPM_ATTEMPT_REMOTE"
    fi
else
    fail "recovery source exists"
fi

scenario_end "$CURRENT_SCENARIO"
summary

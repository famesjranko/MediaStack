#!/usr/bin/env bash
# tests/unit/qbittorrent-whitelist.sh
# Auth-bypass whitelist policy of configure_qbittorrent. Split from
# qbittorrent.sh to keep both under the shell line cap.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="qbittorrent-whitelist"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CURL_LOG="$TMP_DIR/curl.log"

CONFIG_FILE=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/services/qbittorrent/main.sh"

BOLD=""
NC=""
JELLYFIN_ADMIN_USER='mediaadmin'
JELLYFIN_ADMIN_PASSWORD='shared-pass'
TORRENT_PORT=6881
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
MEDIASTACK_NETWORK_PREFIX=172.29.5

LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
LOG_DRIFT_MESSAGES=()
log_ok() { LOG_OK_MESSAGES+=("$1"); }
log_warn() { LOG_WARN_MESSAGES+=("$1"); }
log_drift() { LOG_DRIFT_MESSAGES+=("$1"); }
log_skip() { :; }
service_local_url() { printf 'http://localhost:8080'; }
cfg_field() {
    case "$1" in
        qbittorrent.save_path) echo "/data/torrents" ;;
        qbittorrent.temp_path) echo "/data/torrents/incomplete" ;;
        qbittorrent.max_ratio) echo "2.0" ;;
        qbittorrent.max_seeding_time) echo "1440" ;;
        qbittorrent.max_active_*) echo "3" ;;
        *) echo "0" ;;
    esac
}
cfg_qbt_categories() { :; }
api_fetch() { echo '{}'; }
sleep() { :; }

# Fake qBittorrent: logins succeed; GET /app/preferences returns the live
# whitelist from QBT_LIVE_WHITELIST / QBT_LIVE_ENABLED; setPreferences logs its
# JSON and fails when QBT_FAIL_SETPREFS=1.
curl() {
    local arg is_prefs_get=false is_set_prefs=false is_login=false stdin_field=""
    for arg in "$@"; do
        case "$arg" in
            *@/dev/stdin)
                stdin_field="${arg%@/dev/stdin}"
                cat >/dev/null
                ;;
        esac
    done
    for arg in "$@"; do
        [[ "$arg" == "$stdin_field@/dev/stdin" ]] && continue
        printf '%s\t' "$arg" >>"$CURL_LOG"
        [[ "$arg" == *"/api/v2/auth/login" ]] && is_login=true
        [[ "$arg" == *"/api/v2/app/preferences" ]] && is_prefs_get=true
        [[ "$arg" == *"/api/v2/app/setPreferences" ]] && is_set_prefs=true
    done
    printf '\n' >>"$CURL_LOG"
    if $is_login; then
        printf 'Ok.\n200\n'
    elif $is_prefs_get; then
        [[ "${QBT_LIVE_PREFS_FAIL:-0}" == "1" ]] && return 22
        LIVE_WL="${QBT_LIVE_WHITELIST-}" LIVE_EN="${QBT_LIVE_ENABLED:-false}" python3 -c '
import json, os
print(json.dumps({"bypass_auth_subnet_whitelist": os.environ["LIVE_WL"],
                  "bypass_auth_subnet_whitelist_enabled": os.environ["LIVE_EN"] == "true"}))'
    elif $is_set_prefs && [[ "${QBT_FAIL_SETPREFS:-0}" == "1" ]]; then
        return 22
    fi
    return 0
}

# --- Auth-bypass whitelist: only the credential-less caller containers -------

# Prints the whitelist keys of the last non-credential setPreferences payload
# in CURL_LOG as "<whitelist>|<enabled>", or "absent" when the keys are omitted.
_logged_whitelist() {
    python3 - "$CURL_LOG" <<'PY'
import json
import sys

found = None
for raw in open(sys.argv[1], encoding="utf-8"):
    fields = raw.rstrip("\n").split("\t")
    if not any("/api/v2/app/setPreferences" in f for f in fields):
        continue
    for i, f in enumerate(fields[:-1]):
        if f == "--data-urlencode" and fields[i + 1].startswith("json="):
            payload = json.loads(fields[i + 1][len("json="):])
            if "web_ui_password" not in payload:
                found = payload
if found is None:
    raise SystemExit(1)
if "bypass_auth_subnet_whitelist" not in found:
    print("absent")
else:
    print(f"{found['bypass_auth_subnet_whitelist']}|{found['bypass_auth_subnet_whitelist_enabled']}")
PY
}

# Runs configure_qbittorrent with a clean slate; extra env comes from the caller.
_run_whitelist_case() {
    : >"$CURL_LOG"
    LOG_OK_MESSAGES=()
    LOG_WARN_MESSAGES=()
    LOG_DRIFT_MESSAGES=()
    configure_qbittorrent >/dev/null
}

WANTED_WL='172.29.5.22/32, 172.29.5.23/32, 172.29.5.40/32'

# Given a fresh install (nothing whitelisted) and managed storage
# When configure runs
# Then only the sonarr, radarr and homepage /32s are whitelisted, never the /12 or the gateway
_run_whitelist_case
wl=$(_logged_whitelist)
assert_eq "$WANTED_WL|True" "$wl" "whitelist (managed, fresh): exactly the three caller /32s"
assert_not_contains "$wl" "172.16.0.0/12" "whitelist (managed, fresh): no /12"
assert_not_contains "$wl" "172.29.5.1/" "whitelist (managed, fresh): no gateway entry"

# Given manual app wiring
# When configure runs
# Then the manual branch whitelists the same three /32s
storage_is_manual() { return 0; }
_run_whitelist_case
unset -f storage_is_manual
assert_eq "$WANTED_WL|True" "$(_logged_whitelist)" "whitelist (manual wiring): exactly the three caller /32s"

# Given a non-default network prefix
# When configure runs
# Then the /32s follow that prefix
MEDIASTACK_NETWORK_PREFIX=10.77.3 _run_whitelist_case
assert_eq "10.77.3.22/32, 10.77.3.23/32, 10.77.3.40/32|True" "$(_logged_whitelist)" "whitelist: follows a non-default MEDIASTACK_NETWORK_PREFIX"

# Given MediaStack's legacy 172.16.0.0/12 enabled
# When configure runs
# Then the whitelist is replaced and the change is logged
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true _run_whitelist_case
assert_eq "$WANTED_WL|True" "$(_logged_whitelist)" "whitelist (legacy /12): replaced with the caller /32s"
assert_contains "$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")" "auth whitelist narrowed from 172.16.0.0/12 to $WANTED_WL" "whitelist (legacy /12): log_ok names the change"
assert_eq "0" "${#LOG_DRIFT_MESSAGES[@]}" "whitelist (legacy /12): no drift reported"

# Given a whitelist the user set
# When configure runs
# Then it is left out of the payload and drift is logged
QBT_LIVE_WHITELIST='10.0.0.0/8' QBT_LIVE_ENABLED=true _run_whitelist_case
assert_eq "absent" "$(_logged_whitelist)" "whitelist (user value): not overwritten"
assert_contains "$(printf '%s\n' "${LOG_DRIFT_MESSAGES[@]}")" "auth whitelist was changed outside MediaStack" "whitelist (user value): log_drift emitted"

# Given the legacy /12 but disabled by the user
# When configure runs
# Then it counts as user state and is left alone
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=false _run_whitelist_case
assert_eq "absent" "$(_logged_whitelist)" "whitelist (legacy /12 disabled): treated as user state"

# Given the whitelist is already the caller list
# When configure runs
# Then nothing is rewritten and no drift is reported
QBT_LIVE_WHITELIST=$'172.29.5.22/32\n172.29.5.23/32\n172.29.5.40/32' QBT_LIVE_ENABLED=true _run_whitelist_case
assert_eq "absent" "$(_logged_whitelist)" "whitelist (already current): not rewritten"
assert_eq "0" "${#LOG_DRIFT_MESSAGES[@]}" "whitelist (already current): no drift reported"

# Given the network prefix is malformed
# When configure runs
# Then the whitelist is untouched, a warning names the key and the fix, and the /12 is never written
for bad_prefix in "172.29" "172.29.5.0" "172.29.999" "a.b.c" "١٧٢.28.0"; do
    QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true MEDIASTACK_NETWORK_PREFIX="$bad_prefix" _run_whitelist_case
    assert_eq "absent" "$(_logged_whitelist)" "whitelist (prefix '$bad_prefix'): fails closed, payload omits whitelist"
    assert_contains "$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")" "MEDIASTACK_NETWORK_PREFIX='$bad_prefix' is not a three-number prefix like 172.28.0 - fix or remove it in .env" "whitelist (prefix '$bad_prefix'): warns, naming the key and the fix"
done

# Given the network prefix is unset or empty, as docker-compose.yml allows (it defaults to 172.28.0)
# When configure runs
# Then the /32s use compose's default addresses, never a refusal
_saved_prefix="$MEDIASTACK_NETWORK_PREFIX"
unset MEDIASTACK_NETWORK_PREFIX
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true _run_whitelist_case
assert_eq "172.28.0.22/32, 172.28.0.23/32, 172.28.0.40/32|True" "$(_logged_whitelist)" "whitelist (prefix unset): uses compose's 172.28.0 default"
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true MEDIASTACK_NETWORK_PREFIX="" _run_whitelist_case
assert_eq "172.28.0.22/32, 172.28.0.23/32, 172.28.0.40/32|True" "$(_logged_whitelist)" "whitelist (prefix empty): uses compose's 172.28.0 default"
MEDIASTACK_NETWORK_PREFIX="$_saved_prefix"

# Given the live preferences cannot be read
# When configure runs
# Then the whitelist is untouched and a warning is logged
QBT_LIVE_PREFS_FAIL=1 _run_whitelist_case
assert_eq "absent" "$(_logged_whitelist)" "whitelist (unreadable prefs): fails closed"
assert_contains "$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")" "Could not read qBittorrent preferences" "whitelist (unreadable prefs): warns"

# Given setPreferences fails while the legacy /12 is live
# When configure runs
# Then a warning is logged and the run does not claim the whitelist was narrowed
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true QBT_FAIL_SETPREFS=1 _run_whitelist_case
assert_contains "$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")" "auth whitelist not narrowed" "whitelist (setPreferences fails): warns"
assert_not_contains "$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")" "narrowed" "whitelist (setPreferences fails): no narrowed log_ok"

# --- Day-2 narrowing (qbt_narrow_legacy_whitelist) ---------------------------
# Same live-qBittorrent fake as above. The action must change ONLY the exact
# legacy /12 and must never send any other preference.

# Prints the number of setPreferences calls in CURL_LOG.
_set_prefs_calls() { grep -c '/api/v2/app/setPreferences' "$CURL_LOG" || true; }

# Runs the narrowing with a clean slate; sets NARROW_RC.
_run_narrow_case() {
    : >"$CURL_LOG"
    LOG_OK_MESSAGES=()
    LOG_WARN_MESSAGES=()
    LOG_DRIFT_MESSAGES=()
    NARROW_RC=0
    qbt_narrow_legacy_whitelist >/dev/null || NARROW_RC=$?
}

# Given MediaStack's legacy 172.16.0.0/12 enabled
# When the day-2 narrowing runs
# Then only the whitelist keys are sent, narrowed to the caller /32s, and it succeeds
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true _run_narrow_case
assert_eq "0" "$NARROW_RC" "narrow (legacy /12): succeeds"
assert_eq "$WANTED_WL|True" "$(_logged_whitelist)" "narrow (legacy /12): whitelist is the caller /32s"
assert_contains "$(grep setPreferences "$CURL_LOG")" 'json={"bypass_auth_subnet_whitelist": "172.29.5.22/32, 172.29.5.23/32, 172.29.5.40/32", "bypass_auth_subnet_whitelist_enabled": true}' "narrow (legacy /12): payload holds nothing but the whitelist keys"
assert_contains "$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")" "narrowed from 172.16.0.0/12" "narrow (legacy /12): log_ok names the change"

# Given a whitelist the user set
# When the day-2 narrowing runs
# Then nothing is sent, drift is logged, and it still succeeds
QBT_LIVE_WHITELIST='10.0.0.0/8' QBT_LIVE_ENABLED=true _run_narrow_case
assert_eq "0" "$NARROW_RC" "narrow (user value): succeeds"
assert_eq "0" "$(_set_prefs_calls)" "narrow (user value): setPreferences is never called"
assert_contains "$(printf '%s\n' "${LOG_DRIFT_MESSAGES[@]}")" "changed outside MediaStack" "narrow (user value): log_drift emitted"

# Given a user list that merely contains the legacy /12 next to another entry
# When the day-2 narrowing runs
# Then it is user state and is left alone
QBT_LIVE_WHITELIST='172.16.0.0/12, 10.0.0.0/8' QBT_LIVE_ENABLED=true _run_narrow_case
assert_eq "0" "$(_set_prefs_calls)" "narrow (/12 plus another entry): not rewritten"
assert_eq "1" "${#LOG_DRIFT_MESSAGES[@]}" "narrow (/12 plus another entry): drift reported"

# Given the whitelist is already the caller list
# When the day-2 narrowing runs
# Then nothing is sent and nothing is reported
QBT_LIVE_WHITELIST="$WANTED_WL" QBT_LIVE_ENABLED=true _run_narrow_case
assert_eq "0" "$NARROW_RC" "narrow (already current): succeeds"
assert_eq "0" "$(_set_prefs_calls)" "narrow (already current): setPreferences is never called"
assert_eq "0" "${#LOG_DRIFT_MESSAGES[@]}" "narrow (already current): no drift"

# Given setPreferences fails while the legacy /12 is live
# When the day-2 narrowing runs
# Then it returns non-zero and does not claim success
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true QBT_FAIL_SETPREFS=1 _run_narrow_case
assert_eq "1" "$NARROW_RC" "narrow (setPreferences fails): returns non-zero"
assert_not_contains "$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")" "narrowed" "narrow (setPreferences fails): no narrowed log_ok"
assert_contains "$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")" "Failed to narrow" "narrow (setPreferences fails): warns"

# Given the live preferences cannot be read
# When the day-2 narrowing runs
# Then it returns non-zero and sends nothing
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true QBT_LIVE_PREFS_FAIL=1 _run_narrow_case
assert_eq "1" "$NARROW_RC" "narrow (unreadable prefs): returns non-zero"
assert_eq "0" "$(_set_prefs_calls)" "narrow (unreadable prefs): setPreferences is never called"

# Given the network prefix is malformed
# When the day-2 narrowing runs
# Then it fails closed: non-zero, no API call that could write
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true MEDIASTACK_NETWORK_PREFIX="172.29" _run_narrow_case
assert_eq "1" "$NARROW_RC" "narrow (bad prefix): returns non-zero"
assert_eq "0" "$(_set_prefs_calls)" "narrow (bad prefix): setPreferences is never called"
assert_contains "$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")" "MEDIASTACK_NETWORK_PREFIX='172.29' is not a three-number prefix like 172.28.0 - fix or remove it in .env" "narrow (bad prefix): the warning names the key and the fix"

# Given the network prefix is unset, as docker-compose.yml allows (it defaults to 172.28.0)
# When the day-2 narrowing runs
# Then the /32s are the containers' real default addresses and it succeeds
_saved_prefix="$MEDIASTACK_NETWORK_PREFIX"
unset MEDIASTACK_NETWORK_PREFIX
QBT_LIVE_WHITELIST='172.16.0.0/12' QBT_LIVE_ENABLED=true _run_narrow_case
MEDIASTACK_NETWORK_PREFIX="$_saved_prefix"
assert_eq "0" "$NARROW_RC" "narrow (prefix unset): succeeds"
assert_eq "172.28.0.22/32, 172.28.0.23/32, 172.28.0.40/32|True" "$(_logged_whitelist)" "narrow (prefix unset): the /32s use compose's 172.28.0 default"

# Given the seeded qBittorrent.conf a fresh install starts from
# When its WebUI auth settings are read
# Then it ships no /12 and no enabled whitelist
SEED_CONF="$REPO_ROOT/config/examples/defaults/qbittorrent/qBittorrent/qBittorrent.conf"
assert_file_not_contains "$SEED_CONF" "172.16.0.0/12" "seed conf: no legacy /12 whitelist"
assert_file_not_contains "$SEED_CONF" "AuthSubnetWhitelistEnabled=true" "seed conf: whitelist not enabled"

scenario_end "$CURRENT_SCENARIO"
summary

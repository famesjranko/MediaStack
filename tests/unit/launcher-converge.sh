#!/usr/bin/env bash
# tests/unit/launcher-converge.sh
#
# The one day-2 action that brings MediaStack's own host and service state up to
# date after a code update (scripts/launcher/converge.sh). Verifies:
#   1. Health & security lists the action and routes it to the handler.
#   2. The main-menu warning and the health check name that exact action
#      instead of the "re-run setup" advice that does nothing on a finished install.
#   3. On a host with a legacy after.rules block and no unit, the real
#      setup_admin_filter installs the unit path and strips the block (fake root).
#   4. ADMIN_PORT_FILTER=false installs nothing, and removes what an earlier
#      run left (a failed removal makes the action fail and is retried).
#   5. A failed filter apply returns non-zero, is reported, keeps the legacy
#      block, and does not stop the qBittorrent step from running.
#   6. The qBittorrent step runs only when the container runs, and its
#      failure makes the action fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-converge"
scenario_begin "$CURRENT_SCENARIO"

ACTION_LABEL="Apply changes from a MediaStack update"

# ---------------------------------------------------------------------------
# 1. Health & security lists the action and dispatches to the handler.
# ---------------------------------------------------------------------------
render_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  clear(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  submenu_health >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$render_out" "$ACTION_LABEL" "health menu: the converge action is listed"

dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  clear(){ :; }
  SEEN=$(mktemp)
  # ui_choose runs in a command substitution, so the visit count lives in a file.
  ui_choose(){
    if [[ -s "$SEEN" ]]; then echo Back; else echo seen > "$SEEN"; echo "Apply changes from a MediaStack update"; fi
  }
  action_converge_mediastack(){ echo DISPATCH_CONVERGE; }
  submenu_health 2>&1
' 2>&1)
assert_contains "$dispatch_out" "DISPATCH_CONVERGE" "health menu: choosing the action runs the handler"

# ---------------------------------------------------------------------------
# 2. The warning and the health remedy name the action.
# ---------------------------------------------------------------------------
warn_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  launcher_is_installed(){ return 0; }
  health_docker_user_restrict(){ echo "fail|Admin-port filter unit MISSING - Docker cannot start"; }
  launcher_admin_filter_warning 2>&1
' 2>&1)
assert_contains "$warn_out" "Admin-port filter NOT active" "warning: shown when the filter is not active"
assert_contains "$warn_out" "$ACTION_LABEL" "warning: names the converge action"
assert_not_contains "$warn_out" "re-run setup" "warning: no 're-run setup' advice"

health_tmp=$(mktemp -d)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$health_tmp" "$TMP_DIR"' EXIT
missing_out=$(REPO_ROOT="$REPO_ROOT" HT="$health_tmp" bash -c '
  source "$REPO_ROOT/scripts/lib/common.sh"
  source "$REPO_ROOT/scripts/lib/health.sh"
  unset ADMIN_PORT_FILTER
  MEDIASTACK_ADMIN_FILTER_DROPIN="$HT/none.conf" health_docker_user_restrict
  touch "$HT/dropin.conf"
  MEDIASTACK_ADMIN_FILTER_DROPIN="$HT/dropin.conf" MEDIASTACK_ADMIN_FILTER_UNIT="$HT/none.service" health_docker_user_restrict
' 2>&1)
assert_eq "2" "$(grep -c "$ACTION_LABEL" <<<"$missing_out")" "health: drop-in and unit remedies both name the converge action"
assert_not_contains "$missing_out" "re-run setup" "health: no 're-run setup' remedy"

# ---------------------------------------------------------------------------
# 3-6. converge_mediastack_state against a fake root.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/setup/hardening.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/setup/storage.sh"
# converge.sh loads its helpers from $SCRIPT_DIR, which is the repo root in production.
SCRIPT_DIR="$REPO_ROOT"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/launcher/converge.sh"
set +e

# shellcheck disable=SC2034  # read by the ledger helpers in scripts/setup/hardening.sh
MEDIASTACK_STATE_FILE="$TMP_DIR/no-ledger"
MEDIASTACK_UFW_AFTER_RULES="$TMP_DIR/after.rules"
MEDIASTACK_UFW_AFTER6_RULES="$TMP_DIR/after6.rules"
MEDIASTACK_UFW_AFTER_INIT="$TMP_DIR/after.init"
MEDIASTACK_ADMIN_FILTER_SCRIPT="$TMP_DIR/root/mediastack-admin-filter"
MEDIASTACK_ADMIN_FILTER_UNIT="$TMP_DIR/root/mediastack-admin-filter.service"
MEDIASTACK_ADMIN_FILTER_DROPIN="$TMP_DIR/root/docker.service.d/mediastack-admin-filter.conf"
APPLY_LOG="$TMP_DIR/apply.log"
FAIL_APPLY=0
FAIL_RELOAD=0
QBT_CALLS="$TMP_DIR/qbt.calls"
QBT_RC=0
QBT_RUNNING=false
LOGGED=""

# sudo runs file commands for real inside the fake root. The generated apply
# script is a recorder: its iptables behaviour is covered in hardening/admin-filter.sh.
sudo() {
    [[ "$1" == "-n" ]] && shift
    case "$1" in
        "$MEDIASTACK_ADMIN_FILTER_SCRIPT")
            echo "$*" >>"$APPLY_LOG"
            ((FAIL_APPLY == 0))
            ;;
        systemctl)
            case "$2" in
                is-active) return 1 ;;
                daemon-reload) ((FAIL_RELOAD == 0)) ;;
                *) return 0 ;;
            esac
            ;;
        # No live jump or chain: the chain teardown must never reach a real iptables.
        iptables | ip6tables) return 1 ;;
        *) command "$@" ;;
    esac
}
docker() { # docker inspect --format ... qbittorrent
    case "$*" in
        *"{{.State.Running}}"*) echo "$QBT_RUNNING" ;;
        *"State.Health"*) echo healthy ;;
    esac
}
sleep() { :; }
# No UFW on this host: both UFW steps return early instead of reaching the ufw of whatever
# machine runs the test (their behaviour is covered in hardening/firewall.sh and wireguard-ufw.sh).
ufw_installed() { return 1; }
qbt_narrow_legacy_whitelist() {
    echo called >>"$QBT_CALLS"
    return "$QBT_RC"
}
# The Beszel step is covered in beszel-system.sh; here it only must not touch a hub.
beszel_converge_local_system() { return 0; }
# The NAS watchdog step (covered further down) asks systemctl whether the unit
# exists; the install is a recorder that creates it only when INSTALL_CREATES=1.
WD_UNIT_PRESENT=1 INSTALL_CREATES=1 WD_CALLS="$TMP_DIR/wd.calls"
systemctl() { [[ "$1" != cat ]] || ((WD_UNIT_PRESENT == 1)); }
storage_install_watchdog() {
    echo install >>"$WD_CALLS"
    ((INSTALL_CREATES == 1)) && WD_UNIT_PRESENT=1
    return 0
}
# Capture what the user would see instead of printing it.
log_ok() { LOGGED+="OK: $1"$'\n'; }
log_info() { LOGGED+="INFO: $1"$'\n'; }
log_warn() { LOGGED+="WARN: $1"$'\n'; }
log_skip() { LOGGED+="SKIP: $1"$'\n'; }
log_error() { LOGGED+="ERROR: $1"$'\n'; }

legacy_block() {
    printf '\n# MEDIASTACK-DOCKER-RULES - restrict Docker management ports to LAN\n*filter\n'
    printf ':MEDIASTACK-DOCKER-RESTRICT - [0:0]\n\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -s 10.0.0.0/8 -j RETURN\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -j RETURN\n\nCOMMIT\n# END MEDIASTACK-DOCKER-RULES\n'
}
user_text() { printf '*filter\n:ufw-user-input - [0:0]\nCOMMIT\n'; }

# An existing install after a code update: legacy block, no unit path.
reset_host() {
    rm -rf "$TMP_DIR/root" "$APPLY_LOG" "$QBT_CALLS"
    {
        user_text
        legacy_block
    } >"$MEDIASTACK_UFW_AFTER_RULES"
    {
        user_text
        legacy_block
    } >"$MEDIASTACK_UFW_AFTER6_RULES"
    user_text >"$TMP_DIR/user.rules"
    cp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/legacy.rules"
    rm -f "$MEDIASTACK_UFW_AFTER_INIT"
    FAIL_APPLY=0 FAIL_RELOAD=0 QBT_RC=0 QBT_RUNNING=false LOGGED=""
    unset ADMIN_PORT_FILTER
}

# Given an existing install with a legacy after.rules block and no unit
# When the converge action runs
# Then the unit path is installed and both blocks are stripped
reset_host
converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (legacy host): succeeds"
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_DROPIN" "Requires=mediastack-admin-filter.service" "converge (legacy host): the docker.service drop-in is installed"
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_UNIT" "MEDIASTACK-ADMIN-FILTER" "converge (legacy host): the unit is installed"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/user.rules" 2>&1)" "converge (legacy host): after.rules is the user's text again"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER6_RULES" "$TMP_DIR/user.rules" 2>&1)" "converge (legacy host): after6.rules is the user's text again"

# Given the same host after it converged
# When the action runs again
# Then it still succeeds and leaves the files as they are
before=$(cat "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_UFW_AFTER_RULES")
converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (second run): succeeds"
assert_eq "$before" "$(cat "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_UFW_AFTER_RULES")" "converge (second run): nothing changes"

# Given the user turned the admin-port filter off and nothing of MediaStack's is installed
# When the converge action runs
# Then no unit path is installed and the user's after.rules is not edited
reset_host
user_text >"$MEDIASTACK_UFW_AFTER_RULES"
user_text >"$MEDIASTACK_UFW_AFTER6_RULES"
ADMIN_PORT_FILTER=false converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (filter off): succeeds"
if [[ ! -e "$MEDIASTACK_ADMIN_FILTER_UNIT" && ! -e "$MEDIASTACK_ADMIN_FILTER_DROPIN" && ! -e "$MEDIASTACK_ADMIN_FILTER_SCRIPT" ]]; then
    pass "converge (filter off): no unit, drop-in or script is installed"
else
    fail "converge (filter off): no unit, drop-in or script is installed" "$(find "$TMP_DIR/root" -type f 2>&1)"
fi
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/user.rules" 2>&1)" "converge (filter off): after.rules is left alone"

# Given the user turned the filter off, a legacy after.rules block is still there and the unit path was left by an earlier run
# When the converge action runs
# Then the removal runs: the unit path and the legacy blocks go, and it succeeds
reset_host
converge_mediastack_state >/dev/null
{
    user_text
    legacy_block
} >"$MEDIASTACK_UFW_AFTER_RULES"
ADMIN_PORT_FILTER=false converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (filter off, leftovers): succeeds"
if [[ ! -e "$MEDIASTACK_ADMIN_FILTER_UNIT" && ! -e "$MEDIASTACK_ADMIN_FILTER_DROPIN" && ! -e "$MEDIASTACK_ADMIN_FILTER_SCRIPT" ]]; then
    pass "converge (filter off, leftovers): the unit, drop-in and script are removed"
else
    fail "converge (filter off, leftovers): the unit, drop-in and script are removed" "$(find "$TMP_DIR/root" -type f 2>&1)"
fi
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/user.rules" 2>&1)" "converge (filter off, leftovers): the legacy block is stripped"

# Given the user turned the filter off and the removal fails (systemd cannot reload)
# When the converge action runs, and again once systemd works
# Then the first run fails and says so, keeps the unit, and the second run finishes the removal
reset_host
converge_mediastack_state >/dev/null
FAIL_RELOAD=1 ADMIN_PORT_FILTER=false converge_mediastack_state >/dev/null
rc=$?
assert_eq "1" "$rc" "converge (filter off, removal fails): returns non-zero"
assert_contains "$LOGGED" "ERROR: The admin-port filter is not converged" "converge (filter off, removal fails): the failure is reported"
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_UNIT" "MEDIASTACK-ADMIN-FILTER" "converge (filter off, removal fails): the unit is kept for the retry"
ADMIN_PORT_FILTER=false converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (filter off, retry): succeeds"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "converge (filter off, retry): the unit is removed"

# Given the filter cannot be applied
# When the converge action runs
# Then it returns non-zero, reports it, keeps the legacy block, and still checks qBittorrent
reset_host
FAIL_APPLY=1 QBT_RUNNING=true converge_mediastack_state >/dev/null
rc=$?
assert_eq "1" "$rc" "converge (apply fails): returns non-zero"
assert_contains "$LOGGED" "ERROR: The admin-port filter is not converged" "converge (apply fails): the failure is reported"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/legacy.rules" 2>&1)" "converge (apply fails): the legacy block stays in place"
assert_eq "1" "$(wc -l <"$QBT_CALLS" 2>/dev/null || echo 0)" "converge (apply fails): the qBittorrent step still runs"

# Given qBittorrent is running and its narrowing fails
# When the converge action runs
# Then the action returns non-zero even though the filter converged
reset_host
QBT_RUNNING=true QBT_RC=1 converge_mediastack_state >/dev/null
rc=$?
assert_eq "1" "$rc" "converge (qBittorrent fails): returns non-zero"
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_DROPIN" "Requires=mediastack-admin-filter.service" "converge (qBittorrent fails): the filter is still installed"

# Given qBittorrent is not running
# When the converge action runs
# Then the whitelist step is skipped with a hint to run it again, and the action succeeds
reset_host
converge_mediastack_state >/dev/null
rc=$?
assert_eq "0" "$rc" "converge (qBittorrent stopped): succeeds"
if [[ ! -e "$QBT_CALLS" ]]; then
    pass "converge (qBittorrent stopped): the whitelist step is not attempted"
else
    fail "converge (qBittorrent stopped): the whitelist step is not attempted"
fi
assert_contains "$LOGGED" "qBittorrent is not running" "converge (qBittorrent stopped): the user is told"

# Given a NAS install that wants the watchdog but whose unit is missing
# When the converge action runs
# Then the watchdog is installed and the action succeeds
reset_host
rm -f "$WD_CALLS"
STORAGE_MODE=nas STORAGE_WATCHDOG=true WD_UNIT_PRESENT=0 INSTALL_CREATES=1
converge_mediastack_state >/dev/null
assert_eq "0" "$?" "converge (NAS, watchdog missing): succeeds"
assert_eq "install" "$(cat "$WD_CALLS" 2>/dev/null)" "converge (NAS, watchdog missing): the watchdog is installed"

# Given the same host where the install skips itself (for example no visudo)
# When the converge action runs
# Then the action fails and says nothing will remount the NAS
reset_host
rm -f "$WD_CALLS"
WD_UNIT_PRESENT=0 INSTALL_CREATES=0
converge_mediastack_state >/dev/null
assert_eq "1" "$?" "converge (NAS, watchdog install skipped): returns non-zero"
assert_contains "$LOGGED" "ERROR: The NAS storage watchdog is still not installed" "converge (NAS, watchdog install skipped): the user is told"

# Given a NAS install whose watchdog unit is already there
# When the converge action runs
# Then nothing is reinstalled
reset_host
rm -f "$WD_CALLS"
WD_UNIT_PRESENT=1 INSTALL_CREATES=1
converge_mediastack_state >/dev/null
assert_eq "0" "$?" "converge (NAS, watchdog present): succeeds"
assert_eq "no" "$([[ -e "$WD_CALLS" ]] && echo yes || echo no)" "converge (NAS, watchdog present): no reinstall"

# Given a NAS install with the watchdog switched off, and a local-storage install
# When the converge action runs
# Then no watchdog is installed in either case
for case_env in "nas:false" "local:true"; do
    reset_host
    rm -f "$WD_CALLS"
    # shellcheck disable=SC2034 # consumed by storage_is_nas/storage_watchdog_enabled in storage/core.sh
    STORAGE_MODE="${case_env%%:*}" STORAGE_WATCHDOG="${case_env##*:}"
    WD_UNIT_PRESENT=0 INSTALL_CREATES=1
    converge_mediastack_state >/dev/null
    assert_eq "no" "$([[ -e "$WD_CALLS" ]] && echo yes || echo no)" "converge (${case_env}): no watchdog installed"
done
unset STORAGE_MODE STORAGE_WATCHDOG

scenario_end "$CURRENT_SCENARIO"
summary

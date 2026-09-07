#!/usr/bin/env bash
# tests/unit/fail2ban-watcher.sh
#
# Pure-bash unit tests for the fail2ban reload-watcher systemd unit content
# (scripts/setup/fail2ban.sh). Pins the directives that carry the
# design intent — daemon resilience and the 6h fallback floor — so an edit can't
# silently drop them. systemd *validity* is checked separately with
# `systemd-analyze verify`; the install/uninstall side effects are fail-soft and
# exercised live in the DinD/host paths.
set -uo pipefail

SCRIPT_DIR_T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR_T/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="fail2ban-watcher"
scenario_begin "$CURRENT_SCENARIO"

export SCRIPT_DIR="$REPO_ROOT"
# shellcheck source=../../scripts/setup/fail2ban.sh
source "$REPO_ROOT/scripts/setup/fail2ban.sh"

# --- watcher daemon unit: must be un-killable-by-systemd (issue: silent death) --
watcher=$(f2b_watcher_unit_content msuser msgrp /x/watcher.sh)
assert_contains "$watcher" "StartLimitIntervalSec=0" "watcher: rate-limiter disabled so it never permanently fails"
assert_contains "$watcher" "Restart=always" "watcher: always restarts"
assert_contains "$watcher" "ExecStart=/x/watcher.sh" "watcher: runs the watcher script"
assert_contains "$watcher" "User=msuser" "watcher: runs as the install user (docker group)"

# --- fallback one-shot: an independent `fail2ban-client reload` ----------------
svc=$(f2b_fallback_service_content msuser msgrp)
assert_contains "$svc" "Type=oneshot" "fallback service: one-shot"
assert_contains "$svc" "fail2ban-client reload" "fallback service: reloads fail2ban"

# --- fallback timer: the 6h floor if the watcher ever dies ---------------------
timer=$(f2b_fallback_timer_content)
assert_contains "$timer" "OnUnitActiveSec=6h" "fallback timer: fires every 6h"
assert_contains "$timer" "WantedBy=timers.target" "fallback timer: installs as a timer"

# --- a failed fallback-unit write must not be reported as an enabled timer -----
# The fallback is best-effort, but swallowing the write rc left setup enabling
# and restarting units that were never written, and logging success for them.
_f2b_tmp=$(mktemp -d)
mkdir -p "$_f2b_tmp/scripts"
printf '#!/usr/bin/env bash\n' >"$_f2b_tmp/scripts/fail2ban-reload-watcher.sh"
chmod +x "$_f2b_tmp/scripts/fail2ban-reload-watcher.sh"
SCRIPT_DIR="$_f2b_tmp"
F2B_SYSTEMCTL_LOG="$_f2b_tmp/systemctl.log"
: >"$F2B_SYSTEMCTL_LOG"
F2B_WARNINGS=""
inotifywait() { :; }
log_info() { :; }
log_ok() { :; }
log_warn() { F2B_WARNINGS+="$*"$'\n'; }
sudo() {
    case "${1:-}" in
        tee)
            cat >/dev/null
            # Only the fallback service unit fails to write.
            [[ "${2:-}" == "$MEDIASTACK_F2B_FALLBACK_SERVICE" ]] && return 1
            return 0
            ;;
        systemctl)
            shift
            printf '%s\n' "$*" >>"$F2B_SYSTEMCTL_LOG"
            return 0
            ;;
    esac
    return 0
}
f2b_install_reload_watcher
_f2b_systemctl=$(cat "$F2B_SYSTEMCTL_LOG")
assert_contains "$F2B_WARNINGS" "Could not write fail2ban fallback reload service unit" \
    "fallback write failure: warns instead of being swallowed"
assert_contains "$_f2b_systemctl" "restart mediastack-fail2ban-reload.service" \
    "fallback write failure: the primary watcher is still started"
if [[ "$_f2b_systemctl" == *"fail2ban-reload-fallback.timer"* ]]; then
    fail "fallback write failure: does not enable/restart a unit it never wrote"
else
    pass "fallback write failure: does not enable/restart a unit it never wrote"
fi
unset -f sudo inotifywait log_info log_ok log_warn
unset F2B_WARNINGS F2B_SYSTEMCTL_LOG
rm -rf "$_f2b_tmp"
SCRIPT_DIR="$REPO_ROOT"

# --- uninstall is a clean no-op (rc 0) when nothing was installed --------------
if command -v systemctl >/dev/null 2>&1; then
    sudo() { case "${1:-}" in test) return 1 ;; *) return 0 ;; esac } # every unit file "absent"
    f2b_uninstall_reload_watcher
    assert_eq 0 $? "uninstall: clean no-op when the units were never installed"
    unset -f sudo
else
    pass "uninstall: skipped (no systemctl on this host)"
fi

scenario_end "$CURRENT_SCENARIO"
summary

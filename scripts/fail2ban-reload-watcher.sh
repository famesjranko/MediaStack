#!/usr/bin/env bash
# =============================================================================
# MediaStack fail2ban log-rotation reload watcher
# =============================================================================
# fail2ban resolves each jail's logpath glob to concrete files only at jail
# start / reload. Jellyfin (Serilog) and Seerr (winston) roll to a NEW
# date-stamped file (log_YYYYMMDD.log) every day, so after midnight the live
# jail keeps tailing yesterday's file and silently stops matching — brute-force
# bans stop firing — until the next reload (issue #291).
#
# This watcher reloads fail2ban the moment a service rolls to a new log file, so
# the globs re-resolve and protection never lapses. It watches create/rename
# events ONLY (never writes), so a busy log does not trigger a reload storm.
# Installed as mediastack-fail2ban-reload.service by scripts/setup/fail2ban.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

log() { echo "$(date '+%F %T') [fail2ban-reload-watcher] $*"; }

# The service log dirs bind-mounted into the fail2ban container
# (docker-compose.yml). Watching the host-side bind source sees the container's
# writes (same inode). A new dated file appearing here = a rotation.
WATCH_DIRS=(
    "$SCRIPT_DIR/config/jellyfin/log"
    "$SCRIPT_DIR/config/seerr/logs"
    "$SCRIPT_DIR/config/npm/data/logs"
)

# Quiet-period debounce: after a create, wait this many seconds of no further
# events before reloading. Coalesces a burst of creates (e.g. several NPM
# proxy-host logs at once) into one reload, and gives the new file a moment to
# exist before the glob re-resolves. Overridable for tests.
SETTLE="${F2B_WATCH_SETTLE:-8}"

reload_fail2ban() {
    if docker exec fail2ban fail2ban-client reload >/dev/null 2>&1; then
        log "fail2ban reloaded (log rotation detected)"
    else
        log "fail2ban reload skipped (container not running)"
    fi
}

f2b_watcher_main() {
    # 1. Tool present? Exit WITHOUT reloading if not. A reconcile reload before
    #    this check, under systemd Restart=always, would loop a reload every
    #    RestartSec forever. Base packages install inotify-tools; this guards a
    #    manual/edge host.
    if ! command -v inotifywait >/dev/null 2>&1; then
        log "inotifywait not found (install inotify-tools); watcher disabled"
        exit 0
    fi

    # 2. Wait until every watch dir exists — a single inotifywait over multiple
    #    dirs aborts if ANY is unwatchable, which under Restart=always would
    #    spin. Steady state: create_config_dirs pre-creates them.
    local d
    for d in "${WATCH_DIRS[@]}"; do
        while [[ ! -d "$d" ]]; do
            log "waiting for $d to exist..."
            sleep 5
        done
    done

    # 3. One reconcile reload on start — covers a rollover that happened while
    #    the watcher was down.
    reload_fail2ban

    # 4. Watch for new/renamed files only (never 'modify' → no per-line storm).
    #    Trailing-edge debounce: each event resets a SETTLE-second quiet timer;
    #    when the burst goes quiet we reload once. An event arriving mid-window
    #    resets the timer rather than being dropped, so no rolled file is ever
    #    left unwatched.
    log "watching ${WATCH_DIRS[*]} for log rotation"
    inotifywait -m -q -e create -e moved_to "${WATCH_DIRS[@]}" | while read -r _; do
        while read -r -t "$SETTLE" _; do :; done
        reload_fail2ban
    done
}

# Guard so unit tests can source the helpers without launching the watcher.
if [[ "${MEDIASTACK_F2B_WATCHER_SOURCE_ONLY:-0}" != "1" ]]; then
    f2b_watcher_main
fi

# =============================================================================
# MediaStack Setup — fail2ban log-rotation reload watcher install/uninstall
# =============================================================================
# Owns three host systemd units that keep fail2ban following rotated logs so the
# jail globs never silently go stale (issue #291):
#   1. mediastack-fail2ban-reload.service        — the inotify watcher daemon
#      (scripts/fail2ban-reload-watcher.sh); reloads fail2ban within seconds of a
#      service rolling to a new date-stamped log file. Primary, near-zero gap.
#   2. mediastack-fail2ban-reload-fallback.service — a one-shot `fail2ban-client
#      reload`, triggered by:
#   3. mediastack-fail2ban-reload-fallback.timer   — every 6h. A belt-and-braces
#      floor so that even if the watcher daemon dies, protection lapses for at
#      most the timer interval instead of "until someone notices".
#
# Sourced by setup.sh (Stage 2 install), mediastack (day-2 remote recovery), and
# hardening.sh (uninstall). Sources common.sh itself (invariant #11); re-source
# safe (plain function/var definitions).
_F2B_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_F2B_LIB_DIR/../lib/common.sh"

# Host-artefact paths this module owns — single source of truth so install and
# uninstall can never drift. Plain assignment: re-source safe.
MEDIASTACK_F2B_WATCHER_UNIT="/etc/systemd/system/mediastack-fail2ban-reload.service"
MEDIASTACK_F2B_FALLBACK_SERVICE="/etc/systemd/system/mediastack-fail2ban-reload-fallback.service"
MEDIASTACK_F2B_FALLBACK_TIMER="/etc/systemd/system/mediastack-fail2ban-reload-fallback.timer"

f2b_watcher_unit_content() {
    local install_user="$1" install_group="$2" script="$3"
    # StartLimitIntervalSec=0 disables systemd's start-rate limiter entirely, so
    # Restart=always retries FOREVER and the watcher can never end up permanently
    # `failed` (the default limiter — 5 starts/10s — would otherwise give up and
    # leave protection silently unwatched until a reboot). RestartSec=30 keeps a
    # broken-host retry loop light.
    cat <<EOF
[Unit]
Description=MediaStack fail2ban log-rotation reload watcher
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$install_user
Group=$install_group
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

f2b_fallback_service_content() {
    local install_user="$1" install_group="$2"
    cat <<EOF
[Unit]
Description=MediaStack fail2ban periodic reload (rotation-watcher fallback)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=$install_user
Group=$install_group
ExecStart=/bin/sh -c 'docker exec fail2ban fail2ban-client reload || true'
EOF
}

f2b_fallback_timer_content() {
    cat <<'EOF'
[Unit]
Description=MediaStack fail2ban periodic reload every 6h (rotation-watcher fallback)

[Timer]
OnBootSec=6h
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
EOF
}

# Install (or refresh) the watcher daemon + the 6h fallback timer. Gated by the
# caller on `container_running fail2ban` (fail2ban only runs on remote-access
# installs). Fail-soft everywhere: a missing tool / no sudo / systemctl error
# warns and returns 0 — never hard-fails setup, never hangs a non-TTY path.
f2b_install_reload_watcher() {
    command -v systemctl >/dev/null 2>&1 || {
        log_warn "systemd not available; skipping fail2ban reload watcher"
        return 0
    }
    local script="$SCRIPT_DIR/scripts/fail2ban-reload-watcher.sh"
    if [[ ! -x "$script" ]]; then
        log_warn "fail2ban reload watcher script missing or not executable: $script"
        return 0
    fi
    # Refuse to install a unit that could never work: without inotifywait the
    # watcher exits immediately and Restart=always would churn it.
    if ! command -v inotifywait >/dev/null 2>&1; then
        log_warn "inotify-tools (inotifywait) not installed; not installing fail2ban reload watcher"
        return 0
    fi
    # Non-TTY safe: only proceed if sudo is already primed. The recovery path
    # primes it immediately before; in the main flow it is primed upstream but the
    # timestamp could lapse before this late Stage-2 point on a no-NOPASSWD host —
    # in that case skip fail-soft (a re-run reinstalls, and the day-2 "jellyfin
    # watch" metric flags the missing watcher) rather than risk an interactive prompt.
    if ! sudo -n true 2>/dev/null; then
        log_warn "passwordless sudo unavailable; skipping fail2ban reload watcher install (re-run setup to retry)"
        return 0
    fi

    local install_user install_group
    install_user="$(id -un)"
    install_group="$(id -gn)"

    log_info "Installing fail2ban log-rotation reload watcher (+ 6h fallback timer)..."
    if ! f2b_watcher_unit_content "$install_user" "$install_group" "$script" \
            | sudo tee "$MEDIASTACK_F2B_WATCHER_UNIT" >/dev/null; then
        log_warn "Could not write fail2ban reload watcher unit; skipping"
        return 0
    fi
    f2b_fallback_service_content "$install_user" "$install_group" \
        | sudo tee "$MEDIASTACK_F2B_FALLBACK_SERVICE" >/dev/null || true
    f2b_fallback_timer_content | sudo tee "$MEDIASTACK_F2B_FALLBACK_TIMER" >/dev/null || true

    sudo systemctl daemon-reload || { log_warn "systemd daemon-reload failed"; return 0; }
    # enable + restart (NOT enable --now): --now won't restart an already-running
    # old unit, so a unit-content change on re-run wouldn't take effect.
    sudo systemctl enable mediastack-fail2ban-reload.service >/dev/null 2>&1 \
        || log_warn "Could not enable fail2ban reload watcher"
    sudo systemctl restart mediastack-fail2ban-reload.service >/dev/null 2>&1 \
        && log_ok "fail2ban log-rotation reload watcher enabled" \
        || log_warn "Could not start fail2ban reload watcher"
    # The fallback one-shot is fired by its timer, not enabled directly.
    sudo systemctl enable mediastack-fail2ban-reload-fallback.timer >/dev/null 2>&1 \
        || log_warn "Could not enable fail2ban fallback reload timer"
    sudo systemctl restart mediastack-fail2ban-reload-fallback.timer >/dev/null 2>&1 \
        && log_ok "fail2ban 6h fallback reload timer enabled" \
        || log_warn "Could not start fail2ban fallback reload timer"
}

# Tear down the three units. Each block guarded on unit presence (avoids needless
# sudo churn on LAN-only installs where they were never installed). Mirrors
# storage_uninstall_watchdog: no daemon-reload here — the uninstall caller keeps
# its single trailing reload. Returns non-zero if any removal fails.
f2b_uninstall_reload_watcher() {
    command -v systemctl >/dev/null 2>&1 || return 0
    # Non-TTY safe: mirror f2b_install_reload_watcher — only proceed when sudo is
    # already primed. The LAN-only re-run path reaches here with a possibly-lapsed
    # cache; skip fail-soft rather than risk an interactive prompt.
    if ! sudo -n true 2>/dev/null; then
        log_warn "passwordless sudo unavailable; skipping fail2ban reload watcher cleanup"
        return 0
    fi
    local rc=0
    if sudo test -f "$MEDIASTACK_F2B_FALLBACK_TIMER"; then
        sudo systemctl stop mediastack-fail2ban-reload-fallback.timer 2>/dev/null || rc=1
        sudo systemctl disable mediastack-fail2ban-reload-fallback.timer 2>/dev/null || rc=1
        sudo rm -f "$MEDIASTACK_F2B_FALLBACK_TIMER" || rc=1
    fi
    if sudo test -f "$MEDIASTACK_F2B_FALLBACK_SERVICE"; then
        sudo rm -f "$MEDIASTACK_F2B_FALLBACK_SERVICE" || rc=1
    fi
    if sudo test -f "$MEDIASTACK_F2B_WATCHER_UNIT"; then
        sudo systemctl stop mediastack-fail2ban-reload.service 2>/dev/null || rc=1
        sudo systemctl disable mediastack-fail2ban-reload.service 2>/dev/null || rc=1
        sudo rm -f "$MEDIASTACK_F2B_WATCHER_UNIT" || rc=1
    fi
    return $rc
}

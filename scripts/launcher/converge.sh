#!/usr/bin/env bash
# Owns: converge_mediastack_state and action_converge_mediastack - the one day-2 action that brings MediaStack's own host and service state up to date after a code update.
# Sources: launcher globals, scripts/setup/hardening.sh, scripts/lib/json.sh, scripts/services/qbittorrent/main.sh and scripts/services/beszel/main.sh (all loaded on demand). scripts/update.sh also sources this file for the pure function.

# Why this exists: a completed install never re-runs setup or configure (the
# existing-install menu ends at "No changes made", and STAGE_1_COMPLETE=1 skips
# configure), so a new release cannot reach the host by itself. Every step below
# changes only a MediaStack artefact and is idempotent:
#   1. The admin-port filter (setup_admin_filter): installs the systemd unit and
#      docker.service drop-in, moves a legacy after.rules/after.init block out,
#      and honours ADMIN_PORT_FILTER=false by removing what is still installed.
#   2. qBittorrent's auth whitelist: narrowed only when it is exactly
#      MediaStack's old 172.16.0.0/12. Any other value is user state and is
#      reported as drift, never rewritten.
#   3. Beszel's hub entry for this host: moved from host.docker.internal:45876
#      to the agent's unix socket only when it is exactly MediaStack's old
#      entry (the agent no longer listens on a TCP port). Anything else is drift.
#   4. The unused UFW rule "MediaStack:Beszel-agent" (45876 from the Docker
#      networks) that earlier releases opened: deleted only when its comment is
#      exactly that one (ufw_remove_legacy_beszel_rule).
#   5. The UFW rule "MediaStack:WireGuard-clients" (allow from the wireguard
#      container's /32): added while the remote profile is enabled and UFW is
#      active, removed otherwise (setup_ufw_wireguard_clients). Existing
#      installs get the rule here.
#   6. The NAS storage watchdog: installed when NAS mode wants it
#      (STORAGE_WATCHDOG not false) and its unit is missing. Installs made before
#      the sbin-aware tool lookup skipped it with only a warning, leaving the NAS
#      unmounted after a reboot with nothing to repair it.
# User choices (UFW, quality, DDNS, ...) are not touched: AGENTS.md's
# "warn on drift, never auto-reconcile" protects user state, not our own files.

# A wanted NAS watchdog that is missing is MediaStack-owned state, so it is installed
# here. storage_install_watchdog returns 0 when it skips (no visudo, odd user name),
# so success is judged by the unit existing afterwards.
converge_storage_watchdog() {
    type storage_install_watchdog &>/dev/null || source "$SCRIPT_DIR/scripts/setup/storage.sh"
    storage_is_nas && storage_watchdog_enabled || return 0
    storage_watchdog_installed && return 0
    log_info "The NAS storage watchdog is wanted but not installed - installing it"
    storage_install_watchdog
    if ! storage_watchdog_installed; then
        log_error "The NAS storage watchdog is still not installed (see above). After a reboot nothing will remount the NAS."
        return 1
    fi
}

# Returns non-zero when any step failed; each step logs its own reason. A failed
# filter apply never hides behind the qBittorrent step: both always run.
converge_mediastack_state() {
    local rc=0
    # admin-filter.sh alone is not enough: health.sh and features.sh source it, and
    # their callers then skip this load, but its path constants (MEDIASTACK_ADMIN_FILTER_*,
    # MEDIASTACK_UFW_AFTER_RULES) and firewall.sh's UFW cleanup come from hardening.sh.
    [[ -v MEDIASTACK_ADMIN_FILTER_DROPIN ]] && type ufw_remove_legacy_beszel_rule &>/dev/null \
        || source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    # The Beszel step parses the hub's replies with json_get/json_path.
    type json_get &>/dev/null || source "$SCRIPT_DIR/scripts/lib/json.sh"
    type qbt_narrow_legacy_whitelist &>/dev/null || source "$SCRIPT_DIR/scripts/services/qbittorrent/main.sh"
    type beszel_converge_local_system &>/dev/null || source "$SCRIPT_DIR/scripts/services/beszel/main.sh"

    if ! setup_admin_filter; then
        log_error "The admin-port filter is not converged. Admin ports may be unfiltered until this succeeds; fix the cause above and run this action again."
        rc=1
    fi

    local running
    running=$(docker inspect --format '{{.State.Running}}' qbittorrent 2>/dev/null || true)
    if [[ "$running" == "true" ]]; then
        # A container recreated a moment ago can still be starting; wait briefly
        # so the login does not fail on a daemon that is not listening yet.
        local health attempt
        for attempt in $(seq 1 30); do
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' qbittorrent 2>/dev/null || true)
            [[ -z "$health" || "$health" == "healthy" ]] && break
            sleep 2
        done
        qbt_narrow_legacy_whitelist || rc=1
    else
        log_skip "qBittorrent is not running - its auth whitelist was not checked; start the stack and run this action again"
    fi

    beszel_converge_local_system || rc=1
    ufw_remove_legacy_beszel_rule || rc=1
    setup_ufw_wireguard_clients || rc=1
    converge_storage_watchdog || rc=1
    return "$rc"
}

# Menu entry: ./mediastack -> Health & security -> "Apply changes from a MediaStack update".
action_converge_mediastack() {
    echo ""
    ui_log info "Bringing the admin-port filter, qBittorrent's auth whitelist and Beszel's system entry up to date, removing MediaStack's unused Beszel UFW rule, converging its WireGuard UFW rule, and installing a missing NAS watchdog (uses sudo)..."
    local rc=0
    converge_mediastack_state || rc=$?
    _show_action_result "$rc" "Apply changes from a MediaStack update"
    launcher_pause_for_menu
}

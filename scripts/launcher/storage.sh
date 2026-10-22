#!/usr/bin/env bash
# Owns: The NAS storage/data-mount day-2 view and re-check action.
# Sources: launcher globals, .env, scripts/lib/ui.sh, storage.sh, and Docker/systemd helpers.

_storage_services_running() {
    local running total=0 up=0 svc
    running="$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null)"
    while read -r svc; do
        [[ -n "$svc" ]] || continue
        total=$((total + 1))
        grep -qx "$svc" <<<"$running" && up=$((up + 1))
    done < <(storage_data_services)
    printf '%s of %s running' "$up" "$total"
}

# disabled | not-installed | stopped | running - what the host really has, so
# the screens never claim a watchdog that does not exist.
_storage_watchdog_state() {
    if ! storage_watchdog_enabled; then
        echo disabled
    elif ! storage_watchdog_installed; then
        echo not-installed
    elif systemctl is-active --quiet mediastack-storage-watchdog.service 2>/dev/null; then
        echo running
    else
        echo stopped
    fi
}

_storage_info() {
    local lines=() src fstype dataline free data watch state sentinel_rc=0
    src="$(storage_expected_source)"
    fstype="$(storage_expected_fstype)"
    lines+=("$(ui_kv 'Storage' 'Network storage (NAS)')")
    lines+=("$(ui_kv 'NAS source' "${src:-unknown}")")

    # Probe the sentinel first and bounded: a hard NFS mount blocks every stat
    # while the server is down, and nothing below may wait on it.
    storage_sentinel_ok || sentinel_rc=$?
    local status
    if ((sentinel_rc == 124)); then
        status="NAS unreachable (no answer within $(storage_probe_timeout)s)"
    elif storage_mount_matches; then
        if ((sentinel_rc == 0)); then
            status="$fstype  (mounted, healthy)"
        else
            status="$fstype  (mounted, verifying…)"
        fi
    elif storage_mountpoint_has_mount; then
        status="WRONG: $(storage_findmnt_source) ($(storage_findmnt_fstype)) — expected $fstype"
    else
        status="not mounted"
    fi
    lines+=("$(ui_kv 'Filesystem' "$status")")

    data="${DATA_DIR:-/data}"
    dataline="$data"
    if ((sentinel_rc == 124)); then
        dataline+=" — unavailable while the NAS is unreachable"
    else
        free=$(storage_bounded "$(storage_probe_timeout)" df -h --output=avail "$data" 2>/dev/null | tail -1 | tr -d ' ')
        [[ -n "$free" ]] && dataline+=" — ${free} free"
    fi
    lines+=("$(ui_kv 'Data' "$dataline")")

    state="$(_storage_watchdog_state)"
    case "$state" in
        disabled) watch="disabled" ;;
        not-installed) watch="not installed (nothing will remount the NAS)" ;;
        stopped) watch="installed but stopped" ;;
        *)
            watch="running"
            if [[ -s "$SCRIPT_DIR/config/state/storage-watchdog-stopped" ]]; then
                watch="running (services paused — NAS down since $(<"$SCRIPT_DIR/config/state/storage-watchdog-stopped"))"
            fi
            ;;
    esac
    lines+=("$(ui_kv 'Watchdog' "$watch")")
    lines+=("$(ui_kv 'Services' "$(_storage_services_running)")")

    ui_box "MediaStack - Storage & Data Mount" "${lines[@]}"
}

# What to tell the operator about recovery, from the watchdog state that exists.
_storage_recovery_hint() {
    case "$(_storage_watchdog_state)" in
        running) echo "The watchdog keeps retrying — check the NAS is powered on and reachable on the network." ;;
        stopped) echo "The watchdog is installed but not running, so nothing is retrying. Start it with: sudo systemctl start mediastack-storage-watchdog.service" ;;
        not-installed) echo "No watchdog is installed, so nothing will remount the NAS. Install it from Health & security > Apply changes from a MediaStack update, then check the NAS is reachable." ;;
        *) echo "The watchdog is turned off, so nothing will remount the NAS. Turn it on under Features & settings, or mount the share by hand." ;;
    esac
}

action_recheck_nas() {
    echo ""
    echo "  Checking NAS storage…"
    local rc=0
    # A probe that timed out returns 124; the action result reports plain failure.
    storage_nas_ok || rc=1
    if ((rc == 0)); then
        ui_log ok "NAS is mounted and verified."
    else
        ui_log warn "NAS is not currently mounted/verified. $(_storage_recovery_hint)"
    fi
    _show_action_result "$rc" "Re-check NAS"
    launcher_pause_for_menu
}

submenu_storage() {
    while true; do
        clear
        _storage_info

        local options=("Re-check NAS now" "Back")
        local choice
        choice=$(ui_choose "Storage & data mount:" "${options[@]}")
        case "$choice" in
            "Re-check NAS now"*) action_recheck_nas ;;
            *) return 0 ;;
        esac
    done
}

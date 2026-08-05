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

_storage_info() {
    local lines=() src fstype dataline free data watch wd_unit='mediastack-storage-watchdog.service'
    src="$(storage_expected_source)"
    fstype="$(storage_expected_fstype)"
    lines+=("$(ui_kv 'Storage' 'Network storage (NAS)')")
    lines+=("$(ui_kv 'NAS source' "${src:-unknown}")")

    local status
    if storage_mount_matches; then
        if storage_sentinel_ok; then
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
    free=$(df -h --output=avail "$data" 2>/dev/null | tail -1 | tr -d ' ')
    dataline="$data"
    [[ -n "$free" ]] && dataline+=" — ${free} free"
    lines+=("$(ui_kv 'Data' "$dataline")")

    if ! storage_watchdog_enabled; then
        watch="disabled"
    elif systemctl is-active --quiet "$wd_unit" 2>/dev/null; then
        if [[ -s "$SCRIPT_DIR/config/state/storage-watchdog-stopped" ]]; then
            watch="running (services paused — NAS down since $(<"$SCRIPT_DIR/config/state/storage-watchdog-stopped"))"
        else
            watch="running"
        fi
    else
        watch="stopped"
    fi
    lines+=("$(ui_kv 'Watchdog' "$watch")")
    lines+=("$(ui_kv 'Services' "$(_storage_services_running)")")

    ui_box "MediaStack - Storage & Data Mount" "${lines[@]}"
}

action_recheck_nas() {
    echo ""
    echo "  Checking NAS storage…"
    local rc=0
    storage_nas_ok || rc=$?
    if ((rc == 0)); then
        ui_log ok "NAS is mounted and verified."
    else
        ui_log warn "NAS is not currently mounted/verified. The watchdog keeps retrying — check the NAS is powered on and reachable on the network."
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

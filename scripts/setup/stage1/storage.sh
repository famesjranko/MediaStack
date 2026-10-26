# Owns: stage1_* — Stage 1 local, manual, and managed-NAS storage collection.
# Sources: storage helpers, wizard UI, validators, `DEFAULT_NFS_OPTS`, and `_WIZ_*`/`_WIZ_PREV_*` state.

_stage1_collect_storage() {
    while true; do
        _stage1_collect_storage_once
        # Managed NAS confirms its own choices inside the NAS sub-flow, so its
        # "Re-enter" only revisits the NFS options + watchdog (not the whole
        # connection flow). Every other path uses this generic confirm, whose
        # "Re-enter" re-opens the storage menu.
        if [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-}" == "managed" ]]; then
            break
        fi
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these storage choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_storage_once() {
    ui_section 2 10 "Storage"

    # Loop the storage menu so the NAS sub-flow's "Back to storage options" can
    # bring the user straight back here to pick a different backend.
    local storage_choice local_default
    while true; do
        local_default="${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}"
        if [[ "${_WIZ_STORAGE_MODE:-local}" != "local" ]]; then
            local_default="${_WIZ_PREV_DATA_DIR:-/data}"
        fi
        storage_choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Where should MediaStack store media and downloads?" \
            "Local disk (${local_default}) (recommended)" \
            "Network/NAS storage (NFS) - MediaStack manages mount checks and service protection." \
            "Advanced manual storage - install apps but skip app-level storage wiring." \
            "Quit installer")

        case "$storage_choice" in
            "Network/NAS"*)
                _WIZ_STORAGE_MODE="nas"
                _WIZ_STORAGE_APP_WIRING="managed"
                _WIZ_STORAGE_PROTOCOL="nfs"
                # Returns 0 once the NAS is verified + confirmed (or classification
                # rerouted to local/manual); returns 1 for "Back to storage options",
                # which re-shows this menu on the next loop.
                _stage1_collect_nas_managed && break
                ;;
            "Advanced manual"*)
                _stage1_collect_manual_storage
                break
                ;;
            "Quit"*)
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                exit 0
                ;;
            *)
                _WIZ_STORAGE_MODE="local"
                _WIZ_STORAGE_APP_WIRING="managed"
                _WIZ_STORAGE_PROTOCOL=""
                _WIZ_DATA_DIR=$(ui_input_validated \
                    "Data directory" \
                    "$local_default" \
                    validate_data_dir)
                _stage1_reset_local_storage_fields
                break
                ;;
        esac
    done
    # Consolidated storage summary line. The NAS host:export is echoed per-field
    # inside _stage1_collect_nas_settings, so it isn't repeated here. Managed NAS
    # already prints this inside its own confirm loop, so skip it to avoid a dupe.
    if ! [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-}" == "managed" ]]; then
        ui_kv "Storage" "${_WIZ_STORAGE_MODE:-local} at ${_WIZ_DATA_DIR:-/data} (${_WIZ_STORAGE_APP_WIRING:-managed} wiring)"
    fi
}

_stage1_collect_nas_settings() {
    local previous_mountpoint="${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-}}"

    # Frame the three things NAS setup needs before the first prompt (house style:
    # a ui_box, like the public-indexers panel). Each answer is echoed with ui_kv
    # right after entry (mirrors _stage1_collect_admin) so choices accumulate on
    # screen as a running summary — the gum backend clears each input widget after
    # submit, so without these the answers would vanish before the mount preflight.
    ui_box "Network/NAS storage (NFS)" \
        "MediaStack will connect to your NAS and store your media there." \
        "You'll need three things:" \
        "  - your NAS address (IP or hostname)" \
        "  - the shared folder on the NAS (its NFS export path)" \
        "  - where it should appear on this server (the mountpoint, e.g. /data)"
    echo ""

    _WIZ_DATA_DIR=$(ui_input_validated \
        "Local mountpoint for NAS storage" \
        "${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}}}" \
        validate_nas_mountpoint)
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    ui_kv "NAS mountpoint" "$_WIZ_STORAGE_MOUNTPOINT"
    echo ""

    _WIZ_STORAGE_NFS_HOST=$(ui_input_validated \
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)" \
        "${_WIZ_STORAGE_NFS_HOST:-${_WIZ_PREV_STORAGE_NFS_HOST:-}}" \
        validate_nfs_host)
    ui_kv "NAS host/IP" "$_WIZ_STORAGE_NFS_HOST"
    echo ""

    _WIZ_STORAGE_NFS_EXPORT=$(ui_input_validated \
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)" \
        "${_WIZ_STORAGE_NFS_EXPORT:-${_WIZ_PREV_STORAGE_NFS_EXPORT:-}}" \
        validate_nfs_export)
    ui_kv "NFS export" "$_WIZ_STORAGE_NFS_EXPORT"

    # NFS mount options and the watchdog toggle are collected AFTER the connection
    # is verified and confirmed (_stage1_collect_nas_options). Seed the recommended
    # defaults here so the verification probe has something to mount with.
    _WIZ_STORAGE_NFS_OPTS="${_WIZ_STORAGE_NFS_OPTS:-${_WIZ_PREV_STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}}"

    # The safety marker is the watchdog's internal sentinel; users never name it.
    # Always default it under the mountpoint (silently).
    local sentinel_default="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
    if [[ -n "${_WIZ_STORAGE_SENTINEL:-}" && "$previous_mountpoint" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_STORAGE_SENTINEL"
    elif [[ -n "${_WIZ_PREV_STORAGE_SENTINEL:-}" && "${_WIZ_PREV_STORAGE_MOUNTPOINT:-}" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_PREV_STORAGE_SENTINEL"
    fi
    if ! storage_path_is_under_mountpoint "$sentinel_default" "$_WIZ_STORAGE_MOUNTPOINT"; then
        sentinel_default="${_WIZ_STORAGE_MOUNTPOINT}/.mediastack-storage-ready"
    fi
    _WIZ_STORAGE_SENTINEL="$sentinel_default"
}

# Managed-NAS orchestrator: a small state machine so the final review can send
# the user back to any layer. connection -> options -> review. The review box
# lists every choice and its menu confirms or jumps back to a specific layer.
# Returns 0 when confirmed (or classification rerouted to local/manual), 1 when
# the user chooses "Change storage type" (caller re-shows the storage menu).
# Nothing is mounted or configured here; confirming only locks in the _WIZ_*
# choices (the probe is non-destructive; the real mount is deferred to install).
_stage1_collect_nas_managed() {
    local step=connection action
    while true; do
        case "$step" in
            connection)
                _stage1_collect_nas_settings
                echo ""
                _stage1_preflight_nas_choice
                # A probe failure or a non-empty-share reroute may have switched
                # away from managed NAS (to local, or to manual app wiring). If so
                # it's already resolved and there is nothing to review here.
                [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-managed}" == "managed" ]] || return 0
                step=options
                ;;
            options)
                echo ""
                _stage1_collect_nas_options
                step=review
                ;;
            review)
                echo ""
                _stage1_nas_review_box
                action=$(ui_choose "Lock in these storage choices?" \
                    "Confirm and continue" \
                    "Change NFS options / watchdog" \
                    "Change NAS address, export or mount point" \
                    "Change storage type" \
                    "Abort installation")
                case "$action" in
                    "Confirm"*) return 0 ;;
                    "Change NFS"*) step=options ;;
                    "Change NAS"*) step=connection ;;
                    "Change storage"*) return 1 ;;
                    "Abort"*)
                        log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                        exit 0
                        ;;
                esac
                ;;
        esac
    done
}

# Consolidated review of the managed-NAS choices, shown before the lock-in menu.
# Reuses the ui_box + ui_kv pattern from stage1_show_system.
_stage1_nas_review_box() {
    local wd
    [[ "${_WIZ_STORAGE_WATCHDOG:-true}" == "false" ]] && wd="off" || wd="on"
    ui_box "Storage choices to lock in" \
        "$(ui_kv 'Storage' 'Network/NAS (NFS)')" \
        "$(ui_kv 'NAS server' "${_WIZ_STORAGE_NFS_HOST}:${_WIZ_STORAGE_NFS_EXPORT}")" \
        "$(ui_kv 'Mount point' "${_WIZ_DATA_DIR}")" \
        "$(ui_kv 'NFS options' "${_WIZ_STORAGE_NFS_OPTS}")" \
        "$(ui_kv 'Watchdog' "$wd")"
}

# NFS options + watchdog, asked only after the connection is verified and the
# user has confirmed the NAS. The verification probe ran on the recommended
# options, so "yes" needs no re-check; custom options are unproven and re-probed.
_stage1_collect_nas_options() {
    local nfs_opts_default
    nfs_opts_default="${_WIZ_STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}"

    if ui_confirm "Use the recommended NFS mount options?" "yes"; then
        _WIZ_STORAGE_NFS_OPTS="$nfs_opts_default"
    else
        ui_log warn "Custom NFS options are advanced and unsupported - if the mount misbehaves with these, that is on you. The recommended defaults suit almost everyone."
        while true; do
            _WIZ_STORAGE_NFS_OPTS=$(ui_input_validated \
                "NFS mount options" \
                "$nfs_opts_default" \
                validate_nfs_options)
            if _stage1_reprobe_with_current_opts; then
                break
            fi
            local retry
            retry=$(ui_choose "Could not verify the NAS with those options. What now?" \
                "Edit the options" \
                "Use the recommended options instead")
            if [[ "$retry" == "Use the recommended"* ]]; then
                _WIZ_STORAGE_NFS_OPTS="$nfs_opts_default"
                break
            fi
        done
    fi
    ui_kv "NFS options" "$_WIZ_STORAGE_NFS_OPTS"

    echo ""
    local watchdog_default="yes"
    [[ "${_WIZ_STORAGE_WATCHDOG:-${_WIZ_PREV_STORAGE_WATCHDOG:-true}}" == "false" ]] && watchdog_default="no"
    ui_log info "The NAS watchdog stops your media services if the NAS disconnects and restarts them when it returns. Recommended."
    if ui_confirm "Enable the NAS mount watchdog?" "$watchdog_default"; then
        _WIZ_STORAGE_WATCHDOG="true"
    else
        _WIZ_STORAGE_WATCHDOG="false"
        ui_log warn "Watchdog disabled: MediaStack will NOT stop or protect data services if the NAS drops mid-run."
    fi
    [[ "${_WIZ_STORAGE_WATCHDOG:-true}" == "false" ]] && ui_kv "NAS watchdog" "off" || ui_kv "NAS watchdog" "on"
}

# Re-run the non-destructive probe with the user's just-entered custom options,
# then restore the caller's STORAGE_* env. Returns 0 if the probe passes.
_stage1_reprobe_with_current_opts() {
    local prev_host="${STORAGE_NFS_HOST:-}" prev_export="${STORAGE_NFS_EXPORT:-}" prev_opts="${STORAGE_NFS_OPTS:-}"
    export STORAGE_NFS_HOST="$_WIZ_STORAGE_NFS_HOST"
    export STORAGE_NFS_EXPORT="$_WIZ_STORAGE_NFS_EXPORT"
    export STORAGE_NFS_OPTS="$_WIZ_STORAGE_NFS_OPTS"
    local rc=0
    storage_probe_nas || rc=1
    STORAGE_NFS_HOST="$prev_host"
    STORAGE_NFS_EXPORT="$prev_export"
    STORAGE_NFS_OPTS="$prev_opts"
    return "$rc"
}

_stage1_reset_local_storage_fields() {
    _WIZ_STORAGE_MODE="local"
    _WIZ_STORAGE_APP_WIRING="managed"
    _WIZ_STORAGE_PROTOCOL=""
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    _WIZ_STORAGE_NFS_HOST=""
    _WIZ_STORAGE_NFS_EXPORT=""
    _WIZ_STORAGE_NFS_OPTS=""
    _WIZ_STORAGE_SENTINEL="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
    _WIZ_STORAGE_WATCHDOG="true"
}

_stage1_reset_manual_storage_fields() {
    _WIZ_STORAGE_APP_WIRING="manual"
    _WIZ_STORAGE_MODE="local"
    _WIZ_STORAGE_PROTOCOL=""
    _WIZ_STORAGE_MOUNTPOINT=""
    _WIZ_STORAGE_NFS_HOST=""
    _WIZ_STORAGE_NFS_EXPORT=""
    _WIZ_STORAGE_NFS_OPTS=""
    _WIZ_STORAGE_SENTINEL=""
    _WIZ_STORAGE_WATCHDOG="true"
}

_stage1_collect_manual_storage() {
    _WIZ_STORAGE_APP_WIRING="manual"
    ui_log warn "Advanced manual storage skips Jellyfin libraries, Sonarr/Radarr root folders, qBittorrent paths/categories, Seerr links, and Unpackerr path wiring."
    ui_log warn "You take responsibility for app-level storage wiring here: MediaStack will not create or manage media/download paths, and fixing any misconfiguration is on you."

    if ui_confirm "Still enable NAS mount guard/watchdog for this manual storage?" "no"; then
        ui_log info "MediaStack will verify the NAS mount/sentinel and protect data services, but app storage paths stay manual."
        _WIZ_STORAGE_MODE="nas"
        _WIZ_STORAGE_PROTOCOL="nfs"
        _WIZ_STORAGE_WATCHDOG="true"
        _WIZ_STORAGE_NFS_OPTS="${_WIZ_STORAGE_NFS_OPTS:-${_WIZ_PREV_STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}}"
        if [[ -z "${_WIZ_STORAGE_NFS_HOST:-}" || -z "${_WIZ_STORAGE_NFS_EXPORT:-}" ]]; then
            _stage1_collect_nas_settings
        fi
        _stage1_preflight_nas_choice
        _WIZ_STORAGE_APP_WIRING="manual"
    else
        _WIZ_DATA_DIR=$(ui_input_validated \
            "Container data mount root" \
            "${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}" \
            validate_data_dir)
        _stage1_reset_manual_storage_fields
    fi
}

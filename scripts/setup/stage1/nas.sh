# Owns: Stage 1 NAS preflight, environment handoff, and install-time NAS recovery.
# Sources: storage helpers, wizard UI, env generation, `SCRIPT_DIR`, `DATA_DIR`/`STORAGE_*`, and `_WIZ_*` state.

_stage1_preflight_nas_choice() {
    local prev_data="${DATA_DIR:-}"
    local prev_mode="${STORAGE_MODE:-}"
    local prev_host="${STORAGE_NFS_HOST:-}"
    local prev_export="${STORAGE_NFS_EXPORT:-}"
    local prev_opts="${STORAGE_NFS_OPTS:-}"
    local prev_sentinel="${STORAGE_SENTINEL:-}"
    local prev_mountpoint="${STORAGE_MOUNTPOINT:-}"
    local prev_expected_source="${STORAGE_EXPECTED_SOURCE:-}"
    local prev_expected_fstype="${STORAGE_EXPECTED_FSTYPE:-}"

    while true; do
        export DATA_DIR="$_WIZ_DATA_DIR"
        export STORAGE_MODE="nas"
        export STORAGE_NFS_HOST="$_WIZ_STORAGE_NFS_HOST"
        export STORAGE_NFS_EXPORT="$_WIZ_STORAGE_NFS_EXPORT"
        export STORAGE_NFS_OPTS="$_WIZ_STORAGE_NFS_OPTS"
        export STORAGE_SENTINEL="$_WIZ_STORAGE_SENTINEL"
        export STORAGE_MOUNTPOINT="${_WIZ_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}"
        export STORAGE_EXPECTED_SOURCE=""
        export STORAGE_EXPECTED_FSTYPE=""

        if ! storage_ensure_nfs_common; then
            ui_log warn "Could not install nfs-common, which is required for managed NAS storage."
            local fallback
            fallback=$(ui_choose "NAS support could not be installed. What should setup do?" \
                "Retry installing NAS support" \
                "Use local storage instead" \
                "Advanced manual storage" \
                "Quit installer")
            case "$fallback" in
                "Retry"*) continue ;;
                "Advanced manual"*) _stage1_collect_manual_storage ;;
                "Quit"*)
                    log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                    exit 0
                    ;;
                *)
                    _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
                    _stage1_reset_local_storage_fields
                    ;;
            esac
            DATA_DIR="$prev_data"
            STORAGE_MODE="$prev_mode"
            STORAGE_NFS_HOST="$prev_host"
            STORAGE_NFS_EXPORT="$prev_export"
            STORAGE_NFS_OPTS="$prev_opts"
            STORAGE_SENTINEL="$prev_sentinel"
            STORAGE_MOUNTPOINT="$prev_mountpoint"
            STORAGE_EXPECTED_SOURCE="$prev_expected_source"
            STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
            return 0
        fi
        # Verify only — never mount the real mountpoint during the wizard. The
        # probe temp-mounts elsewhere, so a changed export can't collide with a
        # prior mount and we never ask the user to detach anything. The real
        # /data mount happens at install (storage_preflight_nas).
        if ! storage_probe_nas; then
            ui_log warn "Could not verify NAS storage."
            local fallback
            fallback=$(ui_choose "NAS mount failed. What should setup do?" \
                "Edit NAS settings and retry" \
                "Retry with the same settings" \
                "Use local storage instead" \
                "Advanced manual storage" \
                "Quit installer")
            case "$fallback" in
                "Edit"*)
                    _stage1_collect_nas_settings
                    continue
                    ;;
                "Retry"*) continue ;;
                "Advanced manual"*)
                    _stage1_collect_manual_storage
                    ;;
                "Quit"*)
                    log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                    exit 0
                    ;;
                *)
                    _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
                    _stage1_reset_local_storage_fields
                    ;;
            esac
            DATA_DIR="$prev_data"
            STORAGE_MODE="$prev_mode"
            STORAGE_NFS_HOST="$prev_host"
            STORAGE_NFS_EXPORT="$prev_export"
            STORAGE_NFS_OPTS="$prev_opts"
            STORAGE_SENTINEL="$prev_sentinel"
            STORAGE_MOUNTPOINT="$prev_mountpoint"
            STORAGE_EXPECTED_SOURCE="$prev_expected_source"
            STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
            return 0
        fi
        break
    done

    local classification="${_STORAGE_PROBE_CLASS:-empty}"
    case "$classification" in
        empty)
            ui_log ok "NAS connection verified - NAS share is empty and ready for MediaStack."
            ;;
        mediastack)
            ui_log ok "NAS connection verified - NAS share already has a MediaStack-style media/torrents layout."
            ;;
        conflict:*)
            ui_log warn "NAS share has a blocking conflict at ${classification#conflict:}."
            if [[ "${_WIZ_STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
                ui_log warn "Manual app wiring selected: MediaStack will protect this NAS but will not create app paths or managed media/torrents directories."
            else
                _stage1_resolve_nonstandard_nas_root "conflict"
            fi
            ;;
        nonempty)
            ui_log warn "NAS share is non-empty and does not look like a MediaStack data root."
            if [[ "${_WIZ_STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
                ui_log warn "Manual app wiring selected: MediaStack will protect this NAS but will not create app paths or managed media/torrents directories."
            else
                _stage1_resolve_nonstandard_nas_root "nonempty"
            fi
            ;;
    esac

    DATA_DIR="$prev_data"
    STORAGE_MODE="$prev_mode"
    STORAGE_NFS_HOST="$prev_host"
    STORAGE_NFS_EXPORT="$prev_export"
    STORAGE_NFS_OPTS="$prev_opts"
    STORAGE_SENTINEL="$prev_sentinel"
    STORAGE_MOUNTPOINT="$prev_mountpoint"
    STORAGE_EXPECTED_SOURCE="$prev_expected_source"
    STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
}

_stage1_resolve_nonstandard_nas_root() {
    local reason="$1"
    local choice
    choice=$(ui_choose "How should MediaStack handle this NAS share?" \
        "Use a new mediastack/ subfolder on this NAS (recommended)" \
        "Use local storage instead" \
        "Advanced manual storage" \
        "Quit installer")
    case "$choice" in
        "Use a new"*)
            _WIZ_DATA_DIR="${_WIZ_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}/mediastack"
            _WIZ_STORAGE_SENTINEL="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
            ui_log info "MediaStack will use NAS subfolder: $_WIZ_DATA_DIR"
            ;;
        "Advanced manual"*)
            ui_log warn "Manual storage selected after NAS ${reason}."
            _stage1_collect_manual_storage
            ;;
        "Quit"*)
            log_info "Setup aborted - choose Install MediaStack from the menu to try again"
            exit 0
            ;;
        *)
            _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
            _stage1_reset_local_storage_fields
            ui_log info "Continuing with local storage at $_WIZ_DATA_DIR"
            ;;
    esac
}

_stage1_source_env() {
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
}

_stage1_write_and_source_env() {
    write_env
    _stage1_source_env
}

_stage1_final_nas_preflight() {
    if [[ "${STORAGE_MODE:-local}" != "nas" ]]; then
        return 0
    fi

    while true; do
        if storage_preflight_nas; then
            return 0
        fi

        ui_log warn "NAS storage could not be verified immediately before install."
        local action
        action=$(ui_choose "NAS storage check failed. What should setup do?" \
            "Retry NAS check" \
            "Edit NAS settings and retry" \
            "Use local storage instead" \
            "Advanced manual storage" \
            "Quit installer")
        case "$action" in
            "Retry"*)
                continue
                ;;
            "Edit"*)
                _stage1_collect_nas_settings
                _stage1_preflight_nas_choice
                _stage1_write_and_source_env
                [[ "${STORAGE_MODE:-local}" == "nas" ]] || return 0
                continue
                ;;
            "Advanced manual"*)
                _stage1_collect_manual_storage
                _stage1_write_and_source_env
                [[ "${STORAGE_MODE:-local}" == "nas" ]] || return 0
                continue
                ;;
            "Quit"*)
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                exit 0
                ;;
            *)
                _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
                _stage1_reset_local_storage_fields
                _stage1_write_and_source_env
                return 0
                ;;
        esac
    done
}

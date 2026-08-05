# =============================================================================
# MediaStack Setup -- Recovery route helpers
# =============================================================================
# Sourced by setup.sh and the mediastack launcher. Depends on $SCRIPT_DIR and
# setup modules being loaded by the caller.

# Recovery helpers call stage3_* functions directly. setup.sh gets them via
# wizard.sh, but the launcher sources recovery.sh standalone — pull in stage3.sh
# here so both callers have them. Guarded: safe to re-source (functions only).
if ! type stage3_pending_nvidia_reboot_same_boot >/dev/null 2>&1; then
    source "$SCRIPT_DIR/scripts/setup/stages/stage3.sh"
fi

RECOVERY_MENU_ACTION="${RECOVERY_MENU_ACTION:-}"

require_stage1_complete() {
    local label="$1"
    local env_path="$SCRIPT_DIR/.env"

    if [[ ! -f "$env_path" ]]; then
        log_warn "Stage 1 is not complete yet. Run ./setup.sh first, then retry ./setup.sh ${label}."
        return 1
    fi

    set -a
    source "$env_path"
    set +a

    if [[ "${STAGE_1_COMPLETE:-}" != "1" ]]; then
        log_warn "Stage 1 is not complete yet. Run ./setup.sh first, then retry ./setup.sh ${label}."
        return 1
    fi
}

recovery_menu_remote_available() {
    # Empty REMOTE_WEB_STATE shouldn't lock the user out of the recovery menu
    # — a manually-edited .env or a not-yet-Stage-2-run install should still
    # surface "Add remote access". Real installs always go through
    # _stage2_install (sets `unchecked`) or _stage2_skip_https (sets `skipped`).
    case "${REMOTE_WEB_STATE:-}" in
        "" | unchecked | skipped | failed) return 0 ;;
        *) return 1 ;;
    esac
}

recovery_menu_transcoding_available() {
    [[ "${GPU_TYPE:-none}" != "none" ]] || return 1
    case "${STAGE_3_GPU_STATE:-}" in
        complete | pending) return 1 ;;
        *) return 0 ;;
    esac
}

show_existing_install_menu() {
    RECOVERY_MENU_ACTION=""

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi

    # Surface the CURRENT state of each add-on this menu offers, so a returning
    # user can tell what's done vs pending before choosing. Labels are computed
    # by the same stack.sh helpers print_final_summary uses (single source of
    # truth — these never drift from the post-install summary). PRINTED text /
    # ui_box content only — never a ui_choose option (that would consume a
    # selection index and break the position-based PTY drivers).
    local status_lines=()
    if recovery_menu_remote_available; then
        status_lines+=("Remote access: $(remote_state_label "${REMOTE_WEB_STATE:-}")")
    fi
    if recovery_menu_transcoding_available; then
        status_lines+=("Hardware transcoding: $(transcoding_state_label "${STAGE_3_GPU_STATE:-}" "${STAGE_3_GPU_VENDOR:-}")")
    fi

    if type ui_box >/dev/null 2>&1; then
        local box_lines=(
            "You can add skipped features to this install without touching your data or media."
            "Remote access will rerun Stage 2 only. Hardware transcoding will rerun only that add-on."
            "A fresh reinstall is still available, but it requires typing DESTROY."
            "For day-to-day management (status, updates, features), run ./mediastack instead."
        )
        if ((${#status_lines[@]} > 0)); then
            box_lines+=("" "Current setup:")
            local line
            for line in "${status_lines[@]}"; do
                box_lines+=("  ${line}")
            done
        fi
        ui_box "Existing install detected" "${box_lines[@]}"
    else
        log_info "Existing install detected. Add-stage actions will not touch your data or media."
        local line
        for line in "${status_lines[@]}"; do
            log_info "Current setup -- ${line}"
        done
        log_info "For day-to-day management (status, updates, features), run ./mediastack instead."
    fi

    local options=()
    if stage3_pending_nvidia_reboot_same_boot; then
        options+=("Reboot to finish hardware transcoding")
    fi
    if recovery_menu_remote_available; then
        options+=("Add remote access")
    fi
    if recovery_menu_transcoding_available; then
        options+=("Add hardware transcoding")
    fi
    options+=("Continue without changes")
    options+=("Wipe everything and start fresh")
    options+=("Abort")

    local choice
    choice=$(ui_choose "What would you like to do?" "${options[@]}")

    case "$choice" in
        "Reboot to finish hardware transcoding"*)
            RECOVERY_MENU_ACTION=completed
            print_final_summary
            # "Reboot now" never returns (host reboots); a return here means the
            # user DEFERRED the reboot — the install is done but GPU transcoding
            # only activates after a reboot, so the launcher should say exactly
            # that rather than a flat "completed successfully".
            stage3_prompt_pending_nvidia_reboot && record_launcher_outcome reboot-pending
            ;;
        "Add remote access"*)
            RECOVERY_MENU_ACTION=completed
            run_remote_recovery && record_launcher_outcome completed
            ;;
        "Add hardware transcoding"*)
            RECOVERY_MENU_ACTION=completed
            run_transcoding_recovery && record_launcher_outcome completed
            ;;
        "Continue without changes"*)
            RECOVERY_MENU_ACTION="continue"
            record_launcher_outcome unchanged
            log_ok "Continuing with existing install. No changes made."
            return 0
            ;;
        "Wipe everything and start fresh"*)
            RECOVERY_MENU_ACTION=wipe
            return 0
            ;;
        "Abort"*)
            RECOVERY_MENU_ACTION=abort
            record_launcher_outcome aborted
            log_info "Aborted by user. No changes made."
            return 1
            ;;
        *)
            RECOVERY_MENU_ACTION=abort
            record_launcher_outcome aborted
            log_warn "Unexpected choice: ${choice}. Aborting."
            return 1
            ;;
    esac
}

run_remote_recovery() {
    require_stage1_complete "--remote" || return 1

    if [[ "${REMOTE_WEB_STATE:-}" == "ready" ]]; then
        run_remote_ready_recovery
        return $?
    fi

    check_docker
    check_compose
    check_internet_reachability
    prompt_sudo_cache
    detect_env
    _wizard_load_existing_env

    local rc=0
    run_stage2 || rc=$?
    if ((rc == 0)); then
        if stage3_pending_nvidia_reboot_same_boot; then
            print_final_summary
            stage3_prompt_pending_nvidia_reboot
        fi
    elif stage3_pending_nvidia_reboot_same_boot; then
        log_warn "NVIDIA hardware transcoding is prepared and still needs a reboot. Choose Manage hardware transcoding (GPU) from the menu when you are ready to finish it."
    fi
    return "$rc"
}

run_remote_ready_recovery() {
    check_docker
    check_compose
    check_internet_reachability
    prompt_sudo_cache
    detect_env
    _wizard_load_existing_env

    repair_ddns_updater_config_permissions || return 1
    pull_images
    start_stack
    wait_all_healthy
    # Remote access just came up → install the fail2ban log-rotation reload
    # watcher. Sudo is primed above (prompt_sudo_cache).
    if service_container_running fail2ban; then
        f2b_install_reload_watcher
    fi
    (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only npm,jellyfin,homepage,ddns-updater,wireguard)
    print_access_info
    if stage3_pending_nvidia_reboot_same_boot; then
        print_final_summary
        stage3_prompt_pending_nvidia_reboot
    fi
}

run_transcoding_recovery() {
    require_stage1_complete "--transcoding" || return 1

    check_docker
    check_compose
    check_internet_reachability
    prompt_sudo_cache
    NEEDS_REBOOT=false
    GPU_TYPE="none"
    stash_gpu_type
    detect_env
    _wizard_load_existing_env

    if stage3_pending_nvidia_reboot_same_boot; then
        # Global consumed by stage3.sh reboot gating, not within recovery.sh.
        # shellcheck disable=SC2034
        NEEDS_REBOOT=true
        # A driver setup is prepared and waiting for a reboot. Let the user
        # finish it OR change their mind (e.g. switch Unlock .run -> Standard apt)
        # before rebooting, instead of being locked into the pending choice.
        local _pending_action
        _pending_action=$(ui_choose "NVIDIA driver setup is prepared and waiting for a reboot. What would you like to do?" \
            "Finish setup (reboot now or later)" \
            "Change driver choice (discard and start over)")
        case "$_pending_action" in
            "Change driver"*)
                _stage3_discard_pending_setup
                STAGE3_SKIP_OFFER=true run_stage3
                return 0
                ;;
            *)
                stage3_prompt_nvidia_reboot
                return 0
                ;;
        esac
    fi

    # The user already chose to configure transcoding (launcher menu / CLI flag),
    # so skip run_stage3's redundant "Configure now?" offer.
    STAGE3_SKIP_OFFER=true run_stage3
}

_nvidia_unlock_maintenance_guard() {
    require_stage1_complete "${1:-}" || return 1
    if [[ "${JELLYFIN_GPU:-none}" != "nvidia" || "${NVIDIA_DRIVER_MODE:-}" != "unlock" ]]; then
        log_warn "This action is only available for an active NVIDIA Unlock configuration."
        return 1
    fi
    if stage3_marker_exists; then
        log_warn "Finish the pending NVIDIA reboot/finalization before running this action."
        return 1
    fi
    if [[ "$(nvidia_driver_source)" != "foreign" ]] || ! nvidia_driver_healthy; then
        log_warn "The loaded Unlock driver is missing, unhealthy, or now owned by Debian packages. No changes were made."
        return 1
    fi
}

run_nvidia_unlock_maintenance() {
    local action="$1"
    case "$action" in
        update | repatch) ;;
        *) return 2 ;;
    esac
    _nvidia_unlock_maintenance_guard "--nvidia-unlock-${action}" || return 1
    prompt_sudo_cache

    if [[ "$action" == "repatch" ]]; then
        apply_nvidia_patch
        local _rc=$?
        ((_rc == 0)) && type clear_setup_result_banner >/dev/null 2>&1 && clear_setup_result_banner
        return "$_rc"
    fi

    check_internet_reachability
    if ! ui_confirm "Update the NVIDIA driver and prepare Unlock patch finalization after reboot?" "no"; then
        log_skip "NVIDIA driver update cancelled."
        return 0
    fi

    local _nvidia_tmp="$SCRIPT_DIR/.nvidia-tmp/update"
    local _driver_ver="" _run_file="" jellyfin_running=false
    rm -rf "$_nvidia_tmp"
    mkdir -p "$_nvidia_tmp" || return 1
    if ! _resolve_nvidia_driver; then
        rm -rf "$_nvidia_tmp"
        return 1
    fi

    if (cd "$SCRIPT_DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx jellyfin); then
        jellyfin_running=true
        (cd "$SCRIPT_DIR" && docker compose stop jellyfin) || {
            rm -rf "$_nvidia_tmp"
            return 1
        }
    fi

    if ! _nvidia_unload_loaded_modules; then
        $jellyfin_running && (cd "$SCRIPT_DIR" && docker compose start jellyfin >/dev/null 2>&1 || true)
        rm -rf "$_nvidia_tmp"
        log_error "NVIDIA modules are still in use. Driver update aborted without installing anything."
        return 1
    fi

    if ! _install_nvidia_run_file "$_run_file" "$_driver_ver" "$_nvidia_tmp" \
        || ! _configure_nvidia_container_toolkit; then
        $jellyfin_running && (cd "$SCRIPT_DIR" && docker compose start jellyfin >/dev/null 2>&1 || true)
        rm -rf "$_nvidia_tmp"
        log_error "NVIDIA driver update did not complete."
        return 1
    fi

    rm -rf "$_nvidia_tmp"
    $jellyfin_running && (cd "$SCRIPT_DIR" && docker compose start jellyfin >/dev/null 2>&1 || true)
    # Read by the shared Stage 3 reboot gate after this helper returns.
    # shellcheck disable=SC2034
    NEEDS_REBOOT=true
    _stage3_nvidia_queue_reboot unlock run-update "$_driver_ver"
}

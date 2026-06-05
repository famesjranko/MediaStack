# =============================================================================
# MediaStack Setup -- Recovery route helpers
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and setup modules being loaded by
# the caller.

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
        ""|unchecked|skipped|failed) return 0 ;;
        *) return 1 ;;
    esac
}

recovery_menu_transcoding_available() {
    [[ "${GPU_TYPE:-none}" != "none" ]] || return 1
    case "${STAGE_3_GPU_STATE:-}" in
        complete|pending) return 1 ;;
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
        if (( ${#status_lines[@]} > 0 )); then
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
    if (( rc == 0 )); then
        if stage3_pending_nvidia_reboot_same_boot; then
            print_final_summary
            stage3_prompt_pending_nvidia_reboot
        fi
    elif stage3_pending_nvidia_reboot_same_boot; then
        log_warn "NVIDIA hardware transcoding is prepared and still needs a reboot. Run ./setup.sh --transcoding when you are ready to finish it."
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
        stage3_prompt_nvidia_reboot
        return 0
    fi

    run_stage3
}

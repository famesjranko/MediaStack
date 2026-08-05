# Owns: existing-install detection and the three-way keep/wipe/abort prompt.
# Sources: $SCRIPT_DIR and scripts/lib/common.sh, loaded by the caller
# (scripts/setup/checks.sh, sourced from setup.sh). Calls into
# show_existing_install_menu (scripts/setup/recovery.sh) and
# nuke_existing_install (scripts/setup/checks/destroy.sh, sourced alongside).

detect_existing_install() {
    # Detects an existing MediaStack install per this predicate:
    # .env non-empty AND STAGE_1_COMPLETE=1 AND (ddns config exists OR
    # jellyfin container running).
    # When detected, presents three choices via ui_choose. Runs LAST
    # in the pre-flight battery so all hard fails fire first.
    #
    # CONTRACT: this function never returns non-zero on the
    # "no install detected" path. It sets the global EXISTING_INSTALL_DETECTED
    # to true|false so the call site (setup.sh::main) can read state without
    # tripping `set -euo pipefail`.
    local env_file="$SCRIPT_DIR/.env"
    local ddns_config="$SCRIPT_DIR/config/ddns-updater/config.json"

    # Default state: no install detected. Exported so recovery/setup routing
    # can read it without re-running detection.
    export EXISTING_INSTALL_DETECTED=false

    # Predicate part 1: .env must exist and be non-empty.
    [[ -s "$env_file" ]] || return 0

    local stage1_complete
    stage1_complete=$(awk -F= '$1 == "STAGE_1_COMPLETE" {print $2; exit}' "$env_file" 2>/dev/null || true)
    if [[ "$stage1_complete" != "1" ]]; then
        log_warn "Incomplete Stage 1 state detected; resuming setup instead of existing-install menu."
        return 0
    fi

    # Predicate part 2: ddns config OR running jellyfin container.
    local detected=false
    local evidence=""
    if [[ -f "$ddns_config" ]]; then
        detected=true
        evidence="ddns config"
    else
        # Capture, never pipe to grep -q (SIGPIPE+pipefail race —
        # see project memory feedback_sigpipe_pipefail_flake.md).
        # Wrap in `timeout 5` (degraded daemon
        # would otherwise hang for ~30s).
        local jellyfin_id
        jellyfin_id=$(timeout 5 docker ps --filter name=jellyfin -q 2>/dev/null || true)
        if [[ -n "$jellyfin_id" ]]; then
            detected=true
            evidence="jellyfin container"
        fi
    fi

    $detected || return 0

    # Existing install detected — present the three-way prompt in fixed order.
    log_warn "Existing MediaStack install detected (.env + ${evidence})."
    local choice
    choice=$(ui_choose "What would you like to do?" \
        "Use existing install" \
        "Wipe everything and start fresh" \
        "Abort")

    case "$choice" in
        "Use existing install"*)
            export EXISTING_INSTALL_DETECTED=true
            if type show_existing_install_menu >/dev/null 2>&1; then
                RECOVERY_MENU_ACTION=""
                local menu_rc=0
                show_existing_install_menu || menu_rc=$?
                case "${RECOVERY_MENU_ACTION:-}" in
                    wipe)
                        if ((menu_rc == 0)); then
                            nuke_existing_install
                            local wipe_rc=$?
                            if ((wipe_rc == 0)); then
                                RECOVERY_MENU_ACTION=""
                            fi
                            return "$wipe_rc"
                        fi
                        return "$menu_rc"
                        ;;
                    continue | completed | abort)
                        return "$menu_rc"
                        ;;
                    *)
                        if ((menu_rc != 0)); then
                            return "$menu_rc"
                        fi
                        log_ok "Continuing with existing install. No changes made."
                        return 0
                        ;;
                esac
            fi
            log_ok "Continuing with existing install. No changes made."
            return 0
            ;;
        "Wipe everything and start fresh"*)
            nuke_existing_install
            return $?
            ;;
        "Abort"*)
            log_info "Aborted by user. No changes made."
            record_launcher_outcome aborted
            exit 0
            ;;
        *)
            # Unexpected ui_choose output — treat as abort (defensive).
            log_warn "Unexpected choice: ${choice}. Aborting."
            record_launcher_outcome aborted
            exit 0
            ;;
    esac
}

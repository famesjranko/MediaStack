# Owns: stage3_* — NVIDIA driver-mode wizard screens (Standard/Unlock), action menu, and the run_nvidia orchestration.
# Sources: stage3_* marker/state/jellyfin/nvidia-finalize helpers; scripts/setup/gpu/* driver modules.

_stage3_nvidia_mode_more_copy() {
    ui_log info "Standard driver: Debian's packaged NVIDIA driver. It updates with the system (apt) and keeps NVIDIA's official NVENC session limit - typically 3-5 simultaneous transcodes, which is plenty for a home server where most playback is direct-play."
    ui_log info "Unlock NVENC limit: a patch-managed driver that removes the session limit, for households doing many simultaneous transcodes. It modifies NVIDIA driver binaries and must be re-applied from Manage hardware transcoding after every driver update."
    ui_log warn "Unlock modifies NVIDIA driver binaries and may conflict with NVIDIA's terms, warranties, support expectations, or local law."
}

_stage3_confirm_unlock() {
    ui_box "Unlock NVENC limit (advanced)" \
        "Installs a patch-managed NVIDIA driver and modifies its binaries." \
        "Removes the NVENC session limit, but must be re-applied after every" \
        "driver update (Manage hardware transcoding can reapply it)." \
        "May conflict with NVIDIA's terms, warranties, support, or local law."
    ui_confirm "Install the patch-managed driver and apply nvidia-patch?" "no"
}

# Ask Standard vs Unlock. Echoes "standard" or "unlock" to stdout; every menu and
# explanatory line goes to stderr so command substitution captures only the answer.
# Standard is listed first, so it is the default in non-interactive / UI_DEMO runs
# — the patch path is never selected by default.
_stage3_choose_nvidia_mode() {
    local choice
    while true; do
        {
            ui_box "NVIDIA driver setup" \
                "Standard is right for almost every home server - pick it unless you know" \
                "you need more than ~5 people transcoding at the same time." \
                "Standard driver: Debian-managed, official NVENC limits (recommended)" \
                "Unlock NVENC limit: patch-managed, removes the limit (advanced)"
        } >&2
        choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "How should MediaStack set up the NVIDIA driver?" \
            "Standard driver (recommended)" \
            "Unlock NVENC limit (advanced)" \
            "Tell me more")
        case "$choice" in
            *"Standard driver"*)
                printf 'standard'
                return 0
                ;;
            *"Unlock NVENC limit"*)
                if _stage3_confirm_unlock >&2; then
                    printf 'unlock'
                    return 0
                fi
                { ui_log skip "Leaving the patch unapplied; choose Standard for the distro-managed driver."; } >&2
                ;;
            *"Tell me more"*)
                { _stage3_nvidia_mode_more_copy; } >&2
                ;;
            *)
                printf standard
                return 0
                ;;
        esac
    done
}

_stage3_nvidia_manual_guidance() {
    ui_box "NVIDIA driver managed outside MediaStack" \
        "MediaStack will not remove, repair, replace, or patch this driver automatically." \
        "To switch to Standard, remove the current driver using its original uninstall" \
        "method, then open Manage hardware transcoding (GPU) and choose Standard." \
        "To switch to Unlock, remove it first, then choose Unlock NVENC on the same route."
}

_stage3_choose_nvidia_action() {
    local source="$1" health="$2" choice
    # To stderr: this function's stdout is its return value (captured by the
    # caller), so the header must not land on stdout.
    { ui_section "NVIDIA driver"; } >&2
    while true; do
        case "$source:$health" in
            none:*)
                _stage3_choose_nvidia_mode
                return
                ;;
            debian:healthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "How should MediaStack use the NVIDIA driver?" \
                    "Use installed driver $(nvidia_driver_version 2>/dev/null || echo '(version unknown)') (recommended)" \
                    "Replace with Unlock NVENC (advanced)" \
                    "Tell me more")
                case "$choice" in
                    "Use installed"*)
                        printf use
                        return
                        ;;
                    "Replace with Unlock"*)
                        if _stage3_confirm_unlock >&2; then
                            printf unlock
                            return
                        fi
                        { ui_log skip "Unlock replacement cancelled; the installed Debian driver was not changed."; } >&2
                        ;;
                    "Tell me more"*) { _stage3_nvidia_mode_more_copy; } >&2 ;;
                    *)
                        printf use
                        return
                        ;;
                esac
                ;;
            debian:unhealthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "The Debian NVIDIA driver is not healthy. What should MediaStack do?" \
                    "Repair/reinstall Debian driver (recommended)" \
                    "Replace with Unlock NVENC (advanced)" \
                    "Use software transcoding" \
                    "Tell me more")
                case "$choice" in
                    "Repair/reinstall"*)
                        printf repair
                        return
                        ;;
                    "Replace with Unlock"*)
                        if _stage3_confirm_unlock >&2; then
                            printf unlock
                            return
                        fi
                        { ui_log skip "Unlock replacement cancelled; the Debian driver was not changed."; } >&2
                        ;;
                    "Use software"*)
                        printf software
                        return
                        ;;
                    "Tell me more"*) { _stage3_nvidia_mode_more_copy; } >&2 ;;
                    *)
                        printf repair
                        return
                        ;;
                esac
                ;;
            foreign:healthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "NVIDIA driver managed outside MediaStack. What should MediaStack do?" \
                    "Use existing driver with user-managed updates" \
                    "Reinstall (remove existing, choose driver mode)" \
                    "Use software transcoding")
                case "$choice" in
                    "Use existing"*)
                        printf use-existing
                        return
                        ;;
                    "Reinstall"*)
                        printf reinstall
                        return
                        ;;
                    "Use software"*)
                        printf software
                        return
                        ;;
                    *)
                        printf use-existing
                        return
                        ;;
                esac
                ;;
            foreign:unhealthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "NVIDIA driver managed outside MediaStack is not healthy. What should MediaStack do?" \
                    "Reinstall (remove existing, choose driver mode)" \
                    "Use software transcoding")
                case "$choice" in
                    "Reinstall"*)
                        printf reinstall
                        return
                        ;;
                    *)
                        printf software
                        return
                        ;;
                esac
                ;;
            *)
                printf software
                return
                ;;
        esac
    done
}

_stage3_nvidia_use_driver() {
    local mode="$1" message="$2"
    if ! _install_nvidia_container_toolkit; then
        _stage3_fallback "nvidia" "nvenc" || return $?
        return 0
    fi
    GPU_TYPE=nvidia
    verify_gpu_usable || true
    if [[ "$GPU_TYPE" == nvidia ]]; then
        local configure_rc=0
        _stage3_configure_and_verify "nvidia" "nvenc" "$message" "" "$mode" || configure_rc=$?
        ((configure_rc == 3)) && return 3
    else
        _stage3_fallback "nvidia" "nvenc" || return $?
    fi
    return 0
}

# Queue a reboot to finish NVIDIA setup, recording mode + install source in the
# marker so finalization resumes the right path (and patches only for unlock).
_stage3_nvidia_queue_reboot() {
    local mode="$1" source="$2" expected_version="${3:-}"
    stage3_write_nvidia_marker "$mode" "$source" "$expected_version"
    if ! stage3_set_gpu_env "none" "pending" "nvidia" "nvenc" "$mode"; then
        ui_log warn "Could not persist NVIDIA pending state; recovery marker retained."
        return 1
    fi
    ui_log warn "NVIDIA driver setup is ready for reboot. MediaStack will finish NVENC configuration after the reboot."
    ui_log info "Post-reboot GPU finalization queued: encoder=nvenc, test transcode, final summary."
    _stage3_print_final_summary
    if [[ "${STAGE3_DEFER_REBOOT_PROMPT:-false}" != "true" ]]; then
        stage3_prompt_nvidia_reboot
    fi
}

# Drive NVIDIA setup: pick the driver-management mode, then install via the
# Debian package (Standard, no patch) or the patch-managed .run (Unlock).
_stage3_run_nvidia() {
    local source health action
    # Optional forced source (used after a reinstall uninstalls the foreign
    # driver: nvidia-smi lingers on disk until reboot, so re-detection would
    # still report 'foreign' and loop the menu). Treat it as a clean install.
    source="${1:-$(nvidia_driver_source)}"
    if [[ -n "${1:-}" ]]; then health=unhealthy; elif nvidia_driver_healthy; then health=healthy; else health=unhealthy; fi
    action=$(_stage3_choose_nvidia_action "$source" "$health")

    case "$action" in
        software)
            _stage3_fallback "nvidia" "nvenc" || return $?
            return 0
            ;;
        reinstall)
            if ! command -v nvidia-uninstall &>/dev/null; then
                log_error "nvidia-uninstall not found — cannot remove the existing driver"
                log_info "Remove it manually (sudo nvidia-uninstall), then open Manage hardware transcoding (GPU) from the menu"
                _stage3_fallback "nvidia" "nvenc" || return $?
                return 0
            fi
            if ! ui_spin "Removing existing NVIDIA driver..." sudo nvidia-uninstall -s; then
                log_error "Failed to remove existing NVIDIA driver"
                log_info "Try manually: sudo nvidia-uninstall"
                _stage3_fallback "nvidia" "nvenc" || return $?
                return 0
            fi
            # nvidia-uninstall removes /usr/bin/nvidia-smi, but bash caches the
            # path from the earlier detection lookup — clear it so re-detection
            # (and install_nvidia_drivers' own check) don't see a phantom driver.
            hash -r
            log_ok "Existing NVIDIA driver removed"
            _stage3_run_nvidia none
            return $?
            ;;
        use)
            _stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified."
            return $?
            ;;
        use-existing)
            _stage3_nvidia_use_driver existing "NVIDIA NVENC configured and verified (you manage driver updates)."
            return $?
            ;;
        repair)
            if ! install_nvidia_drivers_apt repair; then
                _stage3_fallback "nvidia" "nvenc" || return $?
                return 0
            fi
            GPU_TYPE=nvidia
            if nvidia_driver_healthy; then
                _stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified after driver repair." || return $?
            else
                NEEDS_REBOOT=true
                _stage3_nvidia_queue_reboot standard apt || return $?
            fi
            return 0
            ;;
    esac

    if [[ "$action" == "standard" ]]; then
        local rc=0
        install_nvidia_drivers_apt || rc=$?
        if [[ "$rc" -ne 0 || "${GPU_TYPE:-none}" == "none" ]]; then
            _stage3_fallback "nvidia" "nvenc" || return $?
            return 0
        fi
        if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
            _stage3_nvidia_queue_reboot "standard" "apt"
            return $?
        fi
        verify_gpu_usable || true
        if [[ "${GPU_TYPE:-none}" == "nvidia" ]]; then
            local configure_rc=0
            _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified." "" "standard" || configure_rc=$?
            ((configure_rc == 3)) && return 3
        else
            _stage3_fallback "nvidia" "nvenc" || return $?
        fi
        return 0
    fi

    # Unlock (advanced): the patch-managed .run flow. A Debian-managed Standard
    # install is converted automatically by purging the exact installed driver
    # packages while preserving/repairing the NVIDIA container toolkit.
    if [[ "$source" == "debian" ]]; then
        if ! prepare_nvidia_debian_to_unlock; then
            _stage3_fallback "nvidia" "nvenc" || return $?
            return 0
        fi
        if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
            _stage3_nvidia_queue_reboot "unlock" "run"
            return $?
        fi
    fi
    if ! install_nvidia_drivers; then
        _stage3_fallback "nvidia" "nvenc" || return $?
        return 0
    fi
    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        _stage3_fallback "nvidia" "nvenc" || return $?
        return 0
    fi
    if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
        _stage3_nvidia_queue_reboot "unlock" "run"
        return $?
    fi
    # Patch failure keeps hardware NVENC (stock ~3-session limit), matching the
    # finalize path — only a driver-level failure falls back to software. The
    # marker is managed inside apply_nvidia_patch.
    if ! apply_nvidia_patch; then
        ui_log warn "NVENC Unlock patch did not apply - continuing with hardware NVENC at the stock session limit (~3 simultaneous transcodes). Retry via Manage hardware transcoding -> Reapply Unlock patch."
    fi
    verify_gpu_usable || true
    if [[ "${GPU_TYPE:-none}" == "nvidia" ]]; then
        local configure_rc=0
        _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified." "" "unlock" || configure_rc=$?
        ((configure_rc == 3)) && return 3
    else
        _stage3_fallback "nvidia" "nvenc" || return $?
    fi
    return 0
}

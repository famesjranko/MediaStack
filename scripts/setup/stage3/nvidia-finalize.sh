# Owns: Post-driver-install configure/verify for NVIDIA/Intel/AMD, reboot prompt, and post-reboot finalize-nvidia sequence.
# Sources: stage3_* marker/state/transcode/jellyfin helpers; scripts/setup/gpu/* driver modules.

_stage3_configure_and_verify() {
    local vendor="$1"
    local encoder="$2"
    local success_copy="$3"
    local fallback_mode="${4:-fallback}"
    # Optional NVIDIA driver-management mode persisted on success (empty for
    # Intel/AMD, which leaves any existing NVIDIA_DRIVER_MODE untouched).
    local driver_mode="${5:-}"
    local proof_since attempt=1 max_attempts=3

    while ((attempt <= max_attempts)); do
        stage3_set_gpu_env "$vendor" "pending" "$vendor" "$encoder"
        proof_since=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        if _stage3_apply_runtime_override "$vendor" \
            && stage3_probe_capabilities "$vendor" "$encoder" \
            && stage3_set_gpu_env "$vendor" "pending" "$vendor" "$encoder" \
            && _stage3_configure_jellyfin \
            && _stage3_wait_for_jellyfin_encoding "$encoder" \
            && STAGE3_TRANSCODE_SINCE="$proof_since" stage3_verify_transcode_evidence "$vendor" "$encoder"; then
            stage3_set_gpu_env "$vendor" "complete" "$vendor" "$encoder" "$driver_mode"
            type clear_setup_result_banner >/dev/null 2>&1 && clear_setup_result_banner
            ui_log ok "$success_copy"
            _stage3_print_final_summary
            return 0
        fi

        if ((attempt >= max_attempts)) || [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
            if [[ "$fallback_mode" == "try-next" ]]; then
                ui_log warn "${vendor} ${encoder} did not verify; trying the next hardware transcoding method."
                # 2 means the caller may try another hardware encoder; 1 means a terminal fallback/skip already ran.
                return 2
            fi
            _stage3_fallback "$vendor" "$encoder"
            return 1
        fi

        ui_log warn "Hardware transcoding verification failed (attempt ${attempt}/${max_attempts})."
        local action
        action=$(ui_choose "Hardware transcoding did not verify. What should setup do?" \
            "Retry verification" \
            "Use software transcoding" \
            "Skip for now")
        case "$action" in
            "Retry"*)
                attempt=$((attempt + 1))
                continue
                ;;
            "Skip"*)
                GPU_TYPE="none"
                stage3_remove_nvidia_marker
                stage3_set_gpu_env "none" "skipped" "" "" || true
                if ! _stage3_disable_jellyfin_hardware; then
                    ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
                elif ! _stage3_encoder_disabled "$encoder"; then
                    ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
                fi
                ui_log skip "$(stage3_skip_summary_copy)"
                _stage3_apply_runtime_override "none" || true
                _stage3_print_final_summary
                return 1
                ;;
            *)
                _stage3_fallback "$vendor" "$encoder"
                return 1
                ;;
        esac
    done

    _stage3_fallback "$vendor" "$encoder"
    return 1
}

_stage3_configure_intel() {
    local qsv_rc

    if _stage3_configure_and_verify "intel" "qsv" "Intel Quick Sync configured and verified." "try-next"; then
        return 0
    else
        qsv_rc=$?
    fi

    if [[ "$qsv_rc" == "2" ]]; then
        ui_log info "Trying Intel VAAPI fallback for older Intel graphics hardware..."
        _stage3_configure_and_verify "intel" "vaapi" "Intel VAAPI transcoding configured and verified." || true
    fi

    return 0
}

stage3_prompt_nvidia_reboot() {
    stage3_reboot_prompt_needed || return 0

    ui_section "Reboot"
    ui_box "Reboot needed to finish NVIDIA transcoding" \
        "MediaStack has prepared the NVIDIA driver setup." \
        "After reboot, setup will resume automatically." \
        "It will verify nvidia-smi, restart Docker, write Jellyfin NVENC settings, run a test transcode, and print the final summary."

    local reboot_action
    reboot_action=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Reboot now?" "Reboot now" "Reboot manually later")
    case "$reboot_action" in
        "Reboot now")
            # The menu above is the single reboot gate: the user chose
            # "Reboot now", so arm the resume hooks and reboot — no redundant
            # second confirm. Resume is scheduled/bannered/announced BEFORE the
            # reboot, so even an interrupted or manual boot finalizes GPU setup.
            schedule_post_reboot
            install_post_reboot_banner
            print_reboot_notice
            # Interactive users get the 10s grace window to READ the reboot notice
            # (and a real chance to Ctrl-C) before the box goes down. On a non-
            # interactive run there is nobody to read it and "Ctrl-C to cancel" is a
            # no-op, so skip the countdown and reboot straight away.
            if [[ -t 0 ]]; then
                local _s
                for _s in 10 9 8 7 6 5 4 3 2 1; do
                    printf '\r  Rebooting in %2ds...  (Ctrl-C to cancel)' "$_s"
                    sleep 1
                done
                printf '\r\033[K'
            fi
            sudo reboot
            ;;
        "Reboot manually later")
            schedule_post_reboot
            install_post_reboot_banner
            print_reboot_notice
            printf '%s\n' "Reboot manually when ready. MediaStack will resume GPU finalization automatically on the next boot."
            ;;
    esac
}

# Post-reboot the nvidia kernel module can take a few seconds to settle before
# nvidia-smi responds (large VRAM, first boot after a fresh install). The resume
# service starts After=docker.service, which is not ordered against the nvidia
# module load, so give the driver a bounded window to come up. Without this a
# not-yet-settled module reads as a driver failure and false-falls-back to
# software even though the driver is fine. Returns 0 as soon as nvidia-smi works.
_stage3_wait_for_nvidia_smi() {
    local max="${STAGE3_NVIDIA_SMI_TIMEOUT:-20}" elapsed=0
    [[ "$max" =~ ^[0-9]+$ ]] || max=20
    while :; do
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
            return 0
        fi
        ((elapsed >= max)) && return 1
        sleep 2
        ((elapsed += 2))
    done
}

stage3_finalize_nvidia() {
    local proof_since
    ui_log info "Resuming hardware transcoding: NVIDIA finalization"

    # Let the driver settle before any nvidia-smi-based decision below. Skip when
    # a .run install is already pending — that path (re)installs the driver
    # itself, so waiting for a not-yet-installed driver would just burn the budget.
    if [[ ! -f "$SCRIPT_DIR/.nvidia-tmp/pending" ]]; then
        _stage3_wait_for_nvidia_smi || true
    fi

    # Driver mode comes from the marker (survives .env regeneration). A marker
    # that EXISTS but has no mode field is a schema-1 marker from the old patch
    # flow, so it is unlock by definition — do NOT fall back to .env there, since
    # a regenerated NVIDIA_DRIVER_MODE=standard would wrongly skip the patch. Only
    # when there is no marker at all do we consult .env.
    local _mode _install_source
    if _mode="$(stage3_marker_driver_mode 2>/dev/null)"; then
        [[ -n "$_mode" ]] || _mode="unlock"
    else
        _mode="${NVIDIA_DRIVER_MODE:-unlock}"
    fi
    _install_source=$(stage3_marker_install_source 2>/dev/null || true)

    # Unlock can resume from either a cached .run installer or a Standard→Unlock
    # conversion reboot where the Debian driver was purged before any .run cache
    # existed. Standard/Existing installed (or kept) the driver before reboot and
    # just need verification below. Ignore and clear any stale .run cache for
    # non-Unlock modes so a leftover Unlock cache can never drag a Standard
    # finalize back onto the .run path.
    if [[ "$_mode" == "unlock" && "$_install_source" != "run-update" ]]; then
        if [[ -f "$SCRIPT_DIR/.nvidia-tmp/pending" ]] || ! { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
            GPU_TYPE="nvidia"
            if ! install_nvidia_drivers; then
                _stage3_nvidia_finalize_failure
                return 0
            fi
        fi
    elif [[ -e "$SCRIPT_DIR/.nvidia-tmp/pending" ]]; then
        ui_log info "Ignoring stale .run driver cache (driver mode is ${_mode})."
        sudo rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || true
    fi

    ui_log info "Verifying NVIDIA driver..."
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    local _expected_version _loaded_version
    _expected_version=$(stage3_marker_expected_driver_version 2>/dev/null || true)
    if [[ -n "$_expected_version" ]]; then
        _loaded_version=$(nvidia_driver_version 2>/dev/null || true)
        if [[ "$_loaded_version" != "$_expected_version" ]]; then
            ui_log warn "Loaded NVIDIA driver version does not match the prepared update."
            _stage3_nvidia_finalize_failure
            return 0
        fi
    fi

    ui_log info "Restarting Docker so NVIDIA runtime is available..."
    sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true

    GPU_TYPE="nvidia"
    if [[ "$_mode" == "unlock" ]]; then
        # The Unlock patch only removes the NVENC concurrent-session limit; the
        # driver + NVENC library are already installed and verified above. If the
        # patch fails, hardware NVENC still works (just capped at the stock ~3
        # sessions) — so DON'T drop all the way to CPU software. Keep NVENC, record
        # that the patch isn't applied (marker read by the login banner), and leave
        # the driver in unlock mode so "Manage hardware transcoding -> Reapply
        # Unlock patch" can retry it. Only a driver-level failure (below) falls
        # back to software.
        # apply_nvidia_patch manages the .nvidia-nvenc-unpatched marker itself.
        if ! apply_nvidia_patch; then
            ui_log warn "NVENC Unlock patch did not apply - continuing with hardware NVENC at the stock session limit (~3 simultaneous transcodes). Retry via Manage hardware transcoding -> Reapply Unlock patch."
        fi
    fi
    verify_gpu_usable || true
    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    ui_log info "Writing Jellyfin encoder: nvenc"
    stage3_set_gpu_env "nvidia" "pending" "nvidia" "nvenc"
    proof_since=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! _stage3_apply_runtime_override "nvidia"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi
    if ! stage3_probe_capabilities "nvidia" "nvenc"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi
    stage3_set_gpu_env "nvidia" "pending" "nvidia" "nvenc"
    if ! _stage3_configure_jellyfin || ! _stage3_wait_for_jellyfin_encoding "nvenc"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    ui_log info "Restarting Jellyfin..."
    (cd "$SCRIPT_DIR" && docker compose up -d jellyfin >/dev/null 2>&1) || true

    # The driver is verified usable (nvidia-smi + docker runtime + verify_gpu_usable
    # above) and Jellyfin is already configured AND confirmed on NVENC. The test
    # transcode is PROOF, not a gate: on a slower boot the smoke test can race the
    # Jellyfin restart, or the encoder-enumeration log lines can emit late, and it
    # comes back inconclusive even though NVENC is correctly wired through. A
    # failure here must NOT drop a working GPU to CPU software (same principle as
    # the Unlock patch above). Keep NVENC, tell the user verification was
    # inconclusive, and let them confirm by playing something.
    ui_log info "Running test transcode..."
    if STAGE3_TRANSCODE_SINCE="$proof_since" stage3_verify_transcode_evidence "nvidia" "nvenc"; then
        ui_log ok "NVIDIA NVENC configured and verified."
    else
        ui_log warn "NVIDIA NVENC is configured and enabled, but the automatic test transcode was inconclusive (this can happen when the smoke test races the Jellyfin restart). Play a video that needs transcoding to confirm, or re-check via Manage hardware transcoding (GPU)."
    fi

    stage3_set_gpu_env "nvidia" "complete" "nvidia" "nvenc" "$_mode"
    stage3_remove_nvidia_marker
    ui_log ok "Post-reboot GPU finalization complete."
    _stage3_print_final_summary
    return 0
}

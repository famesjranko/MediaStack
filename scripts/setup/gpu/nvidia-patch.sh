# Owns: NVIDIA Unlock patch application and patch-state marker handling.
# Sources: gpu.sh globals, nvidia-patch.sh, and NVIDIA driver helpers.
apply_nvidia_patch() {
    local _marker="$SCRIPT_DIR/.nvidia-nvenc-unpatched" _rc=0
    # Suspend errexit for the impl call: callers reach this bare under a top-level
    # `set -e` (setup.sh --nvidia-unlock-repatch → run_nvidia_unlock_maintenance →
    # here), where a bare `_apply_nvidia_patch_impl; _rc=$?` would abort before the
    # marker is touched, leaving a false "patch applied" banner state.
    _apply_nvidia_patch_impl || _rc=$?
    if ((_rc == 0)); then rm -f "$_marker"; else touch "$_marker"; fi
    return "$_rc"
}

_apply_nvidia_patch_impl() {
    # Only run if NVIDIA drivers are loaded
    if ! command -v nvidia-smi &>/dev/null; then
        log_warn "NVIDIA driver is not loaded - cannot apply Unlock patch"
        return 1
    fi

    local patch_dir="$SCRIPT_DIR/.nvidia-patch"
    local patch_run_dir=""

    if ! nvidia_patch_prepare_repo "$patch_dir"; then
        log_warn "nvidia-patch verification failed - skip (update MediaStack or clean .nvidia-patch)"
        return 1
    fi

    patch_run_dir=$(nvidia_patch_export_run_tree "$patch_dir") || {
        log_warn "nvidia-patch export failed - skip"
        return 1
    }

    local driver_ver
    driver_ver=$(nvidia_driver_version 2>/dev/null || true)
    if [[ -z "$driver_ver" ]]; then
        log_warn "Cannot detect NVIDIA driver version - skipping patch"
        rm -rf "$patch_run_dir"
        return 1
    fi

    log_info "NVIDIA driver version: $driver_ver"

    # Check if patch supports this driver version
    if ! bash "$patch_run_dir/patch.sh" -c "$driver_ver" &>/dev/null; then
        log_warn "nvidia-patch does not support driver $driver_ver - skipping"
        rm -rf "$patch_run_dir"
        return 1
    fi

    # Apply NVENC patch (removes encoding session limit)
    log_info "Applying NVENC patch..."
    if sudo bash "$patch_run_dir/patch.sh" -s 2>/dev/null; then
        log_ok "NVENC patch applied (encoding session limit removed)"
    else
        log_warn "NVENC patch failed (may already be applied or unsupported)"
        rm -rf "$patch_run_dir"
        return 1
    fi

    # Apply NvFBC patch (enables framebuffer capture on consumer GPUs)
    if [[ -f "$patch_run_dir/patch-fbc.sh" ]]; then
        log_info "Applying NvFBC patch..."
        if sudo bash "$patch_run_dir/patch-fbc.sh" -s 2>/dev/null; then
            log_ok "NvFBC patch applied"
        else
            log_warn "NvFBC patch failed (may already be applied or unsupported)"
        fi
    fi

    rm -rf "$patch_run_dir"
    return 0
}

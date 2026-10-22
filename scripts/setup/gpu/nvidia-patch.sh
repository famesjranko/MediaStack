# Owns: apply_* — NVIDIA Unlock patch application and patch-state marker handling.
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

# Remove what the Unlock patch step left on the host once its driver is gone.
# patch.sh rewrites libnvidia-encode.so.<ver> and libnvidia-fbc.so.<ver> in place
# and keeps the originals under /opt/nvidia/libnvidia-{encode,fbc}-backup. A
# driver removal can leave those patched files, the .so.1 links to them and the
# backups behind, and the next (Debian) driver then meets a stale old version.
# Only versions with a backup are touched: the backup proves MediaStack patched
# that file. The originals are not restored because the driver they belong to is
# being removed. Lists what it removes, then re-checks that none of it remains.
# Seams for tests: MS_NVIDIA_LIB_DIRS, MS_NVIDIA_BACKUP_ROOT.
apply_nvidia_patch_cleanup() {
    local root="${MS_NVIDIA_BACKUP_ROOT:-/opt/nvidia}"
    local lib_dirs="${MS_NVIDIA_LIB_DIRS:-/usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib/aarch64-linux-gnu /usr/lib}"
    local lib backup_dir f v dir link target
    local versions=() victims=() backups=()

    for lib in encode fbc; do
        backup_dir="$root/libnvidia-$lib-backup"
        [[ -d "$backup_dir" ]] || continue
        backups+=("$backup_dir")
        # Backup files are named libnvidia-<lib>.so.<ver>, flat or in a <ver>/ subdirectory.
        while IFS= read -r f; do
            v="${f##*/libnvidia-"$lib".so.}"
            [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] && versions+=("$lib:$v")
        done < <(sudo find "$backup_dir" -type f -name "libnvidia-$lib.so.*" 2>/dev/null)
    done
    if ((${#backups[@]} == 0)); then
        rm -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched"
        return 0
    fi

    for dir in $lib_dirs; do
        for v in "${versions[@]}"; do
            lib="${v%%:*}"
            f="$dir/libnvidia-$lib.so.${v#*:}"
            if [[ -e "$f" || -L "$f" ]]; then victims+=("$f"); fi
            link="$dir/libnvidia-$lib.so.1"
            if [[ -L "$link" ]]; then
                target="$(readlink "$link")"
                if [[ "${target##*/}" == "libnvidia-$lib.so.${v#*:}" ]]; then victims+=("$link"); fi
            fi
        done
    done

    if ((${#victims[@]} > 0)); then
        log_info "Removing NVIDIA Unlock patch leftovers: ${victims[*]}"
        sudo rm -f -- "${victims[@]}" || return 1
    fi
    sudo rm -rf -- "${backups[@]}" || return 1
    sudo rmdir --ignore-fail-on-non-empty "$root" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched"
    # Refresh the linker cache so it stops resolving the removed libraries.
    sudo ldconfig 2>/dev/null || true

    for f in "${victims[@]}" "${backups[@]}"; do
        if [[ -e "$f" || -L "$f" ]]; then
            log_error "NVIDIA Unlock patch leftover was not removed: $f"
            return 1
        fi
    done
    return 0
}

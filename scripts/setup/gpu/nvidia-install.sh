# Owns: NVIDIA Unlock driver installation and container-toolkit setup.
# Sources: gpu.sh globals, NVIDIA driver helpers, and common.sh logging.
# shellcheck disable=SC2034 # NEEDS_REBOOT and GPU_TYPE are published globals.
install_nvidia_drivers() {
    # Short-circuit only when the driver actually WORKS, not merely when the
    # nvidia-smi binary exists. After prepare_nvidia_debian_to_unlock purges the
    # Debian driver (or a foreign uninstall), the binary can linger while the
    # driver is gone — a bare `command -v nvidia-smi` would then wrongly report
    # "already installed" and skip the real .run install, leaving apply_nvidia_patch
    # with no version to patch. nvidia_driver_healthy checks nvidia-smi -L works.
    if nvidia_driver_healthy; then
        log_ok "NVIDIA drivers already installed: $(nvidia_driver_version 2>/dev/null || echo 'unknown version')"
        # Still need nvidia-container-toolkit
        if ! _install_nvidia_container_toolkit; then
            GPU_TYPE="none"
            return 1
        fi
        return 0
    fi

    local _nvidia_tmp="$SCRIPT_DIR/.nvidia-tmp"

    # Post-reboot resume: cached .run from a pre-reboot run
    if [[ -f "$_nvidia_tmp/pending" ]]; then
        if ! source "$_nvidia_tmp/pending"; then
            log_error "Could not read cached NVIDIA driver metadata"
            log_warn "Falling back to software transcoding"
            GPU_TYPE="none"
            sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
            return 1
        fi
        if nvidia_driver_nouveau_is_active; then
            log_error "Nouveau is still active after reboot - blacklist may have failed"
            log_warn "Falling back to software transcoding"
            GPU_TYPE="none"
            sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
            return 1
        fi
        if [[ ! -f "$_run_file" ]]; then
            log_error "Cached driver not found at $_run_file"
            log_warn "Falling back to software transcoding"
            GPU_TYPE="none"
            sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
            return 1
        fi
        log_info "Resuming NVIDIA driver install (post-reboot)..."
        if ! _nvidia_driver_install_run_file "$_run_file" "$_driver_ver" "$_nvidia_tmp"; then
            log_error "NVIDIA driver installation failed"
            log_warn "Falling back to software transcoding"
            GPU_TYPE="none"
            sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
            return 1
        fi
        sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
        log_ok "NVIDIA driver ${_driver_ver} installed"
        if ! _install_nvidia_container_toolkit; then
            GPU_TYPE="none"
            return 1
        fi
        return 0
    fi

    local sb_state
    sb_state=$(nvidia_driver_check_secure_boot)
    case "$sb_state" in
        enabled)
            log_error "Secure Boot is enabled - the NVIDIA kernel module will not load."
            log_error "Fix one of the following, then re-run setup.sh:"
            log_error "  (a) disable Secure Boot in UEFI firmware settings, OR"
            log_error "  (b) enroll a Machine Owner Key to sign the nvidia module (advanced)."
            log_warn "Falling back to software transcoding; GPU acceleration will not be configured."
            GPU_TYPE="none"
            return 1
            ;;
        disabled)
            log_ok "Secure Boot is disabled"
            ;;
        unavailable)
            log_warn "mokutil not found; cannot verify Secure Boot state - proceeding (driver may fail to load if SB is on)"
            ;;
    esac

    if ! ui_spin "Installing kernel headers and build prerequisites..." \
        sudo apt-get install -y -qq "linux-headers-$(uname -r)" build-essential dkms pkg-config libglvnd-dev; then
        log_error "Failed to install NVIDIA kernel build prerequisites"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    # Blacklist nouveau unconditionally for NVIDIA installs — the installer
    # checks sysfs PCI binding, not just lsmod, so we must ensure nouveau
    # is fully gone before running it.
    if ! nvidia_driver_blacklist_nouveau; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi
    nvidia_driver_try_unload_nouveau || true

    if ! mkdir -p "$_nvidia_tmp"; then
        log_error "Failed to create NVIDIA driver cache directory"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    local _driver_ver="" _run_file=""
    if ! nvidia_driver_resolve_driver; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
        return 1
    fi

    # If nouveau is still active, we cannot run the installer — it will
    # either abort (without --no-nouveau-check) or compile-then-rollback
    # (with it). Cache the .run and reboot instead.
    if nvidia_driver_nouveau_is_active; then
        log_warn "Nouveau is still bound to the GPU - caching driver for post-reboot install"
        if ! cat >"$_nvidia_tmp/pending" <<EOF; then
_driver_ver='${_driver_ver}'
_run_file='${_run_file}'
EOF
            log_error "Failed to write NVIDIA post-reboot install marker"
            log_warn "Falling back to software transcoding"
            GPU_TYPE="none"
            sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
            return 1
        fi
        NEEDS_REBOOT=true
        log_ok "NVIDIA driver ${_driver_ver} downloaded (will install after reboot)"
        return 0
    fi

    # Nouveau is gone — install now
    if ! _nvidia_driver_install_run_file "$_run_file" "$_driver_ver" "$_nvidia_tmp"; then
        log_error "NVIDIA driver installation failed"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
        return 1
    fi

    sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
    NEEDS_REBOOT=true
    log_ok "NVIDIA driver ${_driver_ver} installed (reboot required)"

    if ! _install_nvidia_container_toolkit; then
        GPU_TYPE="none"
        return 1
    fi
    return 0
}

_nvidia_toolkit_healthy() {
    command -v nvidia-container-runtime &>/dev/null || return 1
    command -v nvidia-container-cli &>/dev/null || return 1
    if ldd "$(command -v nvidia-container-cli)" 2>/dev/null | grep -q 'not found'; then
        return 1
    fi
    return 0
}

_configure_nvidia_container_toolkit() {
    if ! ui_spin "Configuring Docker NVIDIA runtime..." \
        sudo nvidia-ctk runtime configure --runtime=docker; then
        log_error "Failed to configure nvidia-container-toolkit runtime"
        return 1
    fi
    if ! sudo systemctl restart docker; then
        log_error "Failed to restart Docker after nvidia-container-toolkit configuration"
        return 1
    fi
}

_install_nvidia_container_toolkit() {
    if _nvidia_toolkit_healthy; then
        log_ok "nvidia-container-toolkit already installed"
        return 0
    else
        log_info "Installing/repairing nvidia-container-toolkit..."

        if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
            log_error "Failed to install NVIDIA container toolkit apt key"
            return 1
        fi

        if ! curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null; then
            log_error "Failed to install NVIDIA container toolkit apt source"
            return 1
        fi

        if ! ui_spin "Updating package lists..." sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for nvidia-container-toolkit"
            return 1
        fi
        if ! ui_spin "Installing nvidia-container-toolkit..." \
            sudo apt-get install -y -qq --reinstall \
            libnvidia-container1 libnvidia-container-tools \
            nvidia-container-toolkit-base nvidia-container-toolkit; then
            log_error "Failed to install nvidia-container-toolkit"
            return 1
        fi

        _configure_nvidia_container_toolkit || return 1
        log_ok "nvidia-container-toolkit installed and configured"
        return 0
    fi
}

# Classify NVIDIA ownership independently of runtime health.

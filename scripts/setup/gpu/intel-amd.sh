# Owns: Intel and AMD media-driver installation and render-device reporting.
# Sources: gpu.sh render-device helpers, apt helpers, and common.sh logging.
install_intel_drivers() {
    local render_device
    render_device="$(gpu_render_device_for_vendor intel || true)"
    if [[ -n "$render_device" ]]; then
        log_ok "Intel GPU render device available at $render_device"
    fi

    if ! dpkg -l intel-media-va-driver-non-free &>/dev/null 2>&1; then
        log_info "Installing Intel media drivers for hardware transcoding..."
        if ! ensure_debian_nonfree; then
            return 1
        fi
        if ! ui_spin "Updating package lists..." sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for Intel media drivers"
            return 1
        fi
        if ! ui_spin "Installing intel-media-va-driver-non-free..." \
            sudo apt-get install -y -qq intel-media-va-driver-non-free vainfo; then
            log_error "Failed to install Intel media drivers"
            return 1
        fi
        log_ok "Intel media drivers installed"
    else
        log_ok "Intel media drivers already installed"
    fi
    return 0
}

install_amd_drivers() {
    local render_device
    render_device="$(gpu_render_device_for_vendor amd || true)"
    if [[ -n "$render_device" ]]; then
        log_ok "AMD GPU render device available at $render_device"
    fi

    if ! dpkg -l mesa-va-drivers &>/dev/null 2>&1; then
        log_info "Installing AMD VAAPI drivers for hardware transcoding..."
        if ! ensure_debian_nonfree; then
            return 1
        fi
        if ! ui_spin "Updating package lists..." sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for AMD VAAPI drivers"
            return 1
        fi
        if ! ui_spin "Installing mesa-va-drivers..." \
            sudo apt-get install -y -qq mesa-va-drivers vainfo; then
            log_error "Failed to install AMD VAAPI drivers"
            return 1
        fi
        log_ok "AMD VAAPI drivers installed"
    else
        log_ok "AMD VAAPI drivers already installed"
    fi
    return 0
}

# Report whether Docker has the NVIDIA runtime registered: prints exactly one
# of "registered", "absent", or "unknown".
#
# This MUST be robust. The prior check here was `docker info | grep -qi nvidia`,
# a single un-retried pipe-into-grep-q. Under `set -euo pipefail` that is doubly
# fragile: (1) grep -q exits on first match and closes the pipe, so `docker info`
# takes SIGPIPE and pipefail propagates the non-zero exit — a false negative even
# when nvidia IS present; (2) in the post-install window (a dozen containers just
# starting on a small box) `docker info` itself is briefly slow or fails, and the
# lone check had no retry. Either way the wizard silently and permanently fell
# back to software transcoding on a correctly-configured host.
#
# Robust approach: capture (no pipe), match the runtime KEY precisely via a
# keys-only template (not a substring grep of the whole multi-KB blob), and retry
# to ride out the transient window. "unknown" means the daemon could not be
# queried — NOT that the runtime is absent; callers must treat the two differently.

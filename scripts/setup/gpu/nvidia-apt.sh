# Owns: Debian NVIDIA driver ownership, repair, and apt installation routes.
# Sources: gpu.sh globals, NVIDIA preparation helpers, and common.sh logging.
# shellcheck disable=SC2034 # GPU_TYPE is a published global consumed by callers.
nvidia_driver_source() {
    local _st
    _st=$(dpkg-query -W -f='${Status}' nvidia-driver 2>/dev/null || true)
    case "$_st" in
        *"install ok installed"*)
            printf 'debian'
            return 0
            ;;
    esac
    command -v nvidia-smi &>/dev/null && printf 'foreign' || printf 'none'
}

nvidia_driver_healthy() {
    command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null
}

nvidia_driver_version() {
    local versions
    versions=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
        | sed '/^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u) || return 1
    [[ -n "$versions" && "$versions" != *$'\n'* ]] || return 1
    printf '%s' "$versions"
}

_nvidia_debian_driver_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' '*nvidia*' '*cuda*' 'glx-*' 2>/dev/null \
        | awk '$2 == "ii" {print $1}' \
        | grep -Ev '^(nvidia-container-toolkit|nvidia-container-toolkit-base|libnvidia-container-tools|libnvidia-container1(:amd64)?|glx-alternative-mesa)$' \
        | sort -u
}

_nvidia_debian_repair_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 2>/dev/null \
        | awk '$2 == "ii" {print $1}' \
        | grep -E '^(nvidia-|libnvidia-|libcuda1(:|$)|lib(glx|egl|gles)-nvidia|xserver-xorg-video-nvidia|firmware-nvidia-|glx-alternative-nvidia|glx-diversions)' \
        | grep -Ev '^(nvidia-container-toolkit|nvidia-container-toolkit-base|libnvidia-container[^:]*)(:.*)?$' \
        | sort -u
}

_nvidia_unload_loaded_modules() {
    sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
    local _modules
    _modules=$(lsmod 2>/dev/null || true)
    [[ "$_modules" != nvidia* && "$_modules" != *$'\n'nvidia* ]]
}

# Prepare a Debian-managed Standard install for the patch-managed .run driver.
# Exact installed package names are purged so the NVIDIA container toolkit stays
# intact; wildcard apt patterns would remove the toolkit too. If loaded NVIDIA
# modules cannot be removed, the caller queues an Unlock resume after reboot.
prepare_nvidia_debian_to_unlock() {
    local _pkgs=()
    mapfile -t _pkgs < <(_nvidia_debian_driver_packages)
    if [[ "${#_pkgs[@]}" -eq 0 ]]; then
        return 0
    fi

    sudo apt-mark manual nvidia-container-toolkit nvidia-container-toolkit-base \
        libnvidia-container-tools libnvidia-container1 >/dev/null 2>&1 || true
    if ! ui_spin "Removing Debian NVIDIA driver packages..." \
        sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${_pkgs[@]}"; then
        log_error "Failed to remove Debian NVIDIA driver packages"
        return 1
    fi
    # Purge removed /usr/bin/nvidia-smi; clear bash's cached path so later
    # command lookups (install_nvidia_drivers' health check) don't see a phantom.
    hash -r

    if _nvidia_unload_loaded_modules; then
        log_ok "Loaded Debian NVIDIA modules unloaded"
        return 0
    fi

    if ! nvidia_driver_blacklist_nouveau; then
        return 1
    fi
    NEEDS_REBOOT=true
    log_warn "Loaded NVIDIA modules are still active - reboot required before installing the patch-managed driver"
    return 0
}

# Decide which Debian nvidia-driver to install. Prefer the normal apt candidate;
# escalate to ${codename}-backports ONLY when positive supportedchips/PCI evidence
# shows the normal candidate can't drive this GPU and backports has a newer
# candidate that can. No hard-coded version numbers. Echoes the apt-get install
# argument list (may begin with "-t <release>") for install_nvidia_drivers_apt().
_resolve_debian_nvidia_driver() {
    local _pkg_args="nvidia-driver firmware-misc-nonfree"
    local _codename
    _codename=$(nvidia_driver_debian_codename)

    local _cand
    _cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "")
    if [[ -z "$_cand" || -z "$_codename" ]]; then
        printf '%s' "$_pkg_args"
        return 0
    fi

    local _pci_id=""
    _pci_id=$(lspci -nn 2>/dev/null | grep -i 'nvidia' | grep -oP '\[10de:\K\w+' | head -1) || true
    if [[ -z "$_pci_id" ]]; then
        printf '%s' "$_pkg_args"
        return 0
    fi

    # The normal candidate already lists this GPU as current — keep it.
    local _normal_compat
    _normal_compat=$(_nvidia_driver_check_compat "${_cand%%-*}" "$_pci_id" 2>/dev/null) || _normal_compat=""
    if [[ "$_normal_compat" == "current" ]]; then
        printf '%s' "$_pkg_args"
        return 0
    fi

    # Escalate only on positive evidence: backports has a strictly-newer candidate
    # that lists this GPU as current.
    local _bp_cand
    _bp_cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "${_codename}-backports")
    if [[ -n "$_bp_cand" ]] && dpkg --compare-versions "$_bp_cand" gt "$_cand"; then
        local _bp_compat
        _bp_compat=$(_nvidia_driver_check_compat "${_bp_cand%%-*}" "$_pci_id" 2>/dev/null) || _bp_compat=""
        if [[ "$_bp_compat" == "current" ]]; then
            log_info "GPU needs a newer driver - selecting ${_codename}-backports"
            printf '%s' "-t ${_codename}-backports $_pkg_args"
            return 0
        fi
    fi

    printf '%s' "$_pkg_args"
}

# Derive the Debian kernel-flavor suffix from `uname -r` (e.g. "6.1.0-51-cloud-amd64"
# → "cloud-amd64", "6.1.0-18-amd64" → "amd64"). Debian kernel releases are
# "<upstream-version>-<abi>-<flavor>"; a release with no ABI segment (custom kernel,
# not a Debian package build) has no derivable flavor and fails.
_nvidia_headers_flavor() {
    local _rel="$1"
    [[ "$_rel" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-(.+)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# Resolve an installable linux-headers package for the given `uname -r` value.
# Prefers the exact per-build package (matches the running kernel precisely);
# falls back to the flavor meta-package apt tracks automatically across kernel
# bumps. Fails (no output) when neither resolves to an apt candidate.
_nvidia_headers_candidate() {
    local _running="$1"
    if [[ -n "$(nvidia_driver_apt_candidate_version "linux-headers-${_running}" "")" ]]; then
        printf 'linux-headers-%s' "$_running"
        return 0
    fi
    local _flavor
    _flavor=$(_nvidia_headers_flavor "$_running") || return 1
    if [[ -n "$(nvidia_driver_apt_candidate_version "linux-headers-${_flavor}" "")" ]]; then
        printf 'linux-headers-%s' "$_flavor"
        return 0
    fi
    return 1
}

# Preflight for the silent-DKMS-skip failure mode: nvidia-driver installs fine
# via apt but DKMS quietly skips the module build when no headers match the
# running kernel, and the gap only surfaces later at verify time. Echoes a
# headers package to append to the driver install transaction, or nothing if
# headers for the running kernel are already installed. Returns 1 (caller
# falls back to software transcoding) when no headers package is resolvable.
_nvidia_preflight_kernel_headers() {
    local _running
    _running=$(uname -r)

    local _st
    _st=$(dpkg-query -W -f='${Status}' "linux-headers-${_running}" 2>/dev/null || true)
    if [[ "$_st" == *"install ok installed"* ]]; then
        return 0
    fi

    local _hdr_pkg
    if _hdr_pkg=$(_nvidia_headers_candidate "$_running"); then
        printf '%s' "$_hdr_pkg"
        return 0
    fi

    local _flavor=""
    _flavor=$(_nvidia_headers_flavor "$_running") || _flavor=""
    log_error "No kernel headers package available for running kernel ${_running} (looked for linux-headers-${_running}${_flavor:+, linux-headers-${_flavor}})"
    return 1
}

# Standard mode: install the Debian-packaged NVIDIA driver (NO nvidia-patch).
# Distro-managed, survives apt upgrade, official NVENC session limits. On any
# failure sets GPU_TYPE="none" and returns 1 (caller falls back to software).
# Return 2 signals a pre-existing non-Debian driver — the caller decides whether
# to keep it (mode "existing") or abort. May set NEEDS_REBOOT=true.
install_nvidia_drivers_apt() {
    local operation="${1:-install}"
    local _source
    _source=$(nvidia_driver_source)
    case "$_source" in
        debian)
            if [[ "$operation" != "repair" ]]; then
                log_ok "Debian-managed NVIDIA driver already installed: $(nvidia_driver_version 2>/dev/null || echo unknown)"
                if ! _install_nvidia_container_toolkit; then
                    GPU_TYPE="none"
                    return 1
                fi
                NVIDIA_DRIVER_MODE="standard"
                return 0
            fi
            ;;
        foreign)
            # A working driver exists but MediaStack did not install it via apt;
            # Standard must not claim it. Caller prompts continue/abort.
            return 2
            ;;
    esac

    local sb_state
    sb_state=$(nvidia_driver_check_secure_boot)
    case "$sb_state" in
        enabled)
            log_error "Secure Boot is enabled - the NVIDIA kernel module will not load."
            log_error "Disable Secure Boot in UEFI, or enroll a Machine Owner Key (advanced), then re-run setup.sh."
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

    if ! nvidia_driver_ensure_debian_nonfree; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi
    if ! sudo apt-get update -qq; then
        log_error "Failed to update apt metadata for the NVIDIA driver"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    if [[ "$operation" == "repair" ]]; then
        local _repair_packages=()
        mapfile -t _repair_packages < <(_nvidia_debian_repair_packages)
        if ((${#_repair_packages[@]} == 0)); then
            log_error "No installed Debian NVIDIA packages were found to repair"
            GPU_TYPE="none"
            return 1
        fi
        if ! ui_spin "Repairing Debian NVIDIA driver packages..." \
            sudo apt-get install -y -qq --reinstall "${_repair_packages[@]}"; then
            log_error "Failed to repair the Debian NVIDIA driver packages"
            GPU_TYPE="none"
            return 1
        fi
        if ! _nvidia_toolkit_healthy || ! _configure_nvidia_container_toolkit; then
            log_error "NVIDIA container toolkit repair failed"
            GPU_TYPE="none"
            return 1
        fi
        NVIDIA_DRIVER_MODE="standard"
        return 0
    fi

    # If the normal candidate can't drive this (too-new) GPU, enable a managed
    # backports source and refresh apt so the resolver can see a newer candidate.
    # Without this, backports escalation is unreachable on a clean host (the
    # resolver could never find a backports candidate to compare against).
    local _gate_cand _gate_pci="" _gate_compat=""
    _gate_cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "")
    _gate_pci=$(lspci -nn 2>/dev/null | grep -i 'nvidia' | grep -oP '\[10de:\K\w+' | head -1) || true
    if [[ -n "$_gate_cand" && -n "$_gate_pci" ]]; then
        _gate_compat=$(_nvidia_driver_check_compat "${_gate_cand%%-*}" "$_gate_pci" 2>/dev/null) || _gate_compat=""
        if [[ "$_gate_compat" != "current" ]] && nvidia_driver_ensure_debian_backports; then
            sudo apt-get update -qq || true
        fi
    fi

    # DKMS silently skips the module build with no matching kernel headers, so
    # the driver install "succeeds" and the failure only surfaces later. Resolve
    # headers for the running kernel before touching the driver package.
    local _headers_pkg
    if ! _headers_pkg=$(_nvidia_preflight_kernel_headers); then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    local _install_args
    _install_args=$(_resolve_debian_nvidia_driver)
    if [[ -n "$_headers_pkg" ]]; then
        # "-t <release>" scopes every package in the transaction to backports,
        # which could swap the flavor meta-package for headers matching a kernel
        # other than the running one. Pin the preflight-validated candidate so
        # the headers DKMS builds against are exactly the ones verified.
        if [[ "$_install_args" == "-t "* ]]; then
            local _hdr_ver
            _hdr_ver=$(nvidia_driver_apt_candidate_version "$_headers_pkg" "")
            [[ -n "$_hdr_ver" ]] && _headers_pkg="${_headers_pkg}=${_hdr_ver}"
        fi
        _install_args="$_install_args $_headers_pkg"
    fi
    # shellcheck disable=SC2086  # _install_args is a controlled arg list (may include "-t <release>")
    if ! ui_spin "Installing Debian NVIDIA driver via apt (${_install_args})..." \
        sudo apt-get install -y -qq $_install_args; then
        log_error "Failed to install the Debian nvidia-driver package"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi
    log_ok "Debian NVIDIA driver installed"

    if ! _install_nvidia_container_toolkit; then
        GPU_TYPE="none"
        return 1
    fi

    # Read by env-gen.sh / stage3.sh / nvidia-repatch.sh, not within gpu.sh.
    # shellcheck disable=SC2034
    NVIDIA_DRIVER_MODE="standard"
    # The Debian package blacklists nouveau and builds the module via DKMS, but a
    # reboot is needed to swap nouveau->nvidia before nvidia-smi works.
    if nvidia_driver_nouveau_is_active || ! { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
        # Read by stage3.sh reboot gating, not within gpu.sh.
        # shellcheck disable=SC2034
        NEEDS_REBOOT=true
        log_ok "Debian NVIDIA driver installed (reboot required to load the kernel module)"
    fi
    return 0
}

# Apply nvidia-patch to remove NVENC session limits on consumer GPUs
# See: https://github.com/keylase/nvidia-patch
# Apply the NVENC/NvFBC Unlock patches, and keep the single source of truth for
# the "session limit not removed" marker in sync. The marker is read by the login
# banner (reboot.sh) and ./mediastack; centralizing it here means every caller —
# stage3 finalize, the inline path, and the recovery "Reapply Unlock patch" — stays
# consistent (a successful repatch clears it; a failure sets it). rc 0 = applied.

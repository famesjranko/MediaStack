# Owns: Debian NVIDIA driver ownership, repair, and apt installation routes.
# Sources: gpu.sh globals, NVIDIA preparation helpers, and common.sh logging.
# shellcheck disable=SC2034 # GPU_TYPE is a published global consumed by callers.
# shellcheck source=/dev/null
declare -F host_tool_path >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/host-tools.sh"
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
    # lsmod lives in /usr/sbin, off a normal user's PATH; a bare call reads as "nothing loaded".
    _modules=$("$(host_tool_path lsmod || echo lsmod)" 2>/dev/null || true)
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
        "${MS_APT_PURGE[@]}" "${_pkgs[@]}"; then
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

# True when the normal apt driver cannot be relied on for this GPU, so a newer
# driver is worth looking for. $1 compat result for the normal candidate
# (see _nvidia_driver_check_compat), $2 its apt version.
#   current       -> no, unless the driver is older than Jellyfin's NVENC minimum
#   legacy_*/absent -> yes: the page gives no support for this GPU
#   unknown       -> no: no evidence either way, so do not change the apt sources
_nvidia_apt_needs_newer() {
    _nvidia_driver_below_nvenc_min "$2" && return 0
    case "$1" in
        legacy_* | absent) return 0 ;;
    esac
    return 1
}

# Decide whether to add ${codename}-backports, and log the decision. Without it
# the resolver below cannot see a newer candidate on a clean host. Runs in the
# calling shell: it changes apt sources.
_nvidia_apt_consider_backports() {
    local _codename _cand _pci _compat="unknown"
    _codename=$(nvidia_driver_debian_codename)
    _cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "")
    [[ -n "$_cand" && -n "$_codename" ]] || return 0
    _pci=$(_nvidia_gpu_pci_id)
    if [[ -n "$_pci" ]]; then
        _compat=$(_nvidia_driver_check_compat "$(_nvidia_upstream_version "$_cand")" "$_pci" 2>/dev/null) || _compat="unknown"
    fi

    if _nvidia_apt_needs_newer "$_compat" "$_cand"; then
        if [[ "$_compat" == absent ]] && ! _nvidia_driver_below_nvenc_min "$_cand"; then
            # Datacenter GPUs are missing from NVIDIA's consumer list yet run this driver.
            log_info "This GPU is not listed on NVIDIA's support page for driver ${_cand}; keeping it - checking ${_codename}-backports for a newer driver that lists it"
        else
            log_info "NVIDIA driver ${_cand} is not a fit for this GPU (${_compat}, Jellyfin NVENC needs ${NVIDIA_JELLYFIN_MIN_DRIVER}+) - checking ${_codename}-backports for a newer driver"
        fi
        if nvidia_driver_ensure_debian_backports; then
            sudo apt-get update -qq || true
        fi
        return 0
    fi
    case "$_compat" in
        current) log_info "NVIDIA lists this GPU as current for driver ${_cand} - backports not needed" ;;
        *) log_warn "Cannot tell from NVIDIA's supported-chips page whether driver ${_cand} supports this GPU - keeping ${_cand}, backports not enabled" ;;
    esac
}

# Decide which Debian nvidia-driver to install. Prefer the normal apt candidate;
# take ${codename}-backports only when the normal candidate gives no support for
# this GPU (legacy/absent) or is older than Jellyfin's NVENC minimum, AND a
# strictly newer backports candidate lists the GPU as current and meets the
# minimum. An "unknown" answer never triggers a change. No hard-coded versions.
# Echoes the apt-get install argument list (may begin with "-t <release>").
# Returns 3 when no installable driver can run Jellyfin's NVENC on this GPU; the
# explanation is logged, and the caller records the fallback reason (this runs in
# a command substitution, so it cannot set it).
_resolve_debian_nvidia_driver() {
    local _pkg_args="nvidia-driver firmware-misc-nonfree"
    local _codename _cand
    _codename=$(nvidia_driver_debian_codename)
    _cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "")
    if [[ -z "$_cand" || -z "$_codename" ]]; then
        printf '%s' "$_pkg_args"
        return 0
    fi

    local _pci _gpu _compat="unknown"
    _pci=$(_nvidia_gpu_pci_id)
    _gpu=$(_nvidia_gpu_label)
    if [[ -n "$_pci" ]]; then
        _compat=$(_nvidia_driver_check_compat "$(_nvidia_upstream_version "$_cand")" "$_pci" 2>/dev/null) || _compat="unknown"
    fi

    if _nvidia_apt_needs_newer "$_compat" "$_cand"; then
        local _bp_cand _bp_compat
        _bp_cand=$(nvidia_driver_apt_candidate_version "nvidia-driver" "${_codename}-backports")
        if [[ -n "$_bp_cand" ]] && dpkg --compare-versions "$_bp_cand" gt "$_cand"; then
            _bp_compat=$(_nvidia_driver_check_compat "$(_nvidia_upstream_version "$_bp_cand")" "$_pci" 2>/dev/null) || _bp_compat="unknown"
            if [[ "$_bp_compat" == "current" ]] && ! _nvidia_driver_below_nvenc_min "$_bp_cand"; then
                log_info "GPU needs a newer driver - selecting ${_codename}-backports (${_bp_cand})"
                printf '%s' "-t ${_codename}-backports $_pkg_args"
                return 0
            fi
            log_info "${_codename}-backports driver ${_bp_cand} is not a better fit for this GPU (${_bp_compat}) - not selected"
        else
            log_info "No newer driver than ${_cand} in ${_codename}-backports"
        fi
    fi

    # Nothing newer to take. The normal candidate must now be able to run NVENC.
    local _max_branch=""
    [[ "$_compat" == legacy_* ]] && _max_branch="${_compat#legacy_}"
    if _nvidia_driver_below_nvenc_min "$_cand" || { [[ -n "$_max_branch" ]] && _nvidia_driver_below_nvenc_min "$_max_branch"; }; then
        _nvidia_driver_too_old "$_gpu" "$_max_branch" "$_cand"
        return 3
    fi
    if [[ -n "$_max_branch" ]]; then
        log_warn "This GPU is on NVIDIA's legacy ${_max_branch}.xx branch; Debian's nvidia-driver ${_cand} may not drive it"
    fi
    printf '%s' "$_pkg_args"
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

    nvidia_driver_secure_boot_gate || return 1

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
        # The flavour metapackage keeps headers following the kernel, so the next
        # kernel upgrade builds its module (the fresh install adds it the same way).
        local _repair_meta
        _repair_meta=$(_nvidia_headers_meta_to_add "")
        [[ -n "$_repair_meta" ]] && _repair_packages+=("$_repair_meta")
        if ! ui_spin "Repairing Debian NVIDIA driver packages..." \
            "${MS_APT_INSTALL[@]}" --reinstall "${_repair_packages[@]}"; then
            log_error "Failed to repair the Debian NVIDIA driver packages"
            GPU_TYPE="none"
            return 1
        fi
        if ! _nvidia_ensure_dkms_all_kernels; then
            log_warn "Falling back to software transcoding"
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

    _nvidia_apt_consider_backports

    # DKMS silently skips the module build with no matching kernel headers, so
    # the driver install "succeeds" and the failure only surfaces later. Resolve
    # headers for the running kernel before touching the driver package.
    local _headers_pkg
    if ! _headers_pkg=$(_nvidia_preflight_kernel_headers); then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    local _install_args _resolve_rc=0
    _install_args=$(_resolve_debian_nvidia_driver) || _resolve_rc=$?
    if ((_resolve_rc != 0)); then
        # 3: the resolver logged why this GPU's best driver cannot run Jellyfin's NVENC.
        ((_resolve_rc == 3)) && STAGE3_FALLBACK_REASON=driver_too_old
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    local _meta_pkg
    _meta_pkg=$(_nvidia_headers_meta_to_add "$_headers_pkg")
    local _hdr_pkgs=() _hdr _hdr_ver
    [[ -n "$_headers_pkg" ]] && _hdr_pkgs+=("$_headers_pkg")
    [[ -n "$_meta_pkg" ]] && _hdr_pkgs+=("$_meta_pkg")
    for _hdr in "${_hdr_pkgs[@]}"; do
        # "-t <release>" scopes every package in the transaction to backports,
        # which could swap the flavor meta-package for headers matching a kernel
        # other than the running one. Pin the preflight-validated candidate so
        # the headers DKMS builds against are exactly the ones verified.
        if [[ "$_install_args" == "-t "* ]]; then
            _hdr_ver=$(nvidia_driver_apt_candidate_version "$_hdr" "")
            [[ -n "$_hdr_ver" ]] && _hdr="${_hdr}=${_hdr_ver}"
        fi
        _install_args="$_install_args $_hdr"
    done
    # shellcheck disable=SC2086  # _install_args is a controlled arg list (may include "-t <release>")
    if ! ui_spin "Installing Debian NVIDIA driver via apt (${_install_args})..." \
        "${MS_APT_INSTALL[@]}" $_install_args; then
        log_error "Failed to install the Debian nvidia-driver package"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi
    log_ok "Debian NVIDIA driver installed"

    if ! _nvidia_ensure_dkms_all_kernels; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

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
        # The gate passed, so Secure Boot on here means the module is signed.
        if [[ "$(nvidia_driver_check_secure_boot)" == "enabled" ]] && ! nvidia_driver_nouveau_is_active; then
            log_warn "nvidia-smi does not work yet under Secure Boot; if it still fails after the reboot, check that DKMS signed the module (modinfo -F signer nvidia-current)"
        fi
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

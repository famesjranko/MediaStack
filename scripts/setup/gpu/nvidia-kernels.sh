# Owns: kernel headers and DKMS module coverage for the Debian NVIDIA driver.
# Sources: gpu.sh globals, nvidia-driver.sh apt helpers, host-tools.sh, and common.sh logging.
# Derive the Debian kernel-flavor suffix from `uname -r` (e.g. "6.1.0-51-cloud-amd64"
# → "cloud-amd64", "6.12.111+deb13-amd64" → "amd64"). Debian kernel releases are
# "<upstream-version>-<abi>-<flavor>" up to Debian 12, "<upstream-version>+debNN-<flavor>"
# from Debian 13, and "<upstream-version>+bpo-<flavor>" in backports. A release with
# neither (custom kernel, not a Debian package build) has no derivable flavor and fails.
_nvidia_headers_flavor() {
    local _rel="$1"
    [[ "$_rel" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+|\+deb[0-9]+|\+bpo)-(.+)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[2]}"
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

# Echoes the kernel-flavour headers metapackage (linux-headers-<flavor>) when it
# is worth adding to the driver transaction: the flavour is derivable, apt has a
# candidate, it is not installed yet, and it is not the package $1 already chose.
# The metapackage tracks the newest kernel of the flavour, so a kernel that
# unattended-upgrades installs later gets headers and DKMS builds the module for
# it. Echoes nothing otherwise.
_nvidia_headers_meta_to_add() {
    local _chosen="${1:-}" _flavor _meta _st
    _flavor=$(_nvidia_headers_flavor "$(uname -r)") || return 0
    _meta="linux-headers-${_flavor}"
    [[ "$_meta" == "$_chosen" ]] && return 0
    _st=$(dpkg-query -W -f='${Status}' "$_meta" 2>/dev/null || true)
    [[ "$_st" == *"install ok installed"* ]] && return 0
    if [[ -n "$(nvidia_driver_apt_candidate_version "$_meta" "")" ]]; then
        printf '%s' "$_meta"
    fi
    return 0
}

# Kernel releases the next boot may use: the running kernel plus every installed
# kernel image that sorts at or above it (GRUB boots the newest by default, and
# the driver transaction can pull a newer image). Older images are not boot
# candidates, so their headers are not required. A linux-image-<ver>-unsigned
# package is the same kernel as <ver> (its headers are linux-headers-<ver>), so it
# maps to <ver>. Echoes one release per line.
_nvidia_boot_kernels() {
    local _running _rel
    _running=$(uname -r)
    {
        printf '%s\n' "$_running"
        dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-*' 2>/dev/null \
            | awk '$2 == "ii" && $1 ~ /^linux-image-[0-9]/ && $1 !~ /-dbg$/ { sub(/^linux-image-/, "", $1); sub(/-unsigned$/, "", $1); print $1 }'
    } | sort -uV | while read -r _rel; do
        [[ "$(printf '%s\n%s\n' "$_running" "$_rel" | sort -V | tail -n 1)" == "$_rel" ]] && printf '%s\n' "$_rel"
    done
    return 0
}

# True when DKMS reports an NVIDIA module built and installed for kernel $1.
# dkms lives in /usr/sbin, which a normal Debian user's PATH omits; a bare call
# made every built module look missing and sent a working install to software.
_nvidia_dkms_built() {
    local _dkms
    _dkms=$(host_tool_path dkms) || return 1
    "$_dkms" status -k "$1" 2>/dev/null | grep -i nvidia | grep -q ': installed'
}

_nvidia_kernel_remedy() {
    log_error "Run: sudo apt-get install linux-headers-$1 && sudo dkms autoinstall -k $1"
    log_error "Then re-run ./mediastack. Rebooting into $1 before that leaves the NVIDIA driver unloaded."
}

# The driver transaction can upgrade the kernel image, and DKMS builds the module
# only for kernels that have headers at that moment. A kernel without a built
# module boots with no NVIDIA driver (nvidia-smi fails, Jellyfin exits "Driver
# Not Loaded"). Make sure every kernel the next boot may use has headers and a
# built module. Kernel upgrades are not blocked. Fails loudly, with a remedy.
_nvidia_ensure_dkms_all_kernels() {
    local _running _k _pkg _st
    local _kernels=() _todo=() _pkgs=()
    _running=$(uname -r)
    mapfile -t _kernels < <(_nvidia_boot_kernels)
    for _k in "${_kernels[@]}"; do
        _nvidia_dkms_built "$_k" && continue
        _todo+=("$_k")
        _st=$(dpkg-query -W -f='${Status}' "linux-headers-${_k}" 2>/dev/null || true)
        [[ "$_st" == *"install ok installed"* ]] && continue
        if [[ "$_k" == "$_running" ]]; then
            _pkg=$(_nvidia_headers_candidate "$_k") || _pkg=""
        elif [[ -n "$(nvidia_driver_apt_candidate_version "linux-headers-${_k}" "")" ]]; then
            _pkg="linux-headers-${_k}"
        else
            _pkg=""
        fi
        if [[ -z "$_pkg" ]]; then
            log_error "No kernel headers package available for installed kernel ${_k} (looked for linux-headers-${_k})"
            _nvidia_kernel_remedy "$_k"
            return 1
        fi
        _pkgs+=("$_pkg")
    done
    ((${#_todo[@]} > 0)) || return 0

    if ((${#_pkgs[@]} > 0)) && ! ui_spin "Installing kernel headers (${_pkgs[*]})..." \
        "${MS_APT_INSTALL[@]}" "${_pkgs[@]}"; then
        log_error "Failed to install kernel headers: ${_pkgs[*]}"
        _nvidia_kernel_remedy "${_todo[0]}"
        return 1
    fi
    for _k in "${_todo[@]}"; do
        ui_spin "Building the NVIDIA kernel module for ${_k}..." sudo dkms autoinstall -k "$_k" || true
        if ! _nvidia_dkms_built "$_k"; then
            log_error "The NVIDIA kernel module is not built for installed kernel ${_k}"
            _nvidia_kernel_remedy "$_k"
            return 1
        fi
    done
    return 0
}

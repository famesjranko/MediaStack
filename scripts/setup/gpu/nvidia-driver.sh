# Owns: NVIDIA Secure Boot, nouveau handling, and driver resolution prerequisites.
# Sources: gpu.sh globals, common.sh logging, and nvidia-patch.sh helpers.
# shellcheck disable=SC2154 # _nvidia_tmp is a documented caller-owned workspace.
nvidia_driver_check_secure_boot() {
    if ! command -v mokutil &>/dev/null; then
        sudo apt-get install -y -qq mokutil >/dev/null 2>&1 || true
    fi
    if ! command -v mokutil &>/dev/null; then
        echo "unavailable"
        return
    fi
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Check whether nouveau is bound to any NVIDIA GPU via sysfs PCI driver
# binding. lsmod alone is insufficient — the installer checks sysfs.
nvidia_driver_nouveau_is_active() {
    lsmod 2>/dev/null | grep -q '^nouveau ' && return 0
    # `ls -l` is intentional: we match the driver symlink TARGET (-> .../nouveau),
    # which a filename glob cannot inspect.
    # shellcheck disable=SC2010
    ls -l /sys/bus/pci/devices/*/driver 2>/dev/null | grep -q 'nouveau' && return 0
    return 1
}

# Attempt to unload nouveau at runtime. Returns 0 if nouveau is no longer
# active (never was, or we successfully removed it).
nvidia_driver_try_unload_nouveau() {
    if ! nvidia_driver_nouveau_is_active; then
        return 0
    fi

    log_info "Attempting to unload nouveau kernel module..."

    sudo systemctl stop display-manager.target 2>/dev/null || true

    local vtcon
    for vtcon in /sys/class/vtconsole/vtcon*/; do
        [[ -d "$vtcon" ]] || continue
        if [[ -f "$vtcon/name" ]] && grep -qi "frame buffer" "$vtcon/name" 2>/dev/null; then
            echo 0 | sudo tee "${vtcon}bind" >/dev/null 2>&1 || true
        fi
    done

    sudo modprobe -r nouveau drm_kms_helper drm 2>/dev/null || true

    if ! nvidia_driver_nouveau_is_active; then
        log_ok "Nouveau unloaded - no reboot required for driver install"
        return 0
    fi

    log_info "Nouveau still active (bound to GPU) - driver install requires a reboot"
    return 1
}

# Check if NVIDIA kernel modules were installed (via DKMS or direct) even
# though the installer reported failure.
nvidia_driver_modules_installed() {
    ls /lib/modules/"$(uname -r)"/updates/dkms/nvidia*.ko* &>/dev/null && return 0
    ls /lib/modules/"$(uname -r)"/updates/nvidia*.ko* &>/dev/null && return 0
    ls /lib/modules/"$(uname -r)"/extra/nvidia*.ko* &>/dev/null && return 0
    dkms status 2>/dev/null | grep -qi "nvidia.*installed" && return 0
    return 1
}

_nvidia_driver_install_run_file() {
    local run_file="$1" driver_version="$2" temp_dir="$3"
    # ui_spin captures output to a log and surfaces it on failure, so the noisy
    # "Uncompressing..."/dpkg output stays hidden behind the spinner.
    ui_spin "Installing NVIDIA driver ${driver_version} (compiling kernel module)..." \
        sudo sh "$run_file" --silent --dkms --no-x-check --no-cc-version-check \
        --no-nouveau-check --no-install-compat32-libs --tmpdir "$temp_dir"
}

# Check NVIDIA's supportedchips.html for a driver version to determine
# whether a GPU (by PCI ID) is current or needs a legacy branch.
# Echoes "current" or "legacy_NNN" (e.g. "legacy_580"). Empty on failure.
_nvidia_driver_check_compat() {
    local _ver="$1" _pci_id="$2"
    local _url="https://download.nvidia.com/XFree86/Linux-x86_64/${_ver}/README/supportedchips.html"
    local _html
    _html=$(curl -fsSL "$_url" 2>/dev/null) || return 1
    [[ -z "$_html" ]] && return 1

    echo "$_html" | python3 -c "
import sys, re
section = 'unknown'
target = 'devid${_pci_id}'.lower()
for line in sys.stdin:
    if 'Current NVIDIA GPUs' in line:
        section = 'current'
    m = re.search(r'legacy_(\d+)\.', line)
    if m:
        section = 'legacy_' + m.group(1)
    if target in line.lower():
        print(section)
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Resolve the correct .run driver: fetch nvidia-patch README, find patchable
# version, check GPU compatibility via NVIDIA's supportedchips.html, and
# download the correct .run. Returns non-zero on failure (caller falls back).
#
# Sets caller variables: _driver_ver, _run_file
# Uses caller variables: _nvidia_tmp
nvidia_driver_resolve_driver() {
    log_info "Detecting NVENC-patchable driver versions..."
    local _readme_url
    _readme_url=$(nvidia_patch_readme_url)
    local _readme
    if ! _readme=$(curl -fsSL "$_readme_url"); then
        log_error "Could not fetch nvidia-patch README"
        return 1
    fi

    if [[ -z "$_readme" ]]; then
        log_error "Could not fetch nvidia-patch README"
        return 1
    fi

    local _table_row _driver_url
    _table_row=$(echo "$_readme" | grep -E '^\| *[0-9]+\.' | grep '| YES |' | grep '\.run)' | tail -1)
    _driver_ver=$(echo "$_table_row" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')
    _driver_url=$(echo "$_table_row" | grep -oP 'https://[^)]+\.run')

    if [[ -z "$_driver_ver" || -z "$_driver_url" ]]; then
        log_error "Could not determine latest driver from nvidia-patch README"
        return 1
    fi

    log_ok "Latest patchable driver: ${_driver_ver}"

    # Check GPU compatibility via NVIDIA's supportedchips.html before
    # downloading the 400MB+ .run file.
    local _gpu_pci_id _compat_result=""
    _gpu_pci_id=$(lspci -nn 2>/dev/null | grep -i 'nvidia' | grep -oP '\[10de:\K\w+' | head -1)

    if [[ -n "$_gpu_pci_id" ]]; then
        log_info "Checking GPU compatibility (device 0x${_gpu_pci_id})..."
        _compat_result=$(_nvidia_driver_check_compat "$_driver_ver" "$_gpu_pci_id") || true
    fi

    if [[ "$_compat_result" == legacy_* ]]; then
        local _legacy_branch="${_compat_result#legacy_}"
        log_warn "GPU requires legacy ${_legacy_branch}.xx driver branch"

        _table_row=$(echo "$_readme" | grep -E "^\| *${_legacy_branch}\." | grep '| YES |' | grep '\.run)' | tail -1)
        _driver_ver=$(echo "$_table_row" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')
        _driver_url=$(echo "$_table_row" | grep -oP 'https://[^)]+\.run')

        if [[ -z "$_driver_ver" || -z "$_driver_url" ]]; then
            log_error "No patchable ${_legacy_branch}.xx driver in nvidia-patch"
            return 1
        fi

        log_ok "Found legacy driver: ${_driver_ver}"
    elif [[ "$_compat_result" == "current" ]]; then
        log_ok "GPU is supported by driver ${_driver_ver}"
    else
        log_warn "Could not verify GPU compatibility - proceeding with ${_driver_ver}"
    fi

    _run_file="${_nvidia_tmp}/NVIDIA-Linux-x86_64-${_driver_ver}.run"
    if ! ui_spin "Downloading NVIDIA driver ${_driver_ver} (~380MB, may take a few minutes)..." \
        curl -fsSL -o "$_run_file" "$_driver_url"; then
        log_error "Failed to download driver ${_driver_ver}"
        return 1
    fi
    if ! chmod +x "$_run_file"; then
        log_error "Failed to mark driver installer executable"
        return 1
    fi

    return 0
}

# Debian release identifiers, read in a subshell so /etc/os-release vars don't
# leak as globals. Small mockable seams keep the apt helpers/tests deterministic.
nvidia_driver_debian_codename() {
    (
        . /etc/os-release 2>/dev/null
        printf '%s' "${VERSION_CODENAME:-}"
    )
}
_nvidia_driver_debian_version_id() {
    (
        . /etc/os-release 2>/dev/null
        printf '%s' "${VERSION_ID:-}"
    )
}

# Echo the apt version of a package, optionally restricted to a release (matched
# against the archive column of `apt-cache madison`). Empty if unavailable.
# Pure-bash parsing avoids the SIGPIPE/pipefail flake of piping into head/grep -q.
nvidia_driver_apt_candidate_version() {
    local _pkg="$1" _release="${2:-}"
    local _madison _name _verfield _archive _ver=""
    _madison=$(apt-cache madison "$_pkg" 2>/dev/null) || _madison=""
    while IFS='|' read -r _name _verfield _archive; do
        [[ -n "$_verfield" ]] || continue
        if [[ -n "$_release" ]]; then
            [[ "$_archive" == *"$_release"* ]] || continue
        else
            [[ "$_archive" == *backports* ]] && continue
        fi
        _ver="${_verfield// /}"
        break
    done <<<"$_madison"
    printf '%s' "$_ver"
}

# Ensure Debian's contrib/non-free(/non-free-firmware) components are visible to
# apt so proprietary GPU drivers and firmware can install. Writes a single
# MediaStack-managed source file ONLY when apt cannot already see non-free, and
# never edits the user's own apt configuration. Codename/version aware: Debian 11
# (bullseye) has no separate non-free-firmware component. Idempotent (fixed path,
# overwritten not appended). Used by the Intel, AMD, and Standard NVIDIA routes.
nvidia_driver_ensure_debian_nonfree() {
    local _codename _version_id
    _codename=$(nvidia_driver_debian_codename)
    if [[ -z "$_codename" ]]; then
        log_error "Failed to detect Debian codename for non-free apt source"
        return 1
    fi
    _version_id=$(_nvidia_driver_debian_version_id)

    local _components="contrib non-free non-free-firmware"
    if [[ "$_version_id" == "11" || "$_codename" == "bullseye" ]]; then
        _components="contrib non-free"
    fi

    # Only add components not already in the system's sources. Checking
    # apt-cache policy is circular: our own old file makes a component "visible",
    # so we'd never clean up the stale entry. Grep /etc/apt/sources.list directly
    # instead. Regex: component must be a whole word (space or line boundary) so
    # "non-free" doesn't accidentally match inside "non-free-firmware".
    local _comp _active_sources
    # MEDIASTACK_APT_SOURCES is a test-only seam; production reads the real file.
    local _sources_file="${MEDIASTACK_APT_SOURCES:-/etc/apt/sources.list}"
    _active_sources=$(grep -v '^\s*#' "$_sources_file" 2>/dev/null || true)
    local _needed=()
    for _comp in $_components; do
        if ! echo "$_active_sources" | grep -qE "(^|\s)${_comp}(\s|$)"; then
            _needed+=("$_comp")
        fi
    done

    if [[ ${#_needed[@]} -eq 0 ]]; then
        # All components already in sources.list — remove stale mediastack file
        sudo rm -f "$MEDIASTACK_GPU_NONFREE_LIST"
        return 0
    fi

    local _needed_str="${_needed[*]}"
    local _source_line
    printf -v _source_line 'deb http://deb.debian.org/debian %s %s\n' "$_codename" "$_needed_str"
    if ! sudo tee "$MEDIASTACK_GPU_NONFREE_LIST" >/dev/null <<<"$_source_line"; then
        log_error "Failed to add Debian non-free apt source"
        return 1
    fi
    log_ok "Enabled Debian components: ${_needed_str}"
    return 0
}

# Enable a MediaStack-managed ${codename}-backports source so the NVIDIA resolver
# can consider a newer driver for a too-new GPU. Idempotent (skips if backports is
# already visible). Backports has low apt pin priority by default, so this never
# changes the versions of other packages — backports installs require an explicit
# `-t ${codename}-backports`. Codename/version aware (no non-free-firmware on 11).
nvidia_driver_ensure_debian_backports() {
    local _codename
    _codename=$(nvidia_driver_debian_codename)
    [[ -n "$_codename" ]] || return 1

    local _policy
    _policy=$(apt-cache policy 2>/dev/null || true)
    case "$_policy" in
        *"${_codename}-backports"*) return 0 ;;
    esac

    local _version_id _components="main contrib non-free non-free-firmware"
    _version_id=$(_nvidia_driver_debian_version_id)
    if [[ "$_version_id" == "11" || "$_codename" == "bullseye" ]]; then
        _components="main contrib non-free"
    fi
    local _source_line
    printf -v _source_line 'deb http://deb.debian.org/debian %s-backports %s\n' "$_codename" "$_components"
    if ! sudo tee "$MEDIASTACK_GPU_BACKPORTS_LIST" >/dev/null <<<"$_source_line"; then
        log_error "Failed to add Debian backports apt source"
        return 1
    fi
    log_ok "Enabled ${_codename}-backports (for a newer NVIDIA driver)"
    return 0
}

# Remove the apt sources this module owns, called from the uninstall path so the
# teardown lives beside the writes above (was re-typed in hardening.sh).
# ponytail: blind rm, no sha-guard — these files carry no admin-editable content,
# unlike the apt.conf.d drop-ins _uninstall_apt guards.
# `|| true`: apt-source removal is non-fatal (matches the old inline `rm … || true`)
# and keeps this errexit-safe regardless of caller context, not just today's `||` callers.
nvidia_driver_gpu_uninstall() {
    sudo rm -f "$MEDIASTACK_GPU_NONFREE_LIST" "$MEDIASTACK_GPU_BACKPORTS_LIST" || true
}

nvidia_driver_blacklist_nouveau() {
    log_info "Blacklisting nouveau kernel module..."
    local _blacklist
    _blacklist=$'blacklist nouveau\noptions nouveau modeset=0\n'
    if ! sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<<"$_blacklist"; then
        log_error "Failed to write nouveau blacklist"
        return 1
    fi
    if ! ui_spin "Updating initramfs (nouveau blacklist)..." sudo update-initramfs -u; then
        log_error "Failed to update initramfs after nouveau blacklist"
        return 1
    fi
    return 0
}

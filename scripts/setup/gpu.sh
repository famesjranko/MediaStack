# =============================================================================
# MediaStack Setup — GPU detection, driver install, and verification
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# Globals set: GPU_TYPE ("nvidia"|"amd"|"intel"|"none"), NEEDS_REBOOT (bool).

_GPU_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/nvidia_patch.sh
source "$_GPU_HELPER_DIR/lib/nvidia_patch.sh"
unset _GPU_HELPER_DIR

detect_gpu() {
    GPU_TYPE="none"

    if ! command -v lspci &>/dev/null; then
        log_warn "lspci not found (install pciutils) - cannot detect GPU"
        return
    fi

    local gpu_lines
    gpu_lines=$(lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)

    if echo "$gpu_lines" | grep -qi 'nvidia'; then
        GPU_TYPE="nvidia"
        log_ok "NVIDIA GPU detected: $(echo "$gpu_lines" | grep -i nvidia | head -1 | sed 's/.*: //')"
    elif echo "$gpu_lines" | grep -qEi 'amd|radeon'; then
        GPU_TYPE="amd"
        log_ok "AMD GPU detected: $(echo "$gpu_lines" | grep -Ei 'amd|radeon' | head -1 | sed 's/.*: //')"
    elif echo "$gpu_lines" | grep -qi 'intel'; then
        GPU_TYPE="intel"
        log_ok "Intel GPU detected"
    else
        log_info "No dedicated GPU detected - Jellyfin will use software transcoding"
    fi
}

gpu_render_device_for_vendor() {
    local vendor="${1:-}"
    local vendor_id=""
    case "$vendor" in
        intel) vendor_id="0x8086" ;;
        amd)   vendor_id="0x1002" ;;
    esac

    local render node sys_vendor found="" saw_vendor_file=false
    for render in /dev/dri/renderD*; do
        [[ -e "$render" ]] || continue
        node="${render##*/}"
        sys_vendor="/sys/class/drm/${node}/device/vendor"
        if [[ -r "$sys_vendor" ]]; then
            saw_vendor_file=true
            if [[ -n "$vendor_id" ]] && grep -qi "^${vendor_id}$" "$sys_vendor"; then
                printf '%s\n' "$render"
                return 0
            fi
        fi
        [[ -z "$found" ]] && found="$render"
    done

    if [[ -n "$vendor_id" && "$saw_vendor_file" == "true" ]]; then
        return 1
    fi
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

gpu_render_device_exists() {
    [[ -e "${1:-}" ]]
}

gpu_render_device_vendor_matches() {
    local render_device="${1:-}"
    local vendor="${2:-}"
    local vendor_id=""
    case "$vendor" in
        intel) vendor_id="0x8086" ;;
        amd)   vendor_id="0x1002" ;;
    esac

    [[ -n "$vendor_id" ]] || return 0

    local node sys_vendor
    node="${render_device##*/}"
    sys_vendor="/sys/class/drm/${node}/device/vendor"
    [[ -r "$sys_vendor" ]] || return 0
    grep -qi "^${vendor_id}$" "$sys_vendor"
}

gpu_persisted_render_device() {
    local vendor="${1:-}"
    local render_device="${STAGE_3_GPU_RENDER_DEVICE:-}"
    [[ "$render_device" =~ ^/dev/dri/renderD[0-9]+$ ]] || return 1
    gpu_render_device_exists "$render_device" || return 1
    gpu_render_device_vendor_matches "$render_device" "$vendor" || return 1
    printf '%s\n' "$render_device"
}

# Detect Secure Boot state via mokutil. Secure Boot refuses to load unsigned
# kernel modules, so if enabled we'd install a driver that never loads.
# Echoes one of: enabled, disabled, unavailable.
check_secure_boot() {
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
nouveau_is_active() {
    lsmod 2>/dev/null | grep -q '^nouveau ' && return 0
    # `ls -l` is intentional: we match the driver symlink TARGET (-> .../nouveau),
    # which a filename glob cannot inspect.
    # shellcheck disable=SC2010
    ls -l /sys/bus/pci/devices/*/driver 2>/dev/null | grep -q 'nouveau' && return 0
    return 1
}

# Attempt to unload nouveau at runtime. Returns 0 if nouveau is no longer
# active (never was, or we successfully removed it).
try_unload_nouveau() {
    if ! nouveau_is_active; then
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

    if ! nouveau_is_active; then
        log_ok "Nouveau unloaded - no reboot required for driver install"
        return 0
    fi

    log_info "Nouveau still active (bound to GPU) - driver install requires a reboot"
    return 1
}

# Check if NVIDIA kernel modules were installed (via DKMS or direct) even
# though the installer reported failure.
nvidia_modules_installed() {
    ls /lib/modules/"$(uname -r)"/updates/dkms/nvidia*.ko* &>/dev/null && return 0
    ls /lib/modules/"$(uname -r)"/updates/nvidia*.ko* &>/dev/null && return 0
    ls /lib/modules/"$(uname -r)"/extra/nvidia*.ko* &>/dev/null && return 0
    dkms status 2>/dev/null | grep -qi "nvidia.*installed" && return 0
    return 1
}

# Check NVIDIA's supportedchips.html for a driver version to determine
# whether a GPU (by PCI ID) is current or needs a legacy branch.
# Echoes "current" or "legacy_NNN" (e.g. "legacy_580"). Empty on failure.
_check_nvidia_compat() {
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
_resolve_nvidia_driver() {
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
        _compat_result=$(_check_nvidia_compat "$_driver_ver" "$_gpu_pci_id") || true
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
    log_info "Downloading NVIDIA driver ${_driver_ver} (this may take a few minutes)..."
    if ! curl -fSL -o "$_run_file" "$_driver_url"; then
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
_debian_codename() {
    ( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}" )
}
_debian_version_id() {
    ( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}" )
}

# Echo the apt version of a package, optionally restricted to a release (matched
# against the archive column of `apt-cache madison`). Empty if unavailable.
# Pure-bash parsing avoids the SIGPIPE/pipefail flake of piping into head/grep -q.
_apt_candidate_version() {
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
    done <<< "$_madison"
    printf '%s' "$_ver"
}

# Ensure Debian's contrib/non-free(/non-free-firmware) components are visible to
# apt so proprietary GPU drivers and firmware can install. Writes a single
# MediaStack-managed source file ONLY when apt cannot already see non-free, and
# never edits the user's own apt configuration. Codename/version aware: Debian 11
# (bullseye) has no separate non-free-firmware component. Idempotent (fixed path,
# overwritten not appended). Used by the Intel, AMD, and Standard NVIDIA routes.
ensure_debian_nonfree() {
    local _codename _version_id
    _codename=$(_debian_codename)
    if [[ -z "$_codename" ]]; then
        log_error "Failed to detect Debian codename for non-free apt source"
        return 1
    fi
    _version_id=$(_debian_version_id)

    local _components="contrib non-free non-free-firmware"
    if [[ "$_version_id" == "11" || "$_codename" == "bullseye" ]]; then
        _components="contrib non-free"
    fi

    # Skip only when EVERY required component is already visible to apt. A partial
    # setup (e.g. non-free present but contrib or non-free-firmware missing) must
    # still be fixed, so a bare "*non-free*" match is not enough. Components show
    # as "<suite>/<component> <arch>" in `apt-cache policy` URL lines; the trailing
    # space keeps "non-free" from matching "non-free-firmware".
    local _policy _comp _missing=0
    _policy=$(apt-cache policy 2>/dev/null || true)
    for _comp in $_components; do
        case "$_policy" in
            *"/$_comp "*) ;;
            *) _missing=1 ;;
        esac
    done
    if [[ "$_missing" -eq 0 ]]; then
        return 0
    fi

    local _source_line
    printf -v _source_line 'deb http://deb.debian.org/debian %s %s\n' "$_codename" "$_components"
    if ! sudo tee /etc/apt/sources.list.d/mediastack-nonfree.list >/dev/null <<< "$_source_line"; then
        log_error "Failed to add Debian non-free apt source"
        return 1
    fi
    log_ok "Enabled Debian components: ${_components}"
    return 0
}

# Enable a MediaStack-managed ${codename}-backports source so the NVIDIA resolver
# can consider a newer driver for a too-new GPU. Idempotent (skips if backports is
# already visible). Backports has low apt pin priority by default, so this never
# changes the versions of other packages — backports installs require an explicit
# `-t ${codename}-backports`. Codename/version aware (no non-free-firmware on 11).
ensure_debian_backports() {
    local _codename
    _codename=$(_debian_codename)
    [[ -n "$_codename" ]] || return 1

    local _policy
    _policy=$(apt-cache policy 2>/dev/null || true)
    case "$_policy" in
        *"${_codename}-backports"*) return 0 ;;
    esac

    local _version_id _components="main contrib non-free non-free-firmware"
    _version_id=$(_debian_version_id)
    if [[ "$_version_id" == "11" || "$_codename" == "bullseye" ]]; then
        _components="main contrib non-free"
    fi
    local _source_line
    printf -v _source_line 'deb http://deb.debian.org/debian %s-backports %s\n' "$_codename" "$_components"
    if ! sudo tee /etc/apt/sources.list.d/mediastack-backports.list >/dev/null <<< "$_source_line"; then
        log_error "Failed to add Debian backports apt source"
        return 1
    fi
    log_ok "Enabled ${_codename}-backports (for a newer NVIDIA driver)"
    return 0
}

_nvidia_blacklist_nouveau() {
    log_info "Blacklisting nouveau kernel module..."
    local _blacklist
    _blacklist=$'blacklist nouveau\noptions nouveau modeset=0\n'
    if ! sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<< "$_blacklist"; then
        log_error "Failed to write nouveau blacklist"
        return 1
    fi
    if ! sudo update-initramfs -u 2>/dev/null; then
        log_error "Failed to update initramfs after nouveau blacklist"
        return 1
    fi
    return 0
}

install_nvidia_drivers() {
    if command -v nvidia-smi &>/dev/null; then
        log_ok "NVIDIA drivers already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'unknown version')"
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
        if nouveau_is_active; then
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
        log_info "Installing NVIDIA driver ${_driver_ver} (compiling kernel module)..."
        if ! sudo sh "$_run_file" --silent --dkms --no-x-check --no-cc-version-check --no-nouveau-check --no-install-compat32-libs --tmpdir "$_nvidia_tmp"; then
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
    sb_state=$(check_secure_boot)
    case "$sb_state" in
        enabled)
            log_error "Secure Boot is enabled - the NVIDIA kernel module will not load."
            log_error "Fix one of the following, then re-run setup.sh:"
            log_error "  (a) disable Secure Boot in UEFI firmware settings, OR"
            log_error "  (b) enroll a Machine Owner Key to sign the nvidia module (advanced)."
            log_warn  "Falling back to software transcoding; GPU acceleration will not be configured."
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

    log_info "Installing kernel headers and build prerequisites..."
    if ! sudo apt-get install -y -qq "linux-headers-$(uname -r)" build-essential dkms pkg-config libglvnd-dev >/dev/null; then
        log_error "Failed to install NVIDIA kernel build prerequisites"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    # Blacklist nouveau unconditionally for NVIDIA installs — the installer
    # checks sysfs PCI binding, not just lsmod, so we must ensure nouveau
    # is fully gone before running it.
    if ! _nvidia_blacklist_nouveau; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi
    try_unload_nouveau || true

    if ! mkdir -p "$_nvidia_tmp"; then
        log_error "Failed to create NVIDIA driver cache directory"
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        return 1
    fi

    local _driver_ver="" _run_file=""
    if ! _resolve_nvidia_driver; then
        log_warn "Falling back to software transcoding"
        GPU_TYPE="none"
        sudo rm -rf "$_nvidia_tmp" 2>/dev/null || true
        return 1
    fi

    # If nouveau is still active, we cannot run the installer — it will
    # either abort (without --no-nouveau-check) or compile-then-rollback
    # (with it). Cache the .run and reboot instead.
    if nouveau_is_active; then
        log_warn "Nouveau is still bound to the GPU - caching driver for post-reboot install"
        if ! cat > "$_nvidia_tmp/pending" <<EOF
_driver_ver='${_driver_ver}'
_run_file='${_run_file}'
EOF
        then
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
    log_info "Installing NVIDIA driver ${_driver_ver} (compiling kernel module)..."
    if ! sudo sh "$_run_file" --silent --dkms --no-x-check --no-cc-version-check --no-nouveau-check --no-install-compat32-libs --tmpdir "$_nvidia_tmp"; then
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

_install_nvidia_container_toolkit() {
    if _nvidia_toolkit_healthy; then
        log_ok "nvidia-container-toolkit already installed"
        return 0
    else
        log_info "Installing/repairing nvidia-container-toolkit..."

        if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
            log_error "Failed to install NVIDIA container toolkit apt key"
            return 1
        fi

        if ! curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null; then
            log_error "Failed to install NVIDIA container toolkit apt source"
            return 1
        fi

        if ! sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for nvidia-container-toolkit"
            return 1
        fi
        if ! sudo apt-get install -y -qq --reinstall \
            libnvidia-container1 libnvidia-container-tools \
            nvidia-container-toolkit-base nvidia-container-toolkit >/dev/null; then
            log_error "Failed to install nvidia-container-toolkit"
            return 1
        fi

        # Configure Docker runtime
        if ! sudo nvidia-ctk runtime configure --runtime=docker; then
            log_error "Failed to configure nvidia-container-toolkit runtime"
            return 1
        fi
        if ! sudo systemctl restart docker; then
            log_error "Failed to restart Docker after nvidia-container-toolkit configuration"
            return 1
        fi
        log_ok "nvidia-container-toolkit installed and configured"
        return 0
    fi
}

# Classify any installed NVIDIA driver by source so "Standard" stays honest.
# Echoes "debian" (the nvidia-driver metapackage is installed — MediaStack's own
# Standard install), "foreign" (a working driver MediaStack does not recognize as
# its Debian-managed install — a manual .run, or a Debian driver set up without the
# metapackage), or "none". Conservative: an unrecognized Debian stack reads as
# "foreign", which is safe (we never claim or auto-modify it).
nvidia_driver_source() {
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi -L &>/dev/null; then
        printf 'none'
        return 0
    fi
    local _st
    _st=$(dpkg-query -W -f='${Status}' nvidia-driver 2>/dev/null || true)
    case "$_st" in
        *"install ok installed"*) printf 'debian' ;;
        *) printf 'foreign' ;;
    esac
}

_nvidia_debian_driver_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' '*nvidia*' '*cuda*' 'glx-*' 2>/dev/null \
        | awk '$2 == "ii" {print $1}' \
        | grep -Ev '^(nvidia-container-toolkit|nvidia-container-toolkit-base|libnvidia-container-tools|libnvidia-container1(:amd64)?|glx-alternative-mesa)$' \
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

    log_info "Removing Debian NVIDIA driver packages before Unlock install..."
    sudo apt-mark manual nvidia-container-toolkit nvidia-container-toolkit-base \
        libnvidia-container-tools libnvidia-container1 >/dev/null 2>&1 || true
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_pkgs[@]}" >/dev/null; then
        log_error "Failed to remove Debian NVIDIA driver packages"
        return 1
    fi

    if _nvidia_unload_loaded_modules; then
        log_ok "Loaded Debian NVIDIA modules unloaded"
        return 0
    fi

    if ! _nvidia_blacklist_nouveau; then
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
    _codename=$(_debian_codename)

    local _cand
    _cand=$(_apt_candidate_version "nvidia-driver" "")
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
    _normal_compat=$(_check_nvidia_compat "${_cand%%-*}" "$_pci_id" 2>/dev/null) || _normal_compat=""
    if [[ "$_normal_compat" == "current" ]]; then
        printf '%s' "$_pkg_args"
        return 0
    fi

    # Escalate only on positive evidence: backports has a strictly-newer candidate
    # that lists this GPU as current.
    local _bp_cand
    _bp_cand=$(_apt_candidate_version "nvidia-driver" "${_codename}-backports")
    if [[ -n "$_bp_cand" ]] && dpkg --compare-versions "$_bp_cand" gt "$_cand"; then
        local _bp_compat
        _bp_compat=$(_check_nvidia_compat "${_bp_cand%%-*}" "$_pci_id" 2>/dev/null) || _bp_compat=""
        if [[ "$_bp_compat" == "current" ]]; then
            log_info "GPU needs a newer driver - selecting ${_codename}-backports"
            printf '%s' "-t ${_codename}-backports $_pkg_args"
            return 0
        fi
    fi

    printf '%s' "$_pkg_args"
}

# Standard mode: install the Debian-packaged NVIDIA driver (NO nvidia-patch).
# Distro-managed, survives apt upgrade, official NVENC session limits. On any
# failure sets GPU_TYPE="none" and returns 1 (caller falls back to software).
# Return 2 signals a pre-existing non-Debian driver — the caller decides whether
# to keep it (mode "existing") or abort. May set NEEDS_REBOOT=true.
install_nvidia_drivers_apt() {
    local _source
    _source=$(nvidia_driver_source)
    case "$_source" in
        debian)
            log_ok "Debian-managed NVIDIA driver already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo unknown)"
            if ! _install_nvidia_container_toolkit; then GPU_TYPE="none"; return 1; fi
            NVIDIA_DRIVER_MODE="standard"
            return 0
            ;;
        foreign)
            # A working driver exists but MediaStack did not install it via apt;
            # Standard must not claim it. Caller prompts continue/abort.
            return 2
            ;;
    esac

    local sb_state
    sb_state=$(check_secure_boot)
    case "$sb_state" in
        enabled)
            log_error "Secure Boot is enabled - the NVIDIA kernel module will not load."
            log_error "Disable Secure Boot in UEFI, or enroll a Machine Owner Key (advanced), then re-run setup.sh."
            log_warn  "Falling back to software transcoding; GPU acceleration will not be configured."
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

    if ! ensure_debian_nonfree; then
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

    # If the normal candidate can't drive this (too-new) GPU, enable a managed
    # backports source and refresh apt so the resolver can see a newer candidate.
    # Without this, backports escalation is unreachable on a clean host (the
    # resolver could never find a backports candidate to compare against).
    local _gate_cand _gate_pci="" _gate_compat=""
    _gate_cand=$(_apt_candidate_version "nvidia-driver" "")
    _gate_pci=$(lspci -nn 2>/dev/null | grep -i 'nvidia' | grep -oP '\[10de:\K\w+' | head -1) || true
    if [[ -n "$_gate_cand" && -n "$_gate_pci" ]]; then
        _gate_compat=$(_check_nvidia_compat "${_gate_cand%%-*}" "$_gate_pci" 2>/dev/null) || _gate_compat=""
        if [[ "$_gate_compat" != "current" ]] && ensure_debian_backports; then
            sudo apt-get update -qq || true
        fi
    fi

    local _install_args
    _install_args=$(_resolve_debian_nvidia_driver)
    log_info "Installing Debian NVIDIA driver via apt (${_install_args})..."
    # shellcheck disable=SC2086  # _install_args is a controlled arg list (may include "-t <release>")
    if ! sudo apt-get install -y -qq $_install_args >/dev/null; then
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

    # Read by env_gen.sh / stage3.sh / nvidia-repatch.sh, not within gpu.sh.
    # shellcheck disable=SC2034
    NVIDIA_DRIVER_MODE="standard"
    # The Debian package blacklists nouveau and builds the module via DKMS, but a
    # reboot is needed to swap nouveau->nvidia before nvidia-smi works.
    if nouveau_is_active || ! { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
        # Read by stage3.sh reboot gating, not within gpu.sh.
        # shellcheck disable=SC2034
        NEEDS_REBOOT=true
        log_ok "Debian NVIDIA driver installed (reboot required to load the kernel module)"
    fi
    return 0
}

# Apply nvidia-patch to remove NVENC session limits on consumer GPUs
# See: https://github.com/keylase/nvidia-patch
apply_nvidia_patch() {
    # Only run if NVIDIA drivers are loaded
    if ! command -v nvidia-smi &>/dev/null; then
        return
    fi

    local patch_dir="$SCRIPT_DIR/.nvidia-patch"
    local patch_run_dir=""

    if ! nvidia_patch_prepare_repo "$patch_dir"; then
        log_warn "nvidia-patch verification failed - skip (update MediaStack or clean .nvidia-patch)"
        return
    fi

    patch_run_dir=$(nvidia_patch_export_run_tree "$patch_dir") || {
        log_warn "nvidia-patch export failed - skip"
        return
    }

    local driver_ver
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "")
    if [[ -z "$driver_ver" ]]; then
        log_warn "Cannot detect NVIDIA driver version - skipping patch"
        rm -rf "$patch_run_dir"
        return
    fi

    log_info "NVIDIA driver version: $driver_ver"

    # Check if patch supports this driver version
    if ! bash "$patch_run_dir/patch.sh" -c "$driver_ver" &>/dev/null; then
        log_warn "nvidia-patch does not support driver $driver_ver - skipping"
        rm -rf "$patch_run_dir"
        return
    fi

    # Apply NVENC patch (removes encoding session limit)
    log_info "Applying NVENC patch..."
    if sudo bash "$patch_run_dir/patch.sh" -s 2>/dev/null; then
        log_ok "NVENC patch applied (encoding session limit removed)"
    else
        log_warn "NVENC patch failed (may already be applied or unsupported)"
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
}

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
        if ! sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for Intel media drivers"
            return 1
        fi
        if ! sudo apt-get install -y -qq intel-media-va-driver-non-free vainfo >/dev/null; then
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
        if ! sudo apt-get update -qq; then
            log_error "Failed to update apt metadata for AMD VAAPI drivers"
            return 1
        fi
        if ! sudo apt-get install -y -qq mesa-va-drivers vainfo >/dev/null; then
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
# back to software transcoding on a correctly-configured host (finding F-004).
#
# Robust approach: capture (no pipe), match the runtime KEY precisely via a
# keys-only template (not a substring grep of the whole multi-KB blob), and retry
# to ride out the transient window. "unknown" means the daemon could not be
# queried — NOT that the runtime is absent; callers must treat the two differently.
_nvidia_docker_runtime_state() {
    local keys
    for _ in 1 2 3 4; do
        if keys="$(docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null)" \
            && [[ -n "$keys" ]]; then
            case " $keys " in
                *" nvidia "*) printf 'registered' ;;
                *)            printf 'absent' ;;
            esac
            return 0
        fi
        sleep 2
    done
    printf 'unknown'
}

# Confirm the selected GPU is actually usable before we write the compose
# override. A broken override (e.g. runtime: nvidia pointing at a runtime
# that isn't registered) prevents Jellyfin from starting at all — worse
# than just losing hardware acceleration. Mutates global GPU_TYPE.
verify_gpu_usable() {
    case "$GPU_TYPE" in
        nvidia)
            if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi -L &>/dev/null; then
                log_error "NVIDIA hardware detected but nvidia-smi is not working."
                log_error "Driver failed to load (Secure Boot blocking the module? DKMS build failure? pending reboot?)."
                log_warn  "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            if ! command -v nvidia-container-runtime &>/dev/null; then
                log_error "nvidia-container-runtime binary not found."
                log_error "Try: sudo apt-get install --reinstall nvidia-container-toolkit"
                log_warn  "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            # Confirm Docker's nvidia runtime is registered — robustly, treating
            # the three states distinctly (never silently fall back on a transient
            # miss — the F-004 failure):
            local _rt_state
            _rt_state="$(_nvidia_docker_runtime_state)"
            case "$_rt_state" in
                registered)
                    log_ok "NVIDIA GPU verified (nvidia-smi + docker runtime)"
                    ;;
                absent)
                    # CONFIRMED missing: the toolkit is present but the runtime is
                    # not registered with Docker. Self-heal (idempotent reconfigure
                    # + restart) and re-check; only fall back if it is still absent.
                    # The Docker restart is justified here because the runtime is
                    # confirmed missing — not merely unprobeable.
                    log_warn "Docker's NVIDIA runtime is not registered; configuring it now..."
                    sudo nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
                    sudo systemctl restart docker >/dev/null 2>&1 \
                        || sudo service docker restart >/dev/null 2>&1 || true
                    if [[ "$(_nvidia_docker_runtime_state)" == "registered" ]]; then
                        log_ok "NVIDIA GPU verified (nvidia-smi + docker runtime now registered)"
                    else
                        log_error "Docker's NVIDIA runtime could not be registered."
                        log_error "Try: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
                        log_warn  "Falling back to software transcoding."
                        GPU_TYPE="none"
                        return
                    fi
                    ;;
                *)
                    # unknown: `docker info` was unreadable after retries (busy
                    # daemon) — NOT a confirmed-missing runtime. Do NOT bounce a
                    # possibly-healthy daemon, and do NOT silently drop the GPU on
                    # an inconclusive probe. Keep nvidia; the real test transcode in
                    # _stage3_configure_and_verify / stage3_finalize_nvidia is the
                    # authoritative gate and falls back cleanly if it truly fails.
                    log_warn "Could not confirm Docker's NVIDIA runtime (daemon busy?); the test transcode will confirm GPU usability."
                    log_ok "NVIDIA GPU verified (nvidia-smi; docker runtime check inconclusive)"
                    ;;
            esac
            ;;
        amd)
            local render_device
            render_device="$(gpu_persisted_render_device amd || gpu_render_device_for_vendor amd || true)"
            if [[ -z "$render_device" ]]; then
                log_error "AMD GPU detected but no /dev/dri/renderD* device is available."
                log_warn  "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            log_ok "AMD GPU verified ($render_device present)"
            if command -v vainfo &>/dev/null; then
                log_info "VAAPI info (host): $(vainfo 2>&1 | head -3 | tr '\n' ' ')"
            fi
            ;;
        intel)
            local render_device
            render_device="$(gpu_persisted_render_device intel || gpu_render_device_for_vendor intel || true)"
            if [[ -z "$render_device" ]]; then
                log_error "Intel GPU detected but no /dev/dri/renderD* device is available."
                log_warn  "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            log_ok "Intel GPU verified ($render_device present)"
            if command -v vainfo &>/dev/null; then
                log_info "VAAPI info (host): $(vainfo 2>&1 | head -3 | tr '\n' ' ')"
            fi
            ;;
    esac
}

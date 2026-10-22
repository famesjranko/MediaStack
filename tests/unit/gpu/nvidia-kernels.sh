# Owns: Debian NVIDIA kernel-coverage assertions (headers + DKMS for every boot kernel).
# Sources: tests/unit/gpu-branching.sh setup, the stubs in nvidia-apt.sh, and scripts/setup/gpu/nvidia-apt.sh.
# shellcheck disable=SC2034 # GPU_TYPE is consumed by product code under test.
_kernel_fixture() {
    uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-53-cloud-amd64\n' || builtin uname "$@"; }
    dpkg-query() {
        case "$*" in
            *'${Package}'*) printf '%s\n' 'linux-image-6.1.0-40-cloud-amd64 ii' 'linux-image-6.1.0-53-cloud-amd64 ii' \
                'linux-image-6.1.0-54-cloud-amd64 ii' 'linux-image-cloud-amd64 ii' 'linux-image-6.1.0-54-cloud-amd64-dbg ii' ;;
            *linux-headers-6.1.0-40-cloud-amd64*) printf 'install ok installed' ;;
            *) return 1 ;;
        esac
    }
    apt-cache() {
        [[ "${1:-}" == "madison" ]] || return 0
        case "${2:-}" in
            linux-headers-6.1.0-53-cloud-amd64 | linux-headers-6.1.0-54-cloud-amd64)
                printf ' %s | 6.1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$2"
                ;;
        esac
    }
    command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
    nvidia_driver_check_secure_boot() { printf 'disabled'; }
    nvidia_driver_ensure_debian_nonfree() { return 0; }
    _resolve_debian_nvidia_driver() { printf 'nvidia-driver firmware-misc-nonfree'; }
    _nvidia_apt_consider_backports() { :; }
    _install_nvidia_container_toolkit() { return 0; }
    nvidia_driver_nouveau_is_active() { return 1; }
    nvidia_driver_source() { printf '%s' "${FIXTURE_SOURCE:-none}"; }
    _nvidia_debian_repair_packages() { printf '%s\n' nvidia-driver; }
    _nvidia_toolkit_healthy() { return 0; }
    _configure_nvidia_container_toolkit() { return 0; }
    log_error() { ERRORS+=("$*"); }
    sudo() { _sudo_stub "$@"; }
    _stub_reset
    ERRORS=()
    GPU_TYPE=nvidia
}
_kernel_fixture_end() {
    unset -f uname dpkg-query apt-cache command nvidia_driver_source nvidia_driver_check_secure_boot \
        nvidia_driver_ensure_debian_nonfree _resolve_debian_nvidia_driver _nvidia_apt_consider_backports _install_nvidia_container_toolkit \
        nvidia_driver_nouveau_is_active _nvidia_debian_repair_packages _nvidia_toolkit_healthy \
        _configure_nvidia_container_toolkit sudo
    log_error() { :; }
    unset FIXTURE_SOURCE rc
}

# --- kernel coverage on the install route ---
# Given kernel 53 is running and kernel 54 (plus an old 40) is installed with no module built,
# When the Debian driver installs,
# Then headers and a DKMS build exist for 53 and 54, and the old kernel is left alone.
_kernel_fixture
rc=0
install_nvidia_drivers_apt || rc=$?
_calls="${SUDO_CALLS[*]}"
assert_eq "0" "$rc" "install: newer installed kernel → succeeds"
assert_contains "$_calls" "linux-headers-6.1.0-53-cloud-amd64" "install: headers for the running kernel are installed"
assert_contains "$_calls" "linux-headers-6.1.0-54-cloud-amd64" "install: headers for the newer installed kernel are installed"
assert_contains "$_calls" "dkms autoinstall -k 6.1.0-53-cloud-amd64" "install: dkms builds the module for the running kernel"
assert_contains "$_calls" "dkms autoinstall -k 6.1.0-54-cloud-amd64" "install: dkms builds the module for the newer kernel"
assert_not_contains "$_calls" "6.1.0-40" "install: an older kernel is not a boot candidate and is left alone"
_kernel_fixture_end

# --- install route: dkms failure ---
# Given dkms cannot build the module for the newer kernel,
# When the Debian driver installs,
# Then the step fails, falls back to software, and the error names the remedy.
_kernel_fixture
DKMS_FAIL=" 6.1.0-54-cloud-amd64 "
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "install: dkms fails for the newer kernel → install fails"
assert_eq "none" "$GPU_TYPE" "install: dkms failure → falls back to software transcoding"
assert_contains "${ERRORS[*]}" "sudo dkms autoinstall -k 6.1.0-54-cloud-amd64" "install: dkms failure names the remedy command"
_kernel_fixture_end

# --- install route: headers missing ---
# Given apt has no headers package for the newer kernel,
# When the Debian driver installs,
# Then the step fails and the error names that headers package.
_kernel_fixture
apt-cache() {
    [[ "${1:-}" == "madison" && "${2:-}" == "linux-headers-6.1.0-53-cloud-amd64" ]] \
        && printf ' %s | 6.1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$2"
    return 0
}
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "install: no headers for the newer kernel → install fails"
assert_contains "${ERRORS[*]}" "linux-headers-6.1.0-54-cloud-amd64" "install: missing headers error names the kernel's headers package"
_kernel_fixture_end

# --- repair route ---
# Given the same installed kernels and a Debian driver already present,
# When the driver is repaired,
# Then headers and a DKMS build cover both kernels; a dkms failure fails the repair with a remedy.
_kernel_fixture
FIXTURE_SOURCE=debian
rc=0
install_nvidia_drivers_apt repair || rc=$?
_calls="${SUDO_CALLS[*]}"
assert_eq "0" "$rc" "repair: newer installed kernel → succeeds"
assert_contains "$_calls" "linux-headers-6.1.0-54-cloud-amd64" "repair: headers for the newer installed kernel are installed"
assert_contains "$_calls" "dkms autoinstall -k 6.1.0-54-cloud-amd64" "repair: dkms builds the module for the newer kernel"
assert_contains "$_calls" "dkms autoinstall -k 6.1.0-53-cloud-amd64" "repair: dkms builds the module for the running kernel"
_kernel_fixture_end

_kernel_fixture
FIXTURE_SOURCE=debian
DKMS_FAIL=" 6.1.0-54-cloud-amd64 "
rc=0
install_nvidia_drivers_apt repair || rc=$?
assert_eq "1" "$rc" "repair: dkms fails for the newer kernel → repair fails"
assert_eq "none" "$GPU_TYPE" "repair: dkms failure → falls back to software transcoding"
assert_contains "${ERRORS[*]}" "sudo dkms autoinstall -k 6.1.0-54-cloud-amd64" "repair: dkms failure names the remedy command"
_kernel_fixture_end
# --- install route: the flavour headers metapackage rides along ---
# Given kernel 53 is running with no headers installed and apt has a linux-headers-cloud-amd64 candidate,
# When the Debian driver installs,
# Then the same transaction installs the running-kernel headers and the flavour metapackage,
# so a kernel installed later gets headers and DKMS builds its module.
_kernel_fixture
_fixture_apt_cache="$(declare -f apt-cache)"
apt-cache() {
    [[ "${1:-}" == "madison" && "${2:-}" == "linux-headers-cloud-amd64" ]] \
        && printf ' %s | 6.1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$2"
    eval "$_fixture_apt_cache; apt-cache \"\$@\""
}
rc=0
install_nvidia_drivers_apt || rc=$?
_driver_call=""
for _c in "${SUDO_CALLS[@]}"; do [[ "$_c" == *"nvidia-driver"* ]] && _driver_call="$_c"; done
assert_eq "0" "$rc" "install: flavour metapackage candidate → succeeds"
assert_contains "$_driver_call" "linux-headers-6.1.0-53-cloud-amd64" "install: the driver transaction carries the running-kernel headers"
assert_contains "$_driver_call" "linux-headers-cloud-amd64" "install: the driver transaction carries the flavour headers metapackage"
_kernel_fixture_end

# Given the flavour metapackage is already installed,
# When the Debian driver installs,
# Then the transaction does not list it again.
_kernel_fixture
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    printf ' %s | 6.1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$2"
}
_fixture_dpkg_query="$(declare -f dpkg-query)"
dpkg-query() {
    case "$*" in
        *linux-headers-cloud-amd64) printf 'install ok installed' ;;
        *) eval "$_fixture_dpkg_query; dpkg-query \"\$@\"" ;;
    esac
}
rc=0
install_nvidia_drivers_apt || rc=$?
_driver_call=""
for _c in "${SUDO_CALLS[@]}"; do [[ "$_c" == *"nvidia-driver"* ]] && _driver_call="$_c"; done
assert_not_contains "$_driver_call" "linux-headers-cloud-amd64" "install: an installed flavour metapackage is not added again"
_kernel_fixture_end
unset _fixture_apt_cache _fixture_dpkg_query _driver_call _c

# --- re-run with a healthy Debian driver: the real setup flow ---
# A healthy Debian driver maps to the "use" action and _stage3_nvidia_use_driver; it never
# reaches install_nvidia_drivers_apt. These cases drive _stage3_run_nvidia so they cover that path.
_FLOW_FUNCS=(nvidia_driver_healthy nvidia_driver_version ui_section ui_choose verify_gpu_usable
    _stage3_configure_and_verify _stage3_fallback ui_log)
_flow_fixture() {
    _kernel_fixture
    local _f
    for _f in "${_FLOW_FUNCS[@]}"; do _FLOW_SAVED+=("$(declare -f "$_f")"); done
    FLOW_HEALTH_CALLS=0
    FLOW_HEALTH_FIRST=0 # exit status of the first nvidia_driver_healthy call
    FLOW_CONFIGURED="" FLOW_FALLBACKS=0 WARNS=()
    FIXTURE_SOURCE=debian
    nvidia_driver_healthy() {
        ((++FLOW_HEALTH_CALLS == 1)) && return "$FLOW_HEALTH_FIRST"
        return 0
    }
    nvidia_driver_version() { printf '535.261.03'; }
    ui_section() { :; }
    ui_choose() {
        case "$1" in
            *"not healthy"*) printf 'Repair/reinstall Debian driver (recommended)' ;;
            *) printf 'Use installed driver 535.261.03 (recommended)' ;;
        esac
    }
    verify_gpu_usable() { :; }
    _stage3_configure_and_verify() {
        FLOW_CONFIGURED="$GPU_TYPE:$5"
        return 0
    }
    _stage3_fallback() { FLOW_FALLBACKS=$((FLOW_FALLBACKS + 1)); }
    ui_log() { [[ "$1" == warn ]] && WARNS+=("$*"); }
}
_flow_fixture_end() {
    local _f
    for _f in "${_FLOW_SAVED[@]}"; do eval "$_f"; done
    _FLOW_SAVED=()
    _kernel_fixture_end
    unset FLOW_HEALTH_CALLS FLOW_HEALTH_FIRST FLOW_CONFIGURED FLOW_FALLBACKS WARNS
}
_FLOW_SAVED=()

# Given a healthy Debian driver and a newer kernel 54 installed since, with no module built for it,
# When setup runs again and the user keeps the installed driver,
# Then headers and a DKMS build are added for kernel 54 and the GPU stays on.
_flow_fixture
DKMS_BUILT=" 6.1.0-53-cloud-amd64 "
_stage3_run_nvidia
_calls="${SUDO_CALLS[*]}"
assert_contains "$_calls" "linux-headers-6.1.0-54-cloud-amd64" "re-run: headers for the newer kernel are installed"
assert_contains "$_calls" "dkms autoinstall -k 6.1.0-54-cloud-amd64" "re-run: dkms builds the module for the newer kernel"
assert_eq "nvidia:standard" "$FLOW_CONFIGURED" "re-run: newer kernel without a module → NVENC configured in standard mode"
assert_eq "0" "$FLOW_FALLBACKS" "re-run: newer kernel without a module → no software fallback"
_flow_fixture_end

# Given a healthy Debian driver whose module is built for every boot kernel,
# When setup runs again,
# Then nothing is installed or built and the GPU stays on.
_flow_fixture
DKMS_BUILT=" 6.1.0-53-cloud-amd64 6.1.0-54-cloud-amd64 "
_stage3_run_nvidia
assert_eq "0" "${#SUDO_CALLS[@]}" "re-run: fully built host → no package or dkms command runs"
assert_eq "nvidia:standard" "$FLOW_CONFIGURED" "re-run: fully built host → NVENC configured in standard mode"
_flow_fixture_end

# Given a healthy Debian driver and a newer kernel whose module cannot be built,
# When setup runs again,
# Then it warns with the remedy and keeps the GPU on, because the running kernel works.
_flow_fixture
DKMS_BUILT=" 6.1.0-53-cloud-amd64 "
DKMS_FAIL=" 6.1.0-54-cloud-amd64 "
_stage3_run_nvidia
assert_contains "${ERRORS[*]}" "sudo dkms autoinstall -k 6.1.0-54-cloud-amd64" "re-run: dkms failure names the remedy command"
assert_contains "${WARNS[*]}" "running kernel" "re-run: dkms failure warns that only the running kernel is covered"
assert_eq "nvidia:standard" "$FLOW_CONFIGURED" "re-run: dkms failure → NVENC still configured"
assert_eq "0" "$FLOW_FALLBACKS" "re-run: dkms failure → no software fallback"
_flow_fixture_end

# Given a driver that MediaStack does not manage (existing mode) and a kernel without a module,
# When the existing driver is used,
# Then no package or dkms command runs.
_flow_fixture
DKMS_BUILT=" 6.1.0-53-cloud-amd64 "
_stage3_nvidia_use_driver existing "done"
assert_eq "0" "${#SUDO_CALLS[@]}" "existing driver: no kernel headers or dkms build for a user-managed driver"
assert_eq "nvidia:existing" "$FLOW_CONFIGURED" "existing driver: NVENC configured in existing mode"
_flow_fixture_end

# --- repair through the real setup flow ---
# Given an unhealthy Debian driver, kernels 53 and 54 without modules, and a flavour metapackage candidate,
# When the user picks Repair,
# Then the reinstall carries the flavour headers metapackage, so the next kernel upgrade builds its module.
_flow_fixture
FLOW_HEALTH_FIRST=1
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    printf ' %s | 6.1.0 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' "$2"
}
_stage3_run_nvidia
_reinstall=""
for _c in "${SUDO_CALLS[@]}"; do [[ "$_c" == *"--reinstall"* ]] && _reinstall="$_c"; done
assert_contains "$_reinstall" "--reinstall nvidia-driver" "repair flow: the driver packages are reinstalled"
assert_contains "$_reinstall" "linux-headers-cloud-amd64" "repair flow: the flavour headers metapackage is added"
assert_eq "nvidia:standard" "$FLOW_CONFIGURED" "repair flow: NVENC configured after the repair"
_flow_fixture_end
unset _reinstall _c _calls

# --- _nvidia_boot_kernels: unsigned image packages ---
# Given the only newer kernel is installed as linux-image-<ver>-unsigned,
# When the boot kernels are listed,
# Then the release is <ver>, with no "-unsigned" suffix, listed once.
_kernel_fixture
dpkg-query() {
    printf '%s\n' 'linux-image-6.1.0-54-cloud-amd64-unsigned ii' 'linux-image-6.1.0-55-cloud-amd64 ii' 'linux-image-6.1.0-55-cloud-amd64-unsigned ii'
}
_boots="$(_nvidia_boot_kernels | paste -sd' ')"
assert_eq "6.1.0-53-cloud-amd64 6.1.0-54-cloud-amd64 6.1.0-55-cloud-amd64" "$_boots" "boot kernels: an -unsigned image maps to its release, once"
_kernel_fixture_end
unset _boots

# --- dkms outside the user PATH ---
# Debian keeps dkms in /usr/sbin, which a normal user's PATH omits. These cases use a
# real executable in a fake sbin directory (no shell function), so a bare `dkms` call
# cannot see it. The module is already built for both kernels.
_sbin_dkms_fixture() {
    SBIN_FIXTURE=$(mktemp -d)
    mkdir -p "$SBIN_FIXTURE/sbin"
    cat >"$SBIN_FIXTURE/sbin/dkms" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "status" && "${2:-}" == "-k" ]] && printf 'nvidia-current/535.261.03, %s, x86_64: installed\n' "$3"
exit 0
SH
    chmod +x "$SBIN_FIXTURE/sbin/dkms"
    _saved_path="$PATH"
    _saved_sbin_dirs="${MS_SBIN_DIRS:-}"
    PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxE '/usr/sbin|/sbin' | paste -sd:)
    MS_SBIN_DIRS="$SBIN_FIXTURE/sbin"
    unset -f dkms
}
_sbin_dkms_fixture_end() {
    PATH="$_saved_path"
    MS_SBIN_DIRS="$_saved_sbin_dirs"
    [[ -n "$MS_SBIN_DIRS" ]] || unset MS_SBIN_DIRS
    rm -rf "$SBIN_FIXTURE"
    dkms() {
        [[ "${1:-}" == "status" && "${2:-}" == "-k" ]] || return 0
        [[ "$DKMS_BUILT" == *" $3 "* ]] && printf 'nvidia-current/535.261.03, %s, x86_64: installed\n' "$3"
        return 0
    }
    unset SBIN_FIXTURE _saved_path _saved_sbin_dirs
}

# Given dkms is installed only under a sbin directory and reports the module built for every kernel,
# When the Debian driver installs,
# Then the build is seen as present: no rebuild, no software fallback, no error.
_kernel_fixture
_sbin_dkms_fixture
rc=0
install_nvidia_drivers_apt || rc=$?
_calls="${SUDO_CALLS[*]}"
assert_eq "1" "$(command -v dkms >/dev/null 2>&1 && echo 0 || echo 1)" "sbin dkms: a bare dkms lookup cannot find the fixture"
assert_eq "0" "$rc" "sbin dkms install: module built in /usr/sbin dkms → install succeeds"
assert_eq "nvidia" "$GPU_TYPE" "sbin dkms install: no software fallback"
assert_not_contains "$_calls" "dkms autoinstall" "sbin dkms install: a built module is not rebuilt"
assert_eq "0" "${#ERRORS[@]}" "sbin dkms install: no remedy is printed for a build that exists"
_sbin_dkms_fixture_end
_kernel_fixture_end

# Given the same sbin-only dkms and a Debian driver already present,
# When the driver is repaired,
# Then the repair keeps GPU transcoding and prints no remedy.
_kernel_fixture
_sbin_dkms_fixture
FIXTURE_SOURCE=debian
rc=0
install_nvidia_drivers_apt repair || rc=$?
assert_eq "0" "$rc" "sbin dkms repair: module built in /usr/sbin dkms → repair succeeds"
assert_eq "nvidia" "$GPU_TYPE" "sbin dkms repair: no software fallback"
assert_eq "0" "${#ERRORS[@]}" "sbin dkms repair: no remedy is printed for a build that exists"
_sbin_dkms_fixture_end
_kernel_fixture_end

unset -f _kernel_fixture _kernel_fixture_end _sbin_dkms_fixture _sbin_dkms_fixture_end
unset _calls

# The mocked install tests above unset the real gpu.sh helpers (mock + real share
# one function slot). Re-source gpu.sh to restore nvidia_driver_ensure_debian_nonfree et al.
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/setup/gpu.sh"

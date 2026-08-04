# Owns: Debian NVIDIA resolver, apt installation, and conversion assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-apt.sh.
# shellcheck disable=SC2034 # GPU_TYPE is consumed by product code under test.
# Deterministic Debian release seams for the resolver/non-free assertions.
_debian_codename() { printf 'bookworm'; }
_debian_version_id() { printf '12'; }

# --- _resolve_debian_nvidia_driver: prefer the stable candidate ---
lspci() { printf '01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA104 [10de:2484]\n'; }
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    printf ' nvidia-driver | 535.100-1 | http://deb.debian.org/debian bookworm/non-free amd64 Packages\n'
}
_check_nvidia_compat() { printf 'current'; }
assert_eq "nvidia-driver firmware-misc-nonfree" "$(_resolve_debian_nvidia_driver)" \
    "_resolve_debian_nvidia_driver: stable candidate supports GPU → no backports"
unset -f apt-cache _check_nvidia_compat

# --- _resolve_debian_nvidia_driver: escalate to backports only on evidence ---
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    printf ' nvidia-driver | 535.100-1 | http://deb.debian.org/debian bookworm/non-free amd64 Packages\n'
    printf ' nvidia-driver | 550.100-1~bpo12+1 | http://deb.debian.org/debian bookworm-backports/non-free amd64 Packages\n'
}
# Stable does not list the GPU; backports does.
_check_nvidia_compat() { case "${1:-}" in 550.100) printf 'current' ;; *) return 1 ;; esac }
assert_eq "-t bookworm-backports nvidia-driver firmware-misc-nonfree" "$(_resolve_debian_nvidia_driver)" \
    "_resolve_debian_nvidia_driver: card too new for stable + backports newer & supported → backports"
unset -f apt-cache _check_nvidia_compat lspci

# --- install_nvidia_drivers_apt: pre-existing non-Debian driver → returns 2 ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { return 0; }
dpkg-query() { return 1; }
GPU_TYPE=nvidia
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "2" "$rc" "install_nvidia_drivers_apt: pre-existing non-Debian driver → returns 2 (caller prompts)"
unset -f dpkg-query nvidia-smi command

# --- install_nvidia_drivers_apt: Debian-managed driver present → standard, no patch ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { case "$*" in *--query-gpu*) printf '535.100\n' ;; *) return 0 ;; esac }
dpkg-query() { printf 'install ok installed'; }
_install_nvidia_container_toolkit() { return 0; }
PATCH_CALLED=0
apply_nvidia_patch() { PATCH_CALLED=1; }
GPU_TYPE=nvidia
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "install_nvidia_drivers_apt: Debian-managed driver → success"
assert_eq "standard" "$NVIDIA_DRIVER_MODE" "install_nvidia_drivers_apt: Debian-managed driver → mode standard"
assert_eq "0" "$PATCH_CALLED" "install_nvidia_drivers_apt: Standard route never applies the patch"
unset -f dpkg-query nvidia-smi command _install_nvidia_container_toolkit apply_nvidia_patch
unset PATCH_CALLED rc

# --- install_nvidia_drivers_apt: fresh install → standard + reboot, no patch ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-18-amd64\n' || builtin uname "$@"; }
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    case "${2:-}" in
        linux-headers-amd64) printf ' linux-headers-amd64 | 6.1.0-18 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' ;;
    esac
}
check_secure_boot() { printf 'disabled'; }
ensure_debian_nonfree() { return 0; }
_resolve_debian_nvidia_driver() { printf 'nvidia-driver firmware-misc-nonfree'; }
_install_nvidia_container_toolkit() { return 0; }
nouveau_is_active() { return 0; } # forces a reboot
PATCH_CALLED=0
apply_nvidia_patch() { PATCH_CALLED=1; }
INSTALL_ARGS=""
sudo() {
    case "${1:-}:${2:-}" in
        apt-get:install) INSTALL_ARGS="$*" ;;
    esac
    return 0
}
GPU_TYPE=nvidia
NEEDS_REBOOT=false
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "install_nvidia_drivers_apt: fresh apt install → success"
assert_eq "standard" "$NVIDIA_DRIVER_MODE" "install_nvidia_drivers_apt: fresh apt install → mode standard"
assert_eq "true" "$NEEDS_REBOOT" "install_nvidia_drivers_apt: fresh install with nouveau active → reboot required"
assert_eq "0" "$PATCH_CALLED" "install_nvidia_drivers_apt: fresh Standard install never patches"
assert_contains "$INSTALL_ARGS" "linux-headers-amd64" "install_nvidia_drivers_apt: fresh install appends resolved headers package"
unset -f command check_secure_boot ensure_debian_nonfree _resolve_debian_nvidia_driver \
    _install_nvidia_container_toolkit nouveau_is_active apply_nvidia_patch sudo dpkg-query uname apt-cache
unset PATCH_CALLED rc NEEDS_REBOOT INSTALL_ARGS

# --- _nvidia_headers_flavor: derive the meta-package suffix from uname -r ---
assert_eq "amd64" "$(_nvidia_headers_flavor '6.1.0-18-amd64')" \
    "_nvidia_headers_flavor: stock amd64"
assert_eq "cloud-amd64" "$(_nvidia_headers_flavor '6.1.0-51-cloud-amd64')" \
    "_nvidia_headers_flavor: cloud-amd64"
assert_eq "rt-amd64" "$(_nvidia_headers_flavor '6.1.0-18-rt-amd64')" \
    "_nvidia_headers_flavor: rt-amd64"
assert_eq "arm64" "$(_nvidia_headers_flavor '6.1.0-18-arm64')" \
    "_nvidia_headers_flavor: arm64"
if _nvidia_headers_flavor '6.5.0-custom' >/dev/null 2>&1; then
    fail "_nvidia_headers_flavor: custom kernel with no ABI segment has no derivable flavor"
else
    pass "_nvidia_headers_flavor: custom kernel with no ABI segment has no derivable flavor"
fi

# --- _nvidia_preflight_kernel_headers: headers already installed → pass, no install ---
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-18-amd64\n' || builtin uname "$@"; }
dpkg-query() { printf 'install ok installed'; }
apt-cache() { fail "_nvidia_preflight_kernel_headers: must not query apt-cache when headers are already installed"; }
_hdr_out=$(_nvidia_preflight_kernel_headers)
_hdr_rc=$?
assert_eq "0" "$_hdr_rc" "_nvidia_preflight_kernel_headers: headers already installed → pass"
assert_eq "" "$_hdr_out" "_nvidia_preflight_kernel_headers: headers already installed → nothing to append"
unset -f uname dpkg-query apt-cache
unset _hdr_out _hdr_rc

# --- _nvidia_preflight_kernel_headers: resolvable meta-package → appended ---
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-51-cloud-amd64\n' || builtin uname "$@"; }
dpkg-query() { return 1; } # exact per-build package not installed
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    case "${2:-}" in
        linux-headers-cloud-amd64) printf ' linux-headers-cloud-amd64 | 6.1.0-51 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' ;;
    esac
}
_hdr_out=$(_nvidia_preflight_kernel_headers)
_hdr_rc=$?
assert_eq "0" "$_hdr_rc" "_nvidia_preflight_kernel_headers: resolvable meta-package → pass"
assert_eq "linux-headers-cloud-amd64" "$_hdr_out" "_nvidia_preflight_kernel_headers: resolvable meta-package → echoed for the caller to append"
unset -f uname dpkg-query apt-cache
unset _hdr_out _hdr_rc

# --- _nvidia_preflight_kernel_headers: unresolvable → fails, names kernel + packages looked for ---
uname() { [[ "${1:-}" == "-r" ]] && printf '6.5.0-custom\n' || builtin uname "$@"; }
dpkg-query() { return 1; }
apt-cache() { [[ "${1:-}" == "madison" ]] || return 0; }
_err_cap=$(mktemp)
log_error() { printf '%s' "$1" >"$_err_cap"; }
_hdr_out=$(_nvidia_preflight_kernel_headers)
_hdr_rc=$?
_logged_error=$(cat "$_err_cap")
rm -f "$_err_cap"
assert_eq "1" "$_hdr_rc" "_nvidia_preflight_kernel_headers: unresolvable → fails"
assert_eq "" "$_hdr_out" "_nvidia_preflight_kernel_headers: unresolvable → nothing to append"
assert_contains "$_logged_error" "6.5.0-custom" "_nvidia_preflight_kernel_headers: error names the running kernel"
assert_contains "$_logged_error" "linux-headers-6.5.0-custom" "_nvidia_preflight_kernel_headers: error names the exact package looked for"
unset -f uname dpkg-query apt-cache log_error
unset _hdr_out _hdr_rc _err_cap _logged_error
log_error() { :; }

# --- install_nvidia_drivers_apt: headers unresolvable → fallback, no driver install attempted ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
uname() { [[ "${1:-}" == "-r" ]] && printf '6.5.0-custom\n' || builtin uname "$@"; }
apt-cache() { [[ "${1:-}" == "madison" ]] || return 0; }
check_secure_boot() { printf 'disabled'; }
ensure_debian_nonfree() { return 0; }
INSTALL_CALLED=0
sudo() {
    case "${1:-}:${2:-}" in
        apt-get:install) INSTALL_CALLED=1 ;;
    esac
    return 0
}
GPU_TYPE=nvidia
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "install_nvidia_drivers_apt: unresolvable headers → falls back"
assert_eq "none" "$GPU_TYPE" "install_nvidia_drivers_apt: unresolvable headers → GPU_TYPE=none"
assert_eq "0" "$INSTALL_CALLED" "install_nvidia_drivers_apt: unresolvable headers → no half-install of the driver"
unset -f command check_secure_boot ensure_debian_nonfree sudo dpkg-query uname apt-cache
unset INSTALL_CALLED rc GPU_TYPE NVIDIA_DRIVER_MODE

# --- install_nvidia_drivers_apt: backports "-t" + flavor meta headers → version-pinned ---
# "-t <release>" scopes every package to backports; the flavor meta could then
# resolve to headers for a kernel other than the running one. The transaction
# must pin the preflight-validated candidate.
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-51-cloud-amd64\n' || builtin uname "$@"; }
apt-cache() {
    [[ "${1:-}" == "madison" ]] || return 0
    case "${2:-}" in
        linux-headers-cloud-amd64) printf ' linux-headers-cloud-amd64 | 6.1.85-1 | http://deb.debian.org/debian bookworm/main amd64 Packages\n' ;;
    esac
}
check_secure_boot() { printf 'disabled'; }
ensure_debian_nonfree() { return 0; }
_resolve_debian_nvidia_driver() { printf -- '-t bookworm-backports nvidia-driver firmware-misc-nonfree'; }
_install_nvidia_container_toolkit() { return 0; }
nouveau_is_active() { return 0; }
INSTALL_ARGS=""
sudo() {
    case "${1:-}:${2:-}" in
        apt-get:install) INSTALL_ARGS="$*" ;;
    esac
    return 0
}
GPU_TYPE=nvidia
NEEDS_REBOOT=false
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "install_nvidia_drivers_apt: backports install with meta headers → success"
assert_contains "$INSTALL_ARGS" "linux-headers-cloud-amd64=6.1.85-1" \
    "install_nvidia_drivers_apt: backports \"-t\" pins the headers meta to the preflight-validated version"
unset -f command check_secure_boot ensure_debian_nonfree _resolve_debian_nvidia_driver \
    _install_nvidia_container_toolkit nouveau_is_active sudo dpkg-query uname apt-cache
unset INSTALL_ARGS rc GPU_TYPE NEEDS_REBOOT NVIDIA_DRIVER_MODE

# --- install_nvidia_drivers_apt repair: one reinstall, no toolkit package transaction ---
nvidia_driver_source() { printf 'debian'; }
check_secure_boot() { printf 'disabled'; }
ensure_debian_nonfree() { return 0; }
_nvidia_debian_repair_packages() { printf '%s\n' nvidia-driver libnvidia-encode1:amd64; }
_nvidia_toolkit_healthy() { return 0; }
TOOLKIT_CONFIGURES=0
_configure_nvidia_container_toolkit() {
    TOOLKIT_CONFIGURES=$((TOOLKIT_CONFIGURES + 1))
    return 0
}
REPAIR_CALLS=()
sudo() {
    REPAIR_CALLS+=("$*")
    return 0
}
GPU_TYPE=nvidia
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt repair || rc=$?
assert_eq "0" "$rc" "install_nvidia_drivers_apt repair: succeeds"
assert_contains "${REPAIR_CALLS[*]}" "apt-get update -qq" "install_nvidia_drivers_apt repair: refreshes apt metadata"
assert_contains "${REPAIR_CALLS[*]}" "apt-get install -y -qq --reinstall nvidia-driver libnvidia-encode1:amd64" "install_nvidia_drivers_apt repair: reinstalls existing driver/userspace packages once"
assert_eq "1" "$TOOLKIT_CONFIGURES" "install_nvidia_drivers_apt repair: configures toolkit once"
assert_eq "standard" "$NVIDIA_DRIVER_MODE" "install_nvidia_drivers_apt repair: persists Standard mode"
unset -f nvidia_driver_source check_secure_boot ensure_debian_nonfree _nvidia_debian_repair_packages \
    _nvidia_toolkit_healthy _configure_nvidia_container_toolkit sudo
unset TOOLKIT_CONFIGURES REPAIR_CALLS GPU_TYPE NVIDIA_DRIVER_MODE rc
source "$REPO_ROOT/scripts/setup/gpu.sh"
set +e
set +u

# --- Standard → Unlock conversion: purge exact driver packages, preserve toolkit ---
dpkg-query() {
    cat <<'EOF'
nvidia-driver ii
nvidia-kernel-dkms ii
libcuda1:amd64 ii
libnvidia-encode1:amd64 ii
cuda-toolkit-12-5 ii
nvidia-container-toolkit ii
nvidia-container-toolkit-base ii
libnvidia-container-tools ii
libnvidia-container1:amd64 ii
glx-alternative-mesa ii
glx-diversions ii
glx-alternative-nvidia ii
EOF
}
_pkg_list=$(_nvidia_debian_driver_packages | tr '\n' ' ')
assert_contains "$_pkg_list" "nvidia-driver" "_nvidia_debian_driver_packages: includes Debian driver packages"
assert_contains "$_pkg_list" "libcuda1:amd64" "_nvidia_debian_driver_packages: includes CUDA userspace package"
assert_contains "$_pkg_list" "glx-diversions" "_nvidia_debian_driver_packages: includes NVIDIA GLX framework package"
assert_contains "$_pkg_list" "glx-alternative-nvidia" "_nvidia_debian_driver_packages: includes NVIDIA GLX alternative package"
case "$_pkg_list" in
    *nvidia-container-toolkit* | *libnvidia-container1* | *glx-alternative-mesa*)
        fail "_nvidia_debian_driver_packages: excludes toolkit and mesa alternatives"
        ;;
    *)
        pass "_nvidia_debian_driver_packages: excludes toolkit and mesa alternatives"
        ;;
esac
_repair_pkg_list=$(_nvidia_debian_repair_packages | tr '\n' ' ')
assert_contains "$_repair_pkg_list" "libcuda1:amd64" "_nvidia_debian_repair_packages: includes Debian CUDA runtime"
assert_contains "$_repair_pkg_list" "glx-alternative-nvidia" "_nvidia_debian_repair_packages: includes Debian GLX userspace"
case "$_repair_pkg_list" in
    *cuda-toolkit* | *nvidia-container-toolkit* | *libnvidia-container*)
        fail "_nvidia_debian_repair_packages: excludes CUDA SDK and container toolkit packages"
        ;;
    *) pass "_nvidia_debian_repair_packages: excludes CUDA SDK and container toolkit packages" ;;
esac
unset -f dpkg-query
unset _pkg_list _repair_pkg_list

sudo() { return 0; }
lsmod() { printf 'nvidia_uvm 1 0\nsnd 1 0\n'; }
if _nvidia_unload_loaded_modules; then
    fail "_nvidia_unload_loaded_modules: detects still-loaded NVIDIA modules"
else
    pass "_nvidia_unload_loaded_modules: detects still-loaded NVIDIA modules"
fi
lsmod() { printf 'snd 1 0\n'; }
if _nvidia_unload_loaded_modules; then
    pass "_nvidia_unload_loaded_modules: succeeds when NVIDIA modules are absent"
else
    fail "_nvidia_unload_loaded_modules: succeeds when NVIDIA modules are absent"
fi
unset -f sudo lsmod

dpkg-query() {
    cat <<'EOF'
nvidia-driver ii
libcuda1:amd64 ii
nvidia-container-toolkit ii
EOF
}
sudo() {
    local args=("$@")
    [[ "${args[0]:-}" == DEBIAN_FRONTEND=* ]] && args=("${args[@]:1}")
    case "${args[0]:-}:${args[1]:-}" in
        apt-mark:manual)
            APT_MARK_CALLED=1
            return 0
            ;;
        apt-get:purge)
            PURGE_ARGS="${args[*]}"
            return 0
            ;;
        *) return 0 ;;
    esac
}
_nvidia_unload_loaded_modules() { return 0; }
_nvidia_blacklist_nouveau() {
    BLACKLIST_CALLED=1
    return 0
}
NEEDS_REBOOT=false
APT_MARK_CALLED=0
PURGE_ARGS=""
BLACKLIST_CALLED=0
rc=0
prepare_nvidia_debian_to_unlock || rc=$?
assert_eq "0" "$rc" "prepare_nvidia_debian_to_unlock: exact purge succeeds"
assert_eq "1" "$APT_MARK_CALLED" "prepare_nvidia_debian_to_unlock: marks toolkit packages manual"
assert_contains "$PURGE_ARGS" "nvidia-driver" "prepare_nvidia_debian_to_unlock: purges nvidia-driver"
case "$PURGE_ARGS" in
    *nvidia-container-toolkit*) fail "prepare_nvidia_debian_to_unlock: must not purge toolkit" ;;
    *) pass "prepare_nvidia_debian_to_unlock: does not purge toolkit" ;;
esac
assert_eq "false" "$NEEDS_REBOOT" "prepare_nvidia_debian_to_unlock: no reboot when modules unload"
assert_eq "0" "$BLACKLIST_CALLED" "prepare_nvidia_debian_to_unlock: no blacklist when modules unload"
unset -f dpkg-query sudo _nvidia_unload_loaded_modules _nvidia_blacklist_nouveau
unset NEEDS_REBOOT APT_MARK_CALLED PURGE_ARGS BLACKLIST_CALLED rc

dpkg-query() { printf 'nvidia-driver ii \n'; }
sudo() {
    local args=("$@")
    [[ "${args[0]:-}" == DEBIAN_FRONTEND=* ]] && args=("${args[@]:1}")
    case "${args[0]:-}:${args[1]:-}" in
        apt-get:purge | apt-mark:manual) return 0 ;;
        *) return 0 ;;
    esac
}
_nvidia_unload_loaded_modules() { return 1; }
_nvidia_blacklist_nouveau() {
    BLACKLIST_CALLED=1
    return 0
}
NEEDS_REBOOT=false
BLACKLIST_CALLED=0
rc=0
prepare_nvidia_debian_to_unlock || rc=$?
assert_eq "0" "$rc" "prepare_nvidia_debian_to_unlock: still succeeds when reboot is needed"
assert_eq "true" "$NEEDS_REBOOT" "prepare_nvidia_debian_to_unlock: queues reboot when modules stay loaded"
assert_eq "1" "$BLACKLIST_CALLED" "prepare_nvidia_debian_to_unlock: blacklists nouveau before conversion reboot"
unset -f dpkg-query sudo _nvidia_unload_loaded_modules _nvidia_blacklist_nouveau
unset NEEDS_REBOOT BLACKLIST_CALLED rc

# --- nvidia-container-toolkit health: binary presence is not enough ---
command() {
    if [[ "${1:-}" == "-v" && ("${2:-}" == "nvidia-container-runtime" || "${2:-}" == "nvidia-container-cli") ]]; then
        return 0
    fi
    builtin command "$@"
}
ldd() { printf 'libnvidia-container.so.1 => not found\n'; }
if _nvidia_toolkit_healthy; then
    fail "_nvidia_toolkit_healthy: missing linked library is unhealthy"
else
    pass "_nvidia_toolkit_healthy: missing linked library is unhealthy"
fi
unset -f command ldd

command() {
    if [[ "${1:-}" == "-v" && ("${2:-}" == "nvidia-container-runtime" || "${2:-}" == "nvidia-container-cli") ]]; then
        return 0
    fi
    builtin command "$@"
}
ldd() { printf 'libnvidia-container.so.1 => /usr/lib/libnvidia-container.so.1\n'; }
assert_eq "0" "$(
    _nvidia_toolkit_healthy
    echo $?
)" "_nvidia_toolkit_healthy: linked toolkit is healthy"
unset -f command ldd

# The mocked install tests above unset the real gpu.sh helpers (mock + real share
# one function slot). Re-source gpu.sh to restore ensure_debian_nonfree et al.
# shellcheck source=../../scripts/setup/gpu.sh
source "$REPO_ROOT/scripts/setup/gpu.sh"

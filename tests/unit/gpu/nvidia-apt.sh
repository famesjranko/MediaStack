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
check_secure_boot() { printf 'disabled'; }
ensure_debian_nonfree() { return 0; }
_resolve_debian_nvidia_driver() { printf 'nvidia-driver firmware-misc-nonfree'; }
_install_nvidia_container_toolkit() { return 0; }
nouveau_is_active() { return 0; } # forces a reboot
PATCH_CALLED=0
apply_nvidia_patch() { PATCH_CALLED=1; }
sudo() { return 0; }
GPU_TYPE=nvidia
NEEDS_REBOOT=false
NVIDIA_DRIVER_MODE=""
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "install_nvidia_drivers_apt: fresh apt install → success"
assert_eq "standard" "$NVIDIA_DRIVER_MODE" "install_nvidia_drivers_apt: fresh apt install → mode standard"
assert_eq "true" "$NEEDS_REBOOT" "install_nvidia_drivers_apt: fresh install with nouveau active → reboot required"
assert_eq "0" "$PATCH_CALLED" "install_nvidia_drivers_apt: fresh Standard install never patches"
unset -f command check_secure_boot ensure_debian_nonfree _resolve_debian_nvidia_driver \
    _install_nvidia_container_toolkit nouveau_is_active apply_nvidia_patch sudo dpkg-query
unset PATCH_CALLED rc NEEDS_REBOOT

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

#!/usr/bin/env bash
# tests/unit/gpu-branching.sh
#
# Pure-bash unit test for the GPU helpers in setup.sh: detect_gpu,
# check_secure_boot, verify_gpu_usable. No DinD, no Docker, no network.
#
# Shims are defined as bash functions in the test shell — when setup.sh's
# helpers call `lspci` / `mokutil` / `nvidia-smi` / `docker`, the in-shell
# function wins over PATH. `command -v` absence is simulated by overriding
# `command` itself (since mokutil may actually exist on the host).
#
# Render-node cases are mocked in-shell so this unit is deterministic on hosts
# with Intel, AMD, NVIDIA, or no GPU hardware.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="gpu-branching"
echo -e "${CYAN}${BOLD}▶ scenario: gpu-branching${NC}"

# Source setup.sh for the helper functions. The guard added to setup.sh's
# bottom ensures main() does not run under `source`.
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# setup.sh sets -euo pipefail; relax so asserts can run a full pass/fail.
set +e
set +u

# Silence log_* output from the helpers — the test drives its own assertions.
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# ui_spin normally runs its command in a background subshell (the spinner owns
# the TTY), which discards mock side-effects (e.g. an array a stubbed sudo fills).
# Run the wrapped command in-process so call-capturing mocks observe the calls.
ui_spin() {
    shift
    "$@"
}

# ---------------------------------------------------------------------------
# detect_gpu
# ---------------------------------------------------------------------------

lspci() { printf '01:00.0 VGA compatible controller: NVIDIA Corporation GA104\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "nvidia" "$GPU_TYPE" "detect_gpu: nvidia via VGA line"
unset -f lspci

lspci() {
    printf '%s\n' \
        '00:00.0 Host bridge: Intel Corporation Host Bridge' \
        '00:02.0 Display controller: Intel Corporation UHD Graphics' \
        '01:00.0 VGA compatible controller: NVIDIA Corporation GA104' \
        '02:00.0 3D controller: NVIDIA Corporation GA104' \
        '03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 14'
}
JELLYFIN_GPU=amd
GPU_TYPE=""
detect_gpu
assert_eq "nvidia amd intel" "${GPU_CANDIDATES[*]}" "detect_gpu: mixed vendors are deduplicated in priority order"
assert_eq "amd" "$GPU_TYPE" "detect_gpu: configured available vendor becomes the default"
unset JELLYFIN_GPU
unset -f lspci

lspci() { printf '06:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 14\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "amd" "$GPU_TYPE" "detect_gpu: amd via VGA line"
unset -f lspci

lspci() { printf '06:00.0 VGA compatible controller: Radeon RX 580 Series\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "amd" "$GPU_TYPE" "detect_gpu: amd via Radeon branding"
unset -f lspci

lspci() { printf '00:02.0 VGA compatible controller: Intel Corporation UHD Graphics\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "intel" "$GPU_TYPE" "detect_gpu: intel via VGA line"
unset -f lspci

# Headless Intel iGPU shows as "Display controller", not "VGA"
lspci() { printf '00:02.0 Display controller: Intel Corporation UHD Graphics 630\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "intel" "$GPU_TYPE" "detect_gpu: intel via Display controller (headless)"
unset -f lspci

# Non-GPU AMD device (chipset/bridge) should NOT match — display-class filter
lspci() { printf '00:00.0 Host bridge: Advanced Micro Devices, Inc. [AMD] Starship/Matisse Root Complex\n00:01.0 SATA controller: AMD FCH SATA Controller\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: AMD chipset without VGA line → none"
unset -f lspci

# Empty lspci → none (no renderD128 fallback)
lspci() { :; }
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: empty lspci → none"
unset -f lspci

(
    set -euo pipefail
    log_ok() { :; }
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    lspci() { :; }
    GPU_TYPE=""
    detect_gpu
    [[ "$GPU_TYPE" == "none" ]]
)
assert_eq "0" "$?" "detect_gpu: empty lspci does not abort under set -e"
unset -f lspci

# Missing lspci command → none with warning
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "lspci" ]]; then
        return 1
    fi
    builtin command "$@"
}
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: lspci missing → none"
unset -f command

# ---------------------------------------------------------------------------
# check_secure_boot
# ---------------------------------------------------------------------------

mokutil() { echo "SecureBoot enabled"; }
state=$(check_secure_boot)
assert_eq "enabled" "$state" "check_secure_boot: SB enabled"
unset -f mokutil

mokutil() { echo "SecureBoot disabled"; }
state=$(check_secure_boot)
assert_eq "disabled" "$state" "check_secure_boot: SB disabled"
unset -f mokutil

# Simulate "mokutil not installed" by lying to `command -v`. The host may
# have /usr/bin/mokutil; we can't rely on PATH manipulation alone.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "mokutil" ]]; then
        return 1
    fi
    builtin command "$@"
}
sudo() { return 1; }
state=$(check_secure_boot)
assert_eq "unavailable" "$state" "check_secure_boot: mokutil absent"
unset -f command sudo

# ---------------------------------------------------------------------------
# verify_gpu_usable
# ---------------------------------------------------------------------------

# NVIDIA runtime verification (regression coverage).
#
# Safety: verify_gpu_usable self-heals a CONFIRMED-unregistered runtime by calling
# `sudo nvidia-ctk runtime configure` + `sudo systemctl restart docker`. These MUST
# be stubbed so the unit never reconfigures or restarts the host's Docker. The
# docker() stub reports the nvidia runtime present iff _RT_REGISTERED is set;
# nvidia-ctk() flips it (models a successful reconfigure); systemctl()/service()
# count restarts so we can assert the daemon is bounced ONLY on confirmed-absent
# and NEVER on a registered runtime or an inconclusive 'unknown' probe.
command() { # resolve nvidia-smi + nvidia-container-runtime regardless of host
    case "${1:-}:${2:-}" in
        -v:nvidia-smi | -v:nvidia-container-runtime) return 0 ;;
    esac
    builtin command "$@"
}
nvidia-smi() {
    [[ "${1:-}" == "-L" ]] && echo "GPU 0: NVIDIA Shim"
    return 0
}
_SYSCTL_CALLS=0
systemctl() {
    _SYSCTL_CALLS=$((_SYSCTL_CALLS + 1))
    return 0
} # count; never touch host
service() {
    _SYSCTL_CALLS=$((_SYSCTL_CALLS + 1))
    return 0
}
sleep() { :; }   # skip the retry backoff in tests
sudo() { "$@"; } # run the (stubbed) privileged target
_RT_REGISTERED=1
nvidia-ctk() { _RT_REGISTERED=1; } # a successful reconfigure registers nvidia
_dk_info() { ((_RT_REGISTERED)) && printf 'io.containerd.runc.v2 nvidia runc \n' || printf 'io.containerd.runc.v2 runc \n'; }

# (1) happy path: runtime already registered → no Docker restart
docker() {
    [[ "${1:-}" == "info" ]] && {
        _dk_info
        return 0
    }
    return 0
}
_RT_REGISTERED=1
_SYSCTL_CALLS=0
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "nvidia" "$GPU_TYPE" "verify_gpu_usable: nvidia + runtime registered"
assert_eq "0" "$_SYSCTL_CALLS" "verify_gpu_usable: registered runtime does NOT restart Docker"

# (2) nvidia-smi missing → downgrade
command() {
    [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-smi" ]] && return 1
    builtin command "$@"
}
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "none" "$GPU_TYPE" "verify_gpu_usable: nvidia-smi missing → downgrade"
command() {
    case "${1:-}:${2:-}" in -v:nvidia-smi | -v:nvidia-container-runtime) return 0 ;; esac
    builtin command "$@"
}

# (3) Regression: docker info transiently FAILS under load then succeeds.
#     The old single un-retried `docker info | grep -q` fell back to software
#     here; the retry must ride it out and keep the GPU. A flag file marks the
#     first call (state persists across the command-substitution subshells the
#     helper uses, unlike a shell-variable counter).
_dk_flag="$(mktemp -u)"
docker() {
    if [[ "${1:-}" == "info" ]]; then
        if [[ ! -e "$_dk_flag" ]]; then
            : >"$_dk_flag"
            return 1
        fi # first call: busy daemon
        _dk_info
        return 0
    fi
    return 0
}
_RT_REGISTERED=1
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "nvidia" "$GPU_TYPE" "verify_gpu_usable: transient docker-info failure retried, not downgraded"
rm -f "$_dk_flag"

# (4) runtime genuinely unregistered but self-heal reconfigures it → stays nvidia
docker() {
    [[ "${1:-}" == "info" ]] && {
        _dk_info
        return 0
    }
    return 0
}
_RT_REGISTERED=0
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "nvidia" "$GPU_TYPE" "verify_gpu_usable: unregistered runtime self-healed via nvidia-ctk → stays nvidia"

# (5) runtime unregistered AND reconfigure cannot fix it → downgrade, after a real restart attempt
_RT_REGISTERED=0
_SYSCTL_CALLS=0
nvidia-ctk() { :; } # broken host: reconfigure does not register
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "none" "$GPU_TYPE" "verify_gpu_usable: runtime unregisterable → downgrade to software"
assert_eq "1" "$_SYSCTL_CALLS" "verify_gpu_usable: confirmed-absent runtime triggers exactly one Docker restart"
nvidia-ctk() { _RT_REGISTERED=1; } # restore

# (6) docker info unreadable after retries → 'unknown': keep nvidia (no false
#     downgrade) and do NOT bounce a possibly-healthy daemon.
docker() {
    [[ "${1:-}" == "info" ]] && return 1
    return 0
} # daemon never answers info
_RT_REGISTERED=1
_SYSCTL_CALLS=0
GPU_TYPE="nvidia"
verify_gpu_usable
assert_eq "nvidia" "$GPU_TYPE" "verify_gpu_usable: unknown runtime state keeps nvidia (no false downgrade)"
assert_eq "0" "$_SYSCTL_CALLS" "verify_gpu_usable: unknown state does NOT restart Docker (no stack bounce)"

unset -f command nvidia-smi systemctl service sleep sudo nvidia-ctk _dk_info docker
unset _RT_REGISTERED _SYSCTL_CALLS _dk_flag

# Intel/AMD render-node branches are mocked so the unit does not depend on the
# host's real /dev/dri state or GPU vendor.
gpu_render_device_for_vendor() {
    local vendor="${1:-}"
    [[ "${TEST_RENDER_DEVICE_AVAILABLE:-0}" == "1" ]] || return 1
    [[ "${TEST_RENDER_DEVICE_VENDOR:-}" == "$vendor" ]] || return 1
    printf '%s\n' "/dev/dri/renderD128"
}
gpu_render_device_exists() {
    [[ "${TEST_RENDER_DEVICE_AVAILABLE:-0}" == "1" && "${1:-}" == "/dev/dri/renderD128" ]]
}
gpu_render_device_vendor_matches() {
    [[ "${TEST_RENDER_DEVICE_VENDOR:-}" == "${2:-}" ]]
}

for render_vendor in intel amd; do
    TEST_RENDER_DEVICE_AVAILABLE=1
    TEST_RENDER_DEVICE_VENDOR="$render_vendor"
    unset STAGE_3_GPU_RENDER_DEVICE
    GPU_TYPE="$render_vendor"
    verify_gpu_usable
    assert_eq "$render_vendor" "$GPU_TYPE" "verify_gpu_usable: $render_vendor + vendor render device present"
    assert_eq "/dev/dri/renderD128" "$STAGE_3_GPU_RENDER_DEVICE" "verify_gpu_usable: $render_vendor records vendor render device"

    TEST_RENDER_DEVICE_AVAILABLE=0
    TEST_RENDER_DEVICE_VENDOR="$render_vendor"
    unset STAGE_3_GPU_RENDER_DEVICE
    GPU_TYPE="$render_vendor"
    verify_gpu_usable
    assert_eq "none" "$GPU_TYPE" "verify_gpu_usable: $render_vendor + no vendor render device → downgrade"
done

TEST_RENDER_DEVICE_AVAILABLE=1
TEST_RENDER_DEVICE_VENDOR=intel
unset STAGE_3_GPU_RENDER_DEVICE
GPU_TYPE="amd"
verify_gpu_usable
assert_eq "none" "$GPU_TYPE" "verify_gpu_usable: amd + non-AMD render device → downgrade"
unset TEST_RENDER_DEVICE_AVAILABLE TEST_RENDER_DEVICE_VENDOR

gpu_render_device_for_vendor() {
    printf '%s\n' "/dev/dri/renderD128"
}
gpu_render_device_exists() {
    case "$1" in
        /dev/dri/renderD128) return 0 ;;
        /dev/dri/renderD129) [[ "${TEST_RENDERD129_EXISTS:-0}" == "1" ]] ;;
        *) return 1 ;;
    esac
}
gpu_render_device_vendor_matches() {
    [[ "${TEST_RENDERD129_VENDOR_MISMATCH:-0}:$1" != "1:/dev/dri/renderD129" ]]
}
for render_vendor in intel amd; do
    TEST_RENDERD129_EXISTS=1
    TEST_RENDERD129_VENDOR_MISMATCH=0
    STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
    GPU_TYPE="$render_vendor"
    verify_gpu_usable
    assert_eq "$render_vendor" "$GPU_TYPE" "verify_gpu_usable: $render_vendor persisted render device keeps GPU usable"
    assert_eq "/dev/dri/renderD129" "$STAGE_3_GPU_RENDER_DEVICE" "verify_gpu_usable: $render_vendor preserves persisted render device before auto-detection"
done
TEST_RENDERD129_EXISTS=0
TEST_RENDERD129_VENDOR_MISMATCH=0
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
GPU_TYPE="intel"
verify_gpu_usable
assert_eq "/dev/dri/renderD128" "$STAGE_3_GPU_RENDER_DEVICE" "verify_gpu_usable: stale persisted render device falls back to auto-detection"
TEST_RENDERD129_EXISTS=1
TEST_RENDERD129_VENDOR_MISMATCH=1
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
GPU_TYPE="amd"
verify_gpu_usable
assert_eq "/dev/dri/renderD128" "$STAGE_3_GPU_RENDER_DEVICE" "verify_gpu_usable: vendor-mismatched persisted render device falls back to auto-detection"
STAGE_3_GPU_RENDER_DEVICE=../../renderD129
GPU_TYPE="intel"
verify_gpu_usable
assert_eq "/dev/dri/renderD128" "$STAGE_3_GPU_RENDER_DEVICE" "verify_gpu_usable: unsafe persisted render device falls back to auto-detection"
unset TEST_RENDERD129_EXISTS TEST_RENDERD129_VENDOR_MISMATCH
unset -f gpu_render_device_exists gpu_render_device_vendor_matches
gpu_render_device_for_vendor() { return 1; }
unset STAGE_3_GPU_RENDER_DEVICE

# none: no-op
GPU_TYPE="none"
verify_gpu_usable
assert_eq "none" "$GPU_TYPE" "verify_gpu_usable: none → none"

# ---------------------------------------------------------------------------
# install_amd_drivers / install_intel_drivers
# ---------------------------------------------------------------------------

INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
log_ok() { INSTALL_LOG_MESSAGES+=("$1"); }
log_info() { :; }
log_warn() { :; }
log_error() { INSTALL_ERROR_MESSAGES+=("$1"); }
sudo() { :; }

# AMD already installed
dpkg() { return 0; }
INSTALL_LOG_MESSAGES=()
install_amd_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "AMD VAAPI drivers already installed"; then
    pass "install_amd_drivers: already installed → skipped"
else
    fail "install_amd_drivers: already installed → skipped"
fi
unset -f dpkg

# AMD fresh install
dpkg() { return 1; }
INSTALL_LOG_MESSAGES=()
install_amd_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "AMD VAAPI drivers installed"; then
    pass "install_amd_drivers: fresh install → installed"
else
    fail "install_amd_drivers: fresh install → installed"
fi
unset -f dpkg

# AMD install failure
dpkg() { return 1; }
apt-cache() { printf '%s\n' "non-free"; }
sudo() {
    if [[ "${1:-}" == "apt-get" && "${2:-}" == "install" ]]; then
        return 42
    fi
    return 0
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if install_amd_drivers; then
    fail "install_amd_drivers: apt install failure returns nonzero"
else
    pass "install_amd_drivers: apt install failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install AMD VAAPI drivers" "install_amd_drivers: apt install failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"AMD VAAPI drivers installed"*) fail "install_amd_drivers: failed install does not log success" ;;
    *) pass "install_amd_drivers: failed install does not log success" ;;
esac
unset -f dpkg apt-cache sudo
sudo() { :; }

# Intel already installed
dpkg() { return 0; }
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
install_intel_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "Intel media drivers already installed"; then
    pass "install_intel_drivers: already installed → skipped"
else
    fail "install_intel_drivers: already installed → skipped"
fi
unset -f dpkg

# Intel fresh install
dpkg() { return 1; }
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
install_intel_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "Intel media drivers installed"; then
    pass "install_intel_drivers: fresh install → installed"
else
    fail "install_intel_drivers: fresh install → installed"
fi
unset -f dpkg

# Intel apt metadata failure
dpkg() { return 1; }
apt-cache() { printf '%s\n' "non-free"; }
sudo() {
    if [[ "${1:-}" == "apt-get" && "${2:-}" == "update" ]]; then
        return 43
    fi
    return 0
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if install_intel_drivers; then
    fail "install_intel_drivers: apt update failure returns nonzero"
else
    pass "install_intel_drivers: apt update failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to update apt metadata for Intel media drivers" "install_intel_drivers: apt update failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"Intel media drivers installed"*) fail "install_intel_drivers: failed update does not log success" ;;
    *) pass "install_intel_drivers: failed update does not log success" ;;
esac
unset -f dpkg apt-cache sudo

# NVIDIA driver resolver curl failures
_nvidia_tmp="$(mktemp -d)"
_driver_ver=""
_run_file=""
curl() { return 45; }
INSTALL_ERROR_MESSAGES=()
if _resolve_nvidia_driver; then
    fail "_resolve_nvidia_driver: README curl failure returns nonzero"
else
    pass "_resolve_nvidia_driver: README curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Could not fetch nvidia-patch README" "_resolve_nvidia_driver: README curl failure logs error"
unset -f curl

_driver_ver=""
_run_file=""
lspci() { :; }
curl() {
    case "$*" in
        *raw.githubusercontent.com*)
            printf '%s\n' '| 580.142 | Linux x86_64 | YES | [driver](https://download.nvidia.com/XFree86/Linux-x86_64/580.142/NVIDIA-Linux-x86_64-580.142.run) |'
            return 0
            ;;
        *NVIDIA-Linux-x86_64-580.142.run*)
            return 46
            ;;
        *)
            return 1
            ;;
    esac
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if _resolve_nvidia_driver; then
    fail "_resolve_nvidia_driver: driver download curl failure returns nonzero"
else
    pass "_resolve_nvidia_driver: driver download curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to download driver 580.142" "_resolve_nvidia_driver: driver download curl failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"NVIDIA driver 580.142 downloaded"*) fail "_resolve_nvidia_driver: failed download does not log success" ;;
    *) pass "_resolve_nvidia_driver: failed download does not log success" ;;
esac
rm -rf "$_nvidia_tmp"
unset _nvidia_tmp _driver_ver _run_file
unset -f curl lspci

# NVIDIA container toolkit curl failures
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-container-runtime" ]]; then
        return 1
    fi
    builtin command "$@"
}
curl() { return 47; }
sudo() {
    cat >/dev/null
    return 0
}
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: key curl failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: key curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install NVIDIA container toolkit apt key" "_install_nvidia_container_toolkit: key curl failure logs error"
unset -f curl sudo

curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            return 48
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: source curl failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: source curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install NVIDIA container toolkit apt source" "_install_nvidia_container_toolkit: source curl failure logs error"
unset -f command curl sudo

# NVIDIA container toolkit configure failure
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-container-runtime" ]]; then
        return 1
    fi
    builtin command "$@"
}
curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            printf '%s\n' "deb https://nvidia.example/debian stable main"
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        apt-get)
            return 0
            ;;
        nvidia-ctk)
            return 44
            ;;
        systemctl)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: nvidia-ctk failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: nvidia-ctk failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to configure nvidia-container-toolkit runtime" "_install_nvidia_container_toolkit: nvidia-ctk failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"nvidia-container-toolkit installed and configured"*) fail "_install_nvidia_container_toolkit: failed nvidia-ctk does not log success" ;;
    *) pass "_install_nvidia_container_toolkit: failed nvidia-ctk does not log success" ;;
esac
unset -f command curl sudo

# install_nvidia_drivers propagates toolkit failure after finding a driver.
command() {
    case "${1:-}:${2:-}" in
        -v:nvidia-smi) return 0 ;;
        -v:nvidia-container-runtime) return 1 ;;
    esac
    builtin command "$@"
}
nvidia-smi() {
    case "$*" in
        *--query-gpu=driver_version*) printf '%s\n' "580.142" ;;
        *) return 0 ;;
    esac
}
curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            printf '%s\n' "deb https://nvidia.example/debian stable main"
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        apt-get)
            return 0
            ;;
        nvidia-ctk)
            return 49
            ;;
        systemctl)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
GPU_TYPE=nvidia
INSTALL_ERROR_MESSAGES=()
if install_nvidia_drivers; then
    fail "install_nvidia_drivers: toolkit failure returns nonzero"
else
    pass "install_nvidia_drivers: toolkit failure returns nonzero"
fi
assert_eq "none" "$GPU_TYPE" "install_nvidia_drivers: toolkit failure downgrades GPU type"
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to configure nvidia-container-toolkit runtime" "install_nvidia_drivers: toolkit failure logs underlying error"
unset -f command nvidia-smi curl sudo
unset GPU_TYPE

# ---------------------------------------------------------------------------
# NVIDIA driver-management modes: Standard (Debian apt) vs Unlock (.run + patch)
# ---------------------------------------------------------------------------
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# --- nvidia_driver_source: none / debian / foreign ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
assert_eq "none" "$(nvidia_driver_source)" "nvidia_driver_source: no nvidia-smi → none"
unset -f command dpkg-query

command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { return 0; }
dpkg-query() { printf 'install ok installed'; }
assert_eq "debian" "$(nvidia_driver_source)" "nvidia_driver_source: nvidia-driver package present → debian"
if nvidia_driver_healthy; then
    pass "nvidia_driver_healthy: healthy runtime is independent of Debian ownership"
else
    fail "nvidia_driver_healthy: healthy runtime is independent of Debian ownership"
fi
nvidia-smi() { [[ "$*" == *"--query-gpu"* ]] && printf '535.100\n' || return 1; }
assert_eq "debian" "$(nvidia_driver_source)" "nvidia_driver_source: unhealthy Debian driver retains Debian ownership"
if nvidia_driver_healthy; then
    fail "nvidia_driver_healthy: failing nvidia-smi -L is unhealthy"
else
    pass "nvidia_driver_healthy: failing nvidia-smi -L is unhealthy"
fi
unset -f dpkg-query
dpkg-query() { return 1; }
assert_eq "foreign" "$(nvidia_driver_source)" "nvidia_driver_source: non-packaged driver → foreign"
assert_eq "535.100" "$(nvidia_driver_version)" "nvidia_driver_version: returns one normalized version"
nvidia-smi() { printf '535.100\n550.20\n'; }
if nvidia_driver_version >/dev/null; then
    fail "nvidia_driver_version: rejects mixed loaded driver versions"
else
    pass "nvidia_driver_version: rejects mixed loaded driver versions"
fi
unset -f dpkg-query nvidia-smi command

# --- apply_nvidia_patch: normalized multi-GPU version and strict failure status ---
PATCH_TEST_DIR=$(mktemp -d)
nvidia_patch_prepare_repo() { return 0; }
nvidia_patch_export_run_tree() {
    mkdir -p "$PATCH_TEST_DIR/run"
    printf '%s' "$PATCH_TEST_DIR/run"
}
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { printf '550.90\n550.90\n'; }
bash() {
    PATCH_COMPAT_ARG="${3:-}"
    return 0
}
sudo() { return 0; }
SCRIPT_DIR="$PATCH_TEST_DIR/root"
mkdir -p "$SCRIPT_DIR"
rc=0
apply_nvidia_patch || rc=$?
assert_eq "0" "$rc" "apply_nvidia_patch: successful NVENC patch returns success"
assert_eq "550.90" "$PATCH_COMPAT_ARG" "apply_nvidia_patch: duplicate GPU versions normalize before compatibility check"
sudo() { return 1; }
rc=0
apply_nvidia_patch || rc=$?
assert_eq "1" "$rc" "apply_nvidia_patch: failed NVENC patch returns failure"
rm -rf "$PATCH_TEST_DIR"
unset -f nvidia_patch_prepare_repo nvidia_patch_export_run_tree command nvidia-smi bash sudo
unset PATCH_TEST_DIR PATCH_COMPAT_ARG rc

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

# --- ensure_debian_nonfree: per-release component set + idempotent ---
# `printf ... | sudo tee` runs sudo in a pipe subshell, so capture the written
# source line to a temp file (a variable assignment wouldn't reach this shell).
_nf_cap=$(mktemp)
# ensure_debian_nonfree greps the system sources file directly (apt-cache is
# circular — our own stale managed file would make a component look "visible").
# Point it at a temp file via the test-only seam so per-case "already present"
# state is deterministic instead of depending on the host's real sources.list.
_nf_src=$(mktemp)
export MEDIASTACK_APT_SOURCES="$_nf_src"
sudo() {
    if [[ "${1:-}" == "tee" ]]; then cat >"$_nf_cap"; else cat >/dev/null 2>&1 || true; fi
    return 0
}
: >"$_nf_src" # no components visible → managed file is written
_debian_codename() { printf 'bookworm'; }
_debian_version_id() { printf '12'; }
: >"$_nf_cap"
ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "ensure_debian_nonfree: Debian 12 includes contrib"
assert_contains "$_nf_line" "non-free-firmware" "ensure_debian_nonfree: Debian 12 includes non-free-firmware"
_debian_codename() { printf 'bullseye'; }
_debian_version_id() { printf '11'; }
: >"$_nf_cap"
ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "ensure_debian_nonfree: Debian 11 includes contrib"
case "$_nf_line" in
    *non-free-firmware*) fail "ensure_debian_nonfree: Debian 11 must NOT use non-free-firmware" ;;
    *non-free*) pass "ensure_debian_nonfree: Debian 11 uses non-free without non-free-firmware" ;;
    *) fail "ensure_debian_nonfree: Debian 11 missing non-free component" ;;
esac
_debian_codename() { printf 'trixie'; }
_debian_version_id() { printf '13'; }
: >"$_nf_cap"
ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "non-free-firmware" "ensure_debian_nonfree: Debian 13 includes non-free-firmware"
# Partial setup: non-free visible but contrib/non-free-firmware missing → still writes.
printf 'deb http://deb.debian.org/debian trixie main non-free\n' >"$_nf_src"
: >"$_nf_cap"
ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "ensure_debian_nonfree: partial setup (non-free only) still enables contrib"
assert_contains "$_nf_line" "non-free-firmware" "ensure_debian_nonfree: partial setup still enables non-free-firmware"
# Idempotent: when ALL required components are already visible, do not rewrite.
printf 'deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\n' >"$_nf_src"
: >"$_nf_cap"
ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_eq "" "$_nf_line" "ensure_debian_nonfree: idempotent — skips when all components visible"
rm -f "$_nf_cap" "$_nf_src"
unset MEDIASTACK_APT_SOURCES
unset -f sudo _debian_codename _debian_version_id
unset _nf_cap _nf_src _nf_line

# --- ensure_debian_backports: managed source, idempotent, codename-aware ---
_bp_cap=$(mktemp)
sudo() {
    if [[ "${1:-}" == "tee" ]]; then cat >"$_bp_cap"; else cat >/dev/null 2>&1 || true; fi
    return 0
}
_debian_codename() { printf 'bookworm'; }
_debian_version_id() { printf '12'; }
apt-cache() { return 0; } # backports not visible → written
: >"$_bp_cap"
ensure_debian_backports
_bp_line=$(cat "$_bp_cap")
assert_contains "$_bp_line" "bookworm-backports" "ensure_debian_backports: writes a <codename>-backports source"
assert_contains "$_bp_line" "non-free-firmware" "ensure_debian_backports: Debian 12 backports includes non-free-firmware"
# Idempotent: skip when backports is already visible to apt.
apt-cache() { printf ' 100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages\n'; }
: >"$_bp_cap"
ensure_debian_backports
_bp_line=$(cat "$_bp_cap")
assert_eq "" "$_bp_line" "ensure_debian_backports: idempotent — skips when backports already visible"
rm -f "$_bp_cap"
unset -f apt-cache sudo _debian_codename _debian_version_id
unset _bp_cap _bp_line

# --- Mode chooser default is Standard (patch never default) non-interactively ---
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
UI_DEMO=1
mode_default=$(_stage3_choose_nvidia_mode 2>/dev/null)
assert_eq "standard" "$mode_default" "_stage3_choose_nvidia_mode: non-interactive default is Standard, never Unlock"
unset UI_DEMO mode_default

# --- write_env driver-mode migration (_nvidia_resolve_driver_mode) ---
assert_eq "unlock" "$(_nvidia_resolve_driver_mode "" "true")" "_nvidia_resolve_driver_mode: legacy NVIDIA_PATCH_ENABLED=true → unlock"
assert_eq "standard" "$(_nvidia_resolve_driver_mode "standard" "")" "_nvidia_resolve_driver_mode: explicit standard preserved"
assert_eq "unlock" "$(_nvidia_resolve_driver_mode "unlock" "")" "_nvidia_resolve_driver_mode: explicit unlock preserved"
assert_eq "existing" "$(_nvidia_resolve_driver_mode "existing" "")" "_nvidia_resolve_driver_mode: existing preserved"
assert_eq "" "$(_nvidia_resolve_driver_mode "" "")" "_nvidia_resolve_driver_mode: fresh install → empty (wizard sets standard on install)"
assert_eq "" "$(_nvidia_resolve_driver_mode "bogus" "")" "_nvidia_resolve_driver_mode: invalid value rejected"

# --- nvidia-repatch.sh: only patches in Unlock mode ---
# Black-box run in a temp tree with a fake (always-failing) nvidia-smi so the
# --force path can never touch a real host driver.
_rp=$(mktemp -d)
mkdir -p "$_rp/scripts/lib" "$_rp/bin"
cp "$REPO_ROOT/scripts/nvidia-repatch.sh" "$_rp/scripts/"
cp "$REPO_ROOT/scripts/lib/nvidia_patch.sh" "$_rp/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 1\n' >"$_rp/bin/nvidia-smi"
chmod +x "$_rp/bin/nvidia-smi"
printf 'NVIDIA_DRIVER_MODE=standard\n' >"$_rp/.env"
_rp_out=$(PATH="$_rp/bin:$PATH" bash "$_rp/scripts/nvidia-repatch.sh" 2>&1)
_rp_rc=$?
assert_eq "0" "$_rp_rc" "nvidia-repatch.sh: Standard mode exits 0 (no-op)"
assert_contains "$_rp_out" "nothing to repatch" "nvidia-repatch.sh: Standard mode reports nothing to repatch"
_rp_out2=$(PATH="$_rp/bin:$PATH" bash "$_rp/scripts/nvidia-repatch.sh" --force 2>&1) || true
case "$_rp_out2" in
    *"nothing to repatch"*) fail "nvidia-repatch.sh: --force must bypass the mode guard" ;;
    *) pass "nvidia-repatch.sh: --force bypasses the mode guard" ;;
esac
rm -rf "$_rp"
unset _rp _rp_out _rp_out2 _rp_rc

unset -f sudo
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

echo -e "${CYAN}◀ gpu-branching done${NC}"
summary

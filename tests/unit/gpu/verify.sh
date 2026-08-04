# Owns: GPU usability and render-device verification assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/verify.sh.
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

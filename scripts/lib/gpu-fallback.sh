#!/usr/bin/env bash
# Owns: gpu_fallback_* — why Jellyfin is on software transcoding, as recorded in
# STAGE_3_GPU_FALLBACK_REASON, plus the Secure Boot remedy text and its health line.
# Sources: nothing. Callers: hardware status view, health checks, NVIDIA installers.
#
# Reason codes (written by stage3_set_gpu_env for state fallback|skipped):
#   no_gpu                no supported GPU was detected
#   user_choice           the user skipped hardware transcoding
#   secure_boot           Secure Boot blocks the NVIDIA kernel module
#   driver_install_failed the GPU driver or runtime could not be installed
#   driver_too_old        the newest driver this GPU can use is older than Jellyfin's NVENC minimum
#   verify_failed         the driver installed but a test transcode did not verify
#   finalize_failed       NVIDIA setup did not finish after the reboot

[[ -n "${_MS_GPU_FALLBACK_SH:-}" ]] && return 0
_MS_GPU_FALLBACK_SH=1

GPU_RETRY_PATH="./mediastack -> Manage hardware transcoding (GPU) -> Configure or change hardware transcoding"

gpu_fallback_reason_text() {
    case "${1:-}" in
        no_gpu) echo "no supported GPU was detected" ;;
        user_choice) echo "hardware transcoding was skipped by choice" ;;
        secure_boot) echo "Secure Boot blocks the NVIDIA driver" ;;
        driver_install_failed) echo "the GPU driver could not be installed" ;;
        driver_too_old) echo "the newest NVIDIA driver for this GPU is too old for Jellyfin's NVENC" ;;
        verify_failed) echo "the GPU did not pass the transcode test" ;;
        finalize_failed) echo "NVIDIA setup did not finish after the reboot" ;;
        *) return 1 ;;
    esac
}

# Prints why an NVIDIA GPU cannot use Jellyfin's NVENC, one line per row, for
# log_error callers. $1 GPU name, $2 newest driver branch the GPU supports (e.g.
# 470; empty when unknown), $3 newest driver considered, $4 Jellyfin's minimum.
gpu_fallback_driver_too_old_lines() {
    local gpu="${1:-NVIDIA GPU}" max_branch="${2:-}" best="${3:-}" min="${4:-}"
    echo "Hardware transcoding is not possible on ${gpu}: Jellyfin's NVENC needs NVIDIA driver ${min} or newer."
    if [[ -n "$max_branch" ]]; then
        echo "${gpu} is supported only up to the ${max_branch}.xx driver branch, which is older than ${min}."
    else
        echo "The newest driver considered for ${gpu} is ${best:-unknown}, which is older than ${min}."
    fi
    echo "Jellyfin will use software transcoding."
}

# Why step 2 creates the key by hand: Debian's dkms package (checked in
# 3.0.10-8+deb12u1 and 3.2.2-1~deb13u1, /usr/sbin/dkms) has no postinst that makes
# it. dkms generates /var/lib/dkms/mok.key and mok.pub only on the first module
# build, with the exact openssl command above, and reuses the files when present.
# MediaStack installs nothing before this check, so the user must do steps 1-2.
# Prints the Secure Boot remedy, one line per row, for log_error/ui_kv callers.
# $1 is the DKMS key state from nvidia_driver_mok_state; the key exists in the
# not_enrolled and pending states, so only the remaining steps are shown.
gpu_fallback_secure_boot_lines() {
    case "${1:-}" in
        pending)
            echo "A Machine Owner Key import is queued but not enrolled yet. Then retry from ${GPU_RETRY_PATH}:"
            echo "  1. sudo reboot; in the blue MOK screen pick Enroll MOK, Continue, enter the one-time password"
            echo "  2. Retry from the menu path above; setup signs the NVIDIA module with that key."
            return
            ;;
        not_enrolled)
            echo "The DKMS signing key exists but is not enrolled. Then retry from ${GPU_RETRY_PATH}:"
            echo "  1. sudo mokutil --import /var/lib/dkms/mok.pub   (set a one-time password)"
            echo "  2. sudo reboot; in the blue MOK screen pick Enroll MOK, Continue, enter the password"
            echo "  3. Retry from the menu path above; setup signs the NVIDIA module with that key."
            return
            ;;
    esac
    echo "Fix one of the following, then retry from ${GPU_RETRY_PATH}:"
    echo "  (a) Disable Secure Boot in the UEFI firmware (or your cloud console), OR"
    echo "  (b) Enrol a Machine Owner Key (MOK) so the signed nvidia module loads:"
    echo "        1. sudo apt-get -y install dkms mokutil openssl"
    echo "        2. sudo mkdir -p /var/lib/dkms && sudo openssl req -new -x509 -nodes -days 36500 -subj \"/CN=DKMS module signing key\" -newkey rsa:2048 -keyout /var/lib/dkms/mok.key -addext \"extendedKeyUsage=codeSigning\" -outform DER -out /var/lib/dkms/mok.pub"
    echo "        3. sudo mokutil --import /var/lib/dkms/mok.pub   (set a one-time password)"
    echo "        4. sudo reboot; in the blue MOK screen pick Enroll MOK, Continue, enter the password"
    echo "        5. Retry from the menu path above; setup signs the NVIDIA module with that key."
}

# One-line remedy for the status view and the health check; empty when none.
gpu_fallback_remedy() {
    case "${1:-}" in
        secure_boot) echo "disable Secure Boot in firmware or your cloud console, or enrol a Machine Owner Key (MOK) and reboot; then retry from ${GPU_RETRY_PATH}" ;;
        driver_too_old) echo "this GPU's newest driver cannot run Jellyfin's NVENC; use a newer NVIDIA GPU for hardware transcoding" ;;
        driver_install_failed | verify_failed | finalize_failed) echo "fix the driver issue, then retry from ${GPU_RETRY_PATH}" ;;
    esac
}

# True when the NVIDIA driver answers. nvidia-smi prints its failure text on
# stdout, so only a zero exit with a version means the driver is loaded. The
# version is printed on stdout.
gpu_fallback_nvidia_driver_version() {
    local drv
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || return 1
    drv=$(head -1 <<<"$drv")
    [[ -n "$drv" ]] || return 1
    printf '%s' "$drv"
}

# True when the stack is set up for NVIDIA (configured or recorded complete).
gpu_fallback_nvidia_configured() {
    [[ "${JELLYFIN_GPU:-}" == "nvidia" ]] \
        || [[ "${STAGE_3_GPU_STATE:-}" == "complete" && "${STAGE_3_GPU_VENDOR:-}" == "nvidia" ]]
}

# Health line: a recorded fallback reason, or a configured NVIDIA driver that is
# not loaded. ok when the GPU is active or none was recorded.
gpu_fallback_health() {
    local reason="${STAGE_3_GPU_FALLBACK_REASON:-}" text remedy
    if gpu_fallback_nvidia_configured && ! gpu_fallback_nvidia_driver_version >/dev/null; then
        echo "warn|NVIDIA driver not loaded — repair from Manage hardware transcoding"
        return 0
    fi
    if [[ "${STAGE_3_GPU_STATE:-}" != "fallback" && "${STAGE_3_GPU_STATE:-}" != "skipped" ]] || [[ -z "$reason" ]]; then
        echo "skip|Hardware transcoding: no software fallback recorded"
        return 0
    fi
    text=$(gpu_fallback_reason_text "$reason") || text="$reason"
    remedy=$(gpu_fallback_remedy "$reason")
    case "$reason" in
        no_gpu | user_choice) echo "ok|Software transcoding: ${text}" ;;
        *) echo "warn|Software transcoding: ${text}${remedy:+ - ${remedy}}" ;;
    esac
}

#!/usr/bin/env bash
# tests/unit/stage3-nvidia-finalize.sh
#
# Contract tests for NVIDIA driver-mode conversion and post-reboot finalize.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-nvidia-finalize"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/deferred-nvidia-reboot"
mkdir -p "$SCRIPT_DIR"
GPU_TYPE=nvidia
NEEDS_REBOOT=false
prompt_calls=0
summary_calls=0
gpu_env_calls=()
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_mode() { printf 'unlock'; }
nvidia_driver_source() { printf 'none'; }
install_nvidia_drivers() {
    # shellcheck disable=SC2034 # read across stage3.sh dispatch (production global set by gpu.sh/stage3 install flows)
    NEEDS_REBOOT=true
    return 0
}
stage3_set_gpu_env() {
    gpu_env_calls+=("$1:$2:$3:$4")
    return 0
}
stage3_prompt_nvidia_reboot() { prompt_calls=$((prompt_calls + 1)); }
print_final_summary() { summary_calls=$((summary_calls + 1)); }
run_hardware_transcoding_addon
assert_eq "0" "$prompt_calls" "wizard hardware add-on defers NVIDIA reboot prompt"
assert_eq "0" "$summary_calls" "wizard hardware add-on suppresses interim final summary"
assert_contains "${gpu_env_calls[*]}" "none:pending:nvidia:nvenc" "deferred NVIDIA path records pending transcoding state"
stage3_prompt_pending_nvidia_reboot
assert_eq "1" "$prompt_calls" "final reboot gate prompts for deferred NVIDIA reboot"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source install_nvidia_drivers stage3_set_gpu_env stage3_prompt_nvidia_reboot print_final_summary
unset GPU_TYPE NEEDS_REBOOT prompt_calls summary_calls gpu_env_calls

prev_script_dir="${SCRIPT_DIR:-}"
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-install-fail"
mkdir -p "$SCRIPT_DIR/.nvidia-tmp"
touch "$SCRIPT_DIR/.nvidia-tmp/pending"
finalize_failure_calls=0
ui_log() { :; }
install_nvidia_drivers() { return 1; }
_stage3_nvidia_finalize_failure() {
    finalize_failure_calls=$((finalize_failure_calls + 1))
    GPU_TYPE=none
    return 0
}
stage3_finalize_nvidia
assert_eq "1" "$finalize_failure_calls" "NVIDIA finalize installer failure uses finalization failure path"
assert_eq "none" "$GPU_TYPE" "NVIDIA finalize installer failure downgrades GPU type"
unset -f ui_log install_nvidia_drivers _stage3_nvidia_finalize_failure
SCRIPT_DIR="$prev_script_dir"
unset finalize_failure_calls GPU_TYPE prev_script_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

# Post-reboot NVIDIA finalize: driver verifies + patch applies but the final
# test-transcode proof comes back inconclusive. A verified driver must NOT drop
# to CPU software just because proof-gathering raced the Jellyfin restart.
prev_script_dir="${SCRIPT_DIR:-}"
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-proof-inconclusive"
mkdir -p "$SCRIPT_DIR"
finalize_failure_calls=0
gpu_env_calls=()
# shellcheck disable=SC2034 # read by _stage3_run_nvidia in scripts/setup/stage3/nvidia-flow.sh
NVIDIA_DRIVER_MODE=unlock
ui_log() { :; }
nvidia-smi() { return 0; }
sudo() { return 0; }
docker() { return 0; }
stage3_marker_driver_mode() { printf 'unlock'; }
stage3_marker_install_source() { printf ''; }
stage3_marker_expected_driver_version() { printf ''; }
apply_nvidia_patch() { return 0; }
verify_gpu_usable() {
    GPU_TYPE=nvidia
    return 0
}
_stage3_apply_runtime_override() { return 0; }
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_wait_for_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
stage3_set_gpu_env() {
    gpu_env_calls+=("$1:$2:$3:$4")
    return 0
}
stage3_remove_nvidia_marker() { :; }
_stage3_print_final_summary() { :; }
_stage3_nvidia_finalize_failure() {
    finalize_failure_calls=$((finalize_failure_calls + 1))
    return 0
}
stage3_finalize_nvidia
assert_eq "0" "$finalize_failure_calls" "inconclusive test transcode does not fall back to software"
assert_contains "${gpu_env_calls[*]}" "nvidia:complete:nvidia:nvenc" "inconclusive test transcode still records NVENC complete"
unset -f ui_log nvidia-smi sudo docker stage3_marker_driver_mode stage3_marker_install_source stage3_marker_expected_driver_version apply_nvidia_patch verify_gpu_usable _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_wait_for_jellyfin_encoding stage3_verify_transcode_evidence stage3_set_gpu_env stage3_remove_nvidia_marker _stage3_print_final_summary _stage3_nvidia_finalize_failure
SCRIPT_DIR="$prev_script_dir"
unset finalize_failure_calls gpu_env_calls NVIDIA_DRIVER_MODE GPU_TYPE prev_script_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

# Post-reboot driver-settle wait: the nvidia module can lag a few seconds behind
# the resume service, so a not-yet-ready driver must be retried (bounded) rather
# than read as a failure.
smi_attempts=0
sleep() { :; }
nvidia-smi() {
    smi_attempts=$((smi_attempts + 1))
    ((smi_attempts >= 3)) && return 0
    return 1
}
STAGE3_NVIDIA_SMI_TIMEOUT=20
if _stage3_wait_for_nvidia_smi; then
    pass "driver-settle wait returns success once nvidia-smi comes up"
else
    fail "driver-settle wait returns success once nvidia-smi comes up"
fi
assert_eq "3" "$smi_attempts" "driver-settle wait retries nvidia-smi until it responds"
nvidia-smi() { return 1; }
# shellcheck disable=SC2034 # read by _stage3_wait_for_nvidia_smi in scripts/setup/stage3/nvidia-finalize.sh
STAGE3_NVIDIA_SMI_TIMEOUT=4
if _stage3_wait_for_nvidia_smi; then
    fail "driver-settle wait gives up when nvidia-smi never responds"
else
    pass "driver-settle wait gives up when nvidia-smi never responds"
fi
unset -f sleep nvidia-smi
unset smi_attempts STAGE3_NVIDIA_SMI_TIMEOUT

scenario_end "$CURRENT_SCENARIO"
summary

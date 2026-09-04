#!/usr/bin/env bash
# tests/unit/stage-state-persistence.sh
#
# Regression tests for Stage 2/3 state transitions when .env persistence fails.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage-state-persistence"
scenario_begin "$CURRENT_SCENARIO"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Stage 2 helper: a failed writer is surfaced and does not update the shell.
source "$REPO_ROOT/scripts/setup/stages/stage2.sh"
SCRIPT_DIR="$TMP_ROOT/stage2-helper"
mkdir -p "$SCRIPT_DIR"
printf 'REMOTE_WEB_STATE=skipped\n' >"$SCRIPT_DIR/.env"
REMOTE_WEB_STATE=skipped
stage2_warn_calls=0
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() {
    stage2_warn_calls=$((stage2_warn_calls + 1))
}
if _stage2_set_remote_state ready; then
    fail "Stage 2 state helper rejects persistence failure"
else
    pass "Stage 2 state helper rejects persistence failure"
fi
assert_eq "skipped" "$REMOTE_WEB_STATE" "Stage 2 failed write does not export requested state"
assert_eq "1" "$stage2_warn_calls" "Stage 2 failed write emits persistence warning"

# Stage 2 ready gate: persistence must succeed before re-source/configure or
# the user-facing ready result. The configure script is an observable seam.
SCRIPT_DIR="$TMP_ROOT/stage2-ready"
mkdir -p "$SCRIPT_DIR/scripts"
printf 'REMOTE_WEB_STATE=skipped\n' >"$SCRIPT_DIR/.env"
printf '#!/usr/bin/env bash\nprintf configured >"%s"\n' "$TMP_ROOT/stage2-ready/configured" >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
stage2_source_calls=0
stage2_ready_warn_calls=0
stage2_ready_log="$TMP_ROOT/stage2-ready/log"
: >"$stage2_ready_log"
stage2_le_classify() {
    # shellcheck disable=SC2034 # consumed by stage2_le_gate as the classifier result
    STAGE2_LE_CLASSIFICATION=ready
    return 0
}
_stage2_source_env() {
    stage2_source_calls=$((stage2_source_calls + 1))
}
_env_write_kv_warn() {
    stage2_ready_warn_calls=$((stage2_ready_warn_calls + 1))
}
log_ok() { printf '%s\n' "$*" >>"$stage2_ready_log"; }
if stage2_le_gate gate.test; then
    fail "Stage 2 ready gate rejects persistence failure"
else
    pass "Stage 2 ready gate rejects persistence failure"
fi
assert_eq "0" "$stage2_source_calls" "Stage 2 ready gate does not reload after failed write"
assert_file_absent "$TMP_ROOT/stage2-ready/configured" "Stage 2 ready gate does not configure after failed write"
assert_file_not_contains "$stage2_ready_log" "Remote access is ready" "Stage 2 ready gate does not announce success after failed write"
assert_eq "1" "$stage2_ready_warn_calls" "Stage 2 ready gate reports persistence failure"

unset -f _env_write_kv _env_write_kv_warn stage2_le_classify _stage2_source_env log_ok
unset stage2_warn_calls stage2_source_calls stage2_ready_warn_calls stage2_ready_log

# Stage 3 helper: a failed multi-key writer is surfaced before any requested
# GPU state is exported.
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/stage3-helper"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=skipped\n' >"$SCRIPT_DIR/.env"
JELLYFIN_GPU=none
STAGE_3_GPU_STATE=skipped
STAGE_3_GPU_VENDOR=old-vendor
STAGE_3_GPU_ENCODER=old-encoder
stage3_warn_calls=0
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() {
    stage3_warn_calls=$((stage3_warn_calls + 1))
}
if stage3_set_gpu_env nvidia pending nvidia nvenc; then
    fail "Stage 3 state helper rejects persistence failure"
else
    pass "Stage 3 state helper rejects persistence failure"
fi
assert_eq "none" "$JELLYFIN_GPU" "Stage 3 failed write does not export requested GPU"
assert_eq "skipped" "$STAGE_3_GPU_STATE" "Stage 3 failed write does not export requested state"
assert_eq "old-vendor" "$STAGE_3_GPU_VENDOR" "Stage 3 failed write does not export requested vendor"
assert_eq "old-encoder" "$STAGE_3_GPU_ENCODER" "Stage 3 failed write does not export requested encoder"
assert_eq "1" "$stage3_warn_calls" "Stage 3 failed write emits persistence warning"

unset -f _env_write_kv _env_write_kv_warn
unset stage3_warn_calls JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_VENDOR STAGE_3_GPU_ENCODER

# NVIDIA finalization: a failure writing the critical complete state must keep
# the recovery marker and suppress the completion result.
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
stage3_write_nvidia_marker unlock run >/dev/null
nvidia_finalize_log="$TMP_ROOT/nvidia-finalize/log"
: >"$nvidia_finalize_log"
ui_log() { printf '%s\n' "$*" >>"$nvidia_finalize_log"; }
nvidia-smi() { return 0; }
sudo() { return 0; }
docker() { return 0; }
apply_nvidia_patch() { return 0; }
verify_gpu_usable() {
    GPU_TYPE=nvidia
    return 0
}
_stage3_apply_runtime_override() { return 0; }
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_wait_for_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 0; }
_stage3_print_final_summary() { :; }
_env_write_kv_warn() { :; }
_env_write_kv() {
    local args="$*"
    if [[ "$args" == *"STAGE_3_GPU_STATE complete"* ]]; then
        printf 'write-error:simulated\n'
        return 6
    fi
    printf 'changed\n'
    return 0
}
if stage3_finalize_nvidia; then
    fail "NVIDIA finalization rejects complete-state persistence failure"
else
    pass "NVIDIA finalization rejects complete-state persistence failure"
fi
if stage3_marker_exists; then
    pass "NVIDIA finalization retains marker after complete-state persistence failure"
else
    fail "NVIDIA finalization retains marker after complete-state persistence failure"
fi
assert_file_not_contains "$nvidia_finalize_log" "Post-reboot GPU finalization complete." "NVIDIA finalization does not announce completion after failed write"

# Top-level Stage 3 skip: persistence must succeed before software fallback
# work removes a recovery marker or prints a final summary.
SCRIPT_DIR="$TMP_ROOT/stage3-no-gpu"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=intel\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
GPU_TYPE=none
stage3_skip_calls=0
stage3_summary_calls=0
_stage3_skip_to_software_mode() { stage3_skip_calls=$((stage3_skip_calls + 1)); }
_stage3_print_final_summary() { stage3_summary_calls=$((stage3_summary_calls + 1)); }
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() { :; }
ui_log() { :; }
if run_stage3; then
    fail "Stage 3 no-GPU path rejects skipped-state persistence failure"
else
    pass "Stage 3 no-GPU path rejects skipped-state persistence failure"
fi
assert_eq "0" "$stage3_skip_calls" "Stage 3 no-GPU path does not enter software mode after failed write"
assert_eq "0" "$stage3_summary_calls" "Stage 3 no-GPU path does not print summary after failed write"
if stage3_marker_exists; then
    pass "Stage 3 no-GPU path retains marker after skipped-state persistence failure"
else
    fail "Stage 3 no-GPU path retains marker after skipped-state persistence failure"
fi

# Generic fallback: durable fallback state is written before marker removal or
# runtime/Jellyfin mutation.
SCRIPT_DIR="$TMP_ROOT/stage3-fallback"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=intel\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
GPU_TYPE=intel
stage3_runtime_calls=0
_stage3_configure_jellyfin() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
_stage3_apply_runtime_override() {
    if [[ -f "$skip_selected_file" ]]; then
        stage3_runtime_calls=$((stage3_runtime_calls + 1))
    fi
}
if _stage3_fallback intel qsv; then
    fail "Stage 3 fallback rejects fallback-state persistence failure"
else
    pass "Stage 3 fallback rejects fallback-state persistence failure"
fi
assert_eq "intel" "$GPU_TYPE" "Stage 3 failed fallback write preserves detected GPU type"
assert_eq "0" "$stage3_runtime_calls" "Stage 3 failed fallback write does not mutate runtime"
if stage3_marker_exists; then
    pass "Stage 3 fallback retains marker after fallback-state persistence failure"
else
    fail "Stage 3 fallback retains marker after fallback-state persistence failure"
fi

# NVIDIA finalization failure has the same ordering requirement: do not apply
# software fallback or remove the marker when fallback state cannot be saved.
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-failure"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=nvidia\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
GPU_TYPE=nvidia
stage3_runtime_calls=0
_stage3_apply_runtime_override() { stage3_runtime_calls=$((stage3_runtime_calls + 1)); }
if _stage3_nvidia_finalize_failure; then
    fail "NVIDIA finalization fallback rejects fallback-state persistence failure"
else
    pass "NVIDIA finalization fallback rejects fallback-state persistence failure"
fi
assert_eq "nvidia" "$GPU_TYPE" "NVIDIA failed fallback write preserves GPU type"
assert_eq "0" "$stage3_runtime_calls" "NVIDIA failed fallback write does not mutate runtime"
if stage3_marker_exists; then
    pass "NVIDIA failed fallback write retains marker"
else
    fail "NVIDIA failed fallback write retains marker"
fi

# Interactive verification skip: skipped state must be durable before the
# explicit user choice removes a marker or changes runtime.
SCRIPT_DIR="$TMP_ROOT/stage3-interactive-skip"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=nvidia\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
GPU_TYPE=nvidia
stage3_runtime_calls=0
skip_selected_file="$TMP_ROOT/interactive-skip-selected"
ui_choose() {
    : >"$skip_selected_file"
    printf '%s\n' "Skip for now"
}
_env_write_kv() {
    local args="$*"
    if [[ "$args" == *"STAGE_3_GPU_STATE skipped"* ]]; then
        printf 'write-error:simulated\n'
        return 6
    fi
    printf 'changed\n'
    return 0
}
_stage3_apply_runtime_override() {
    if [[ -f "$skip_selected_file" ]]; then
        stage3_runtime_calls=$((stage3_runtime_calls + 1))
    fi
}
_stage3_configure_jellyfin() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
if _stage3_configure_and_verify nvidia nvenc "NVIDIA NVENC configured and verified."; then
    fail "Stage 3 interactive skip rejects skipped-state persistence failure"
else
    pass "Stage 3 interactive skip rejects skipped-state persistence failure"
fi
assert_eq "0" "$stage3_runtime_calls" "Stage 3 interactive skip does not mutate runtime after failed write"
if stage3_marker_exists; then
    pass "Stage 3 interactive skip retains marker after skipped-state persistence failure"
else
    fail "Stage 3 interactive skip retains marker after skipped-state persistence failure"
fi

scenario_end "$CURRENT_SCENARIO"
summary

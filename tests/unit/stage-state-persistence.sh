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
STAGE2_WARN_CALLS=0
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() {
    STAGE2_WARN_CALLS=$((STAGE2_WARN_CALLS + 1))
}
if _stage2_set_remote_state ready; then
    fail "Stage 2 state helper rejects persistence failure"
else
    pass "Stage 2 state helper rejects persistence failure"
fi
assert_eq "skipped" "$REMOTE_WEB_STATE" "Stage 2 failed write does not export requested state"
assert_eq "1" "$STAGE2_WARN_CALLS" "Stage 2 failed write emits persistence warning"

# Stage 2 ready gate: persistence must succeed before re-source/configure or
# the user-facing ready result. The configure script is an observable seam.
SCRIPT_DIR="$TMP_ROOT/stage2-ready"
mkdir -p "$SCRIPT_DIR/scripts"
printf 'REMOTE_WEB_STATE=skipped\n' >"$SCRIPT_DIR/.env"
printf '#!/usr/bin/env bash\nprintf configured >"%s"\n' "$TMP_ROOT/stage2-ready/configured" >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
STAGE2_SOURCE_CALLS=0
STAGE2_READY_WARN_CALLS=0
STAGE2_READY_LOG="$TMP_ROOT/stage2-ready/log"
: >"$STAGE2_READY_LOG"
stage2_le_classify() {
    # shellcheck disable=SC2034 # consumed by stage2_le_gate as the classifier result
    STAGE2_LE_CLASSIFICATION=ready
    return 0
}
_stage2_source_env() {
    STAGE2_SOURCE_CALLS=$((STAGE2_SOURCE_CALLS + 1))
}
_env_write_kv_warn() {
    STAGE2_READY_WARN_CALLS=$((STAGE2_READY_WARN_CALLS + 1))
}
log_ok() { printf '%s\n' "$*" >>"$STAGE2_READY_LOG"; }
if stage2_le_gate gate.test; then
    fail "Stage 2 ready gate rejects persistence failure"
else
    pass "Stage 2 ready gate rejects persistence failure"
fi
assert_eq "0" "$STAGE2_SOURCE_CALLS" "Stage 2 ready gate does not reload after failed write"
assert_file_absent "$TMP_ROOT/stage2-ready/configured" "Stage 2 ready gate does not configure after failed write"
assert_file_not_contains "$STAGE2_READY_LOG" "Remote access is ready" "Stage 2 ready gate does not announce success after failed write"
assert_eq "1" "$STAGE2_READY_WARN_CALLS" "Stage 2 ready gate reports persistence failure"

unset -f _env_write_kv _env_write_kv_warn stage2_le_classify _stage2_source_env log_ok
unset STAGE2_WARN_CALLS STAGE2_SOURCE_CALLS STAGE2_READY_WARN_CALLS STAGE2_READY_LOG

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
STAGE3_WARN_CALLS=0
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() {
    STAGE3_WARN_CALLS=$((STAGE3_WARN_CALLS + 1))
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
assert_eq "1" "$STAGE3_WARN_CALLS" "Stage 3 failed write emits persistence warning"

unset -f _env_write_kv _env_write_kv_warn
unset STAGE3_WARN_CALLS JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_VENDOR STAGE_3_GPU_ENCODER

# NVIDIA finalization: a failure writing the critical complete state must keep
# the recovery marker and suppress the completion result.
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
stage3_write_nvidia_marker unlock run >/dev/null
NVIDIA_FINALIZE_LOG="$TMP_ROOT/nvidia-finalize/log"
: >"$NVIDIA_FINALIZE_LOG"
ui_log() { printf '%s\n' "$*" >>"$NVIDIA_FINALIZE_LOG"; }
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
assert_file_not_contains "$NVIDIA_FINALIZE_LOG" "Post-reboot GPU finalization complete." "NVIDIA finalization does not announce completion after failed write"

# Top-level Stage 3 skip: persistence must succeed before software fallback
# work removes a recovery marker or prints a final summary.
SCRIPT_DIR="$TMP_ROOT/stage3-no-gpu"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=intel\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
GPU_TYPE=none
STAGE3_SKIP_CALLS=0
STAGE3_SUMMARY_CALLS=0
_stage3_skip_to_software_mode() { STAGE3_SKIP_CALLS=$((STAGE3_SKIP_CALLS + 1)); }
_stage3_print_final_summary() { STAGE3_SUMMARY_CALLS=$((STAGE3_SUMMARY_CALLS + 1)); }
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() { :; }
ui_log() { :; }
NO_GPU_RC=0
run_stage3 || NO_GPU_RC=$?
assert_eq "3" "$NO_GPU_RC" "Stage 3 no-GPU path rejects skipped-state persistence failure"
assert_eq "0" "$STAGE3_SKIP_CALLS" "Stage 3 no-GPU path does not enter software mode after failed write"
assert_eq "0" "$STAGE3_SUMMARY_CALLS" "Stage 3 no-GPU path does not print summary after failed write"
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
STAGE3_RUNTIME_CALLS=0
_stage3_configure_jellyfin() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
_stage3_apply_runtime_override() {
    STAGE3_RUNTIME_CALLS=$((STAGE3_RUNTIME_CALLS + 1))
}
FALLBACK_RC=0
_stage3_fallback intel qsv || FALLBACK_RC=$?
assert_eq "3" "$FALLBACK_RC" "Stage 3 fallback rejects fallback-state persistence failure"
assert_eq "intel" "$GPU_TYPE" "Stage 3 failed fallback write preserves detected GPU type"
assert_eq "0" "$STAGE3_RUNTIME_CALLS" "Stage 3 failed fallback write does not mutate runtime"
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
STAGE3_RUNTIME_CALLS=0
_stage3_apply_runtime_override() { STAGE3_RUNTIME_CALLS=$((STAGE3_RUNTIME_CALLS + 1)); }
NVIDIA_FALLBACK_RC=0
_stage3_nvidia_finalize_failure || NVIDIA_FALLBACK_RC=$?
assert_eq "3" "$NVIDIA_FALLBACK_RC" "NVIDIA finalization fallback rejects fallback-state persistence failure"
assert_eq "0" "$STAGE3_RUNTIME_CALLS" "NVIDIA failed fallback write does not mutate runtime"
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
STAGE3_RUNTIME_CALLS=0
SKIP_SELECTED_FILE="$TMP_ROOT/interactive-skip-selected"
ui_choose() {
    : >"$SKIP_SELECTED_FILE"
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
    if [[ -f "$SKIP_SELECTED_FILE" ]]; then
        STAGE3_RUNTIME_CALLS=$((STAGE3_RUNTIME_CALLS + 1))
    fi
}
_stage3_configure_jellyfin() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
INTERACTIVE_SKIP_RC=0
_stage3_configure_and_verify nvidia nvenc "NVIDIA NVENC configured and verified." || INTERACTIVE_SKIP_RC=$?
assert_eq "3" "$INTERACTIVE_SKIP_RC" "Stage 3 interactive skip rejects skipped-state persistence failure"
assert_eq "0" "$STAGE3_RUNTIME_CALLS" "Stage 3 interactive skip does not mutate runtime after failed write"
if stage3_marker_exists; then
    pass "Stage 3 interactive skip retains marker after skipped-state persistence failure"
else
    fail "Stage 3 interactive skip retains marker after skipped-state persistence failure"
fi

# Normal AMD/NVIDIA entry paths must preserve the distinct persistence-failure
# status instead of treating it like an already-handled hardware fallback.
SCRIPT_DIR="$TMP_ROOT/stage3-amd-caller"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=skipped\n' >"$SCRIPT_DIR/.env"
GPU_TYPE=amd
STAGE3_SKIP_OFFER=true
_stage3_choose_gpu_vendor() { :; }
ui_banner() { :; }
install_amd_drivers() { return 0; }
verify_gpu_usable() { GPU_TYPE=amd; }
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() { :; }
AMD_CALLER_RC=0
run_hardware_transcoding_addon || AMD_CALLER_RC=$?
assert_eq "3" "$AMD_CALLER_RC" "Stage 3 AMD caller propagates durable-state failure"

SCRIPT_DIR="$TMP_ROOT/stage3-nvidia-caller"
mkdir -p "$SCRIPT_DIR"
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=skipped\n' >"$SCRIPT_DIR/.env"
GPU_TYPE=nvidia
_stage3_choose_nvidia_action() { printf 'use\n'; }
nvidia_driver_source() { printf 'debian\n'; }
nvidia_driver_healthy() { return 0; }
_install_nvidia_container_toolkit() { return 0; }
verify_gpu_usable() { GPU_TYPE=nvidia; }
NVIDIA_CALLER_RC=0
run_stage3 || NVIDIA_CALLER_RC=$?
assert_eq "3" "$NVIDIA_CALLER_RC" "Stage 3 NVIDIA caller propagates durable-state failure"

# The wizard must stop after a Stage 3 persistence failure. In particular it
# must not enter Stage 2 or print the final completion summary.
SCRIPT_DIR="$REPO_ROOT"
# shellcheck source=../../scripts/setup/wizard.sh
source "$REPO_ROOT/scripts/setup/wizard.sh"
SCRIPT_DIR="$TMP_ROOT/wizard-caller"
mkdir -p "$SCRIPT_DIR"
seed_root_config() { :; }
_wizard_load_existing_env() { :; }
run_stage1() { :; }
run_hardware_transcoding_addon() { return 3; }
WIZARD_STAGE2_CALLS=0
WIZARD_SUMMARY_CALLS=0
run_stage2() { WIZARD_STAGE2_CALLS=$((WIZARD_STAGE2_CALLS + 1)); }
_stage3_print_final_summary() { WIZARD_SUMMARY_CALLS=$((WIZARD_SUMMARY_CALLS + 1)); }
WIZARD_RC=0
run_wizard || WIZARD_RC=$?
assert_eq "3" "$WIZARD_RC" "Wizard propagates Stage 3 durable-state failure"
assert_eq "0" "$WIZARD_STAGE2_CALLS" "Wizard skips Stage 2 after Stage 3 durable-state failure"
assert_eq "0" "$WIZARD_SUMMARY_CALLS" "Wizard suppresses final summary after Stage 3 durable-state failure"

# A ripe marker with no .env is not a durable-state failure: there is no install
# to finalize into. setup.sh routes here before every other branch while the
# marker is ripe, so keeping it would re-enter this path on every later run and
# lock the user out of setup entirely. The marker must be cleared and the run
# allowed to continue.
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-no-env"
mkdir -p "$SCRIPT_DIR"
touch "$SCRIPT_DIR/.nvidia-finalize-pending"
NO_ENV_WARNS=0
ui_log() {
    [[ "${1:-}" == "warn" ]] && NO_ENV_WARNS=$((NO_ENV_WARNS + 1))
    return 0
}
_stage3_wait_for_nvidia_smi() { return 0; }
NO_ENV_RC=0
stage3_finalize_nvidia || NO_ENV_RC=$?
assert_eq "0" "$NO_ENV_RC" "NVIDIA finalize without .env is not treated as a failure"
if stage3_marker_exists; then
    fail "NVIDIA finalize without .env clears the pending-reboot marker"
else
    pass "NVIDIA finalize without .env clears the pending-reboot marker"
fi
assert_eq "1" "$NO_ENV_WARNS" "NVIDIA finalize without .env explains why it stopped"
ui_log() { :; }

# Stage 2: a failed "failed" write must not replace the certificate diagnosis.
# The classification copy, the status snapshot and the recovery menu are what
# the operator needs — the write failure has already warned on its own.
SCRIPT_DIR="$TMP_ROOT/stage2-failed-state"
mkdir -p "$SCRIPT_DIR/scripts"
printf 'REMOTE_WEB_STATE=ready\n' >"$SCRIPT_DIR/.env"
printf '#!/usr/bin/env bash\nprintf configured >>"%s"\n' "$TMP_ROOT/stage2-failed-state/configured" >"$SCRIPT_DIR/scripts/configure.sh"
chmod +x "$SCRIPT_DIR/scripts/configure.sh"
stage2_le_classify() {
    # shellcheck disable=SC2034 # consumed by stage2_le_gate as the classifier result
    STAGE2_LE_CLASSIFICATION=dns-not-propagated
    return 0
}
stage2_le_failure_copy() { printf 'certificate diagnosis\n'; }
stage2_le_status_path() { printf '%s/status.json\n' "$SCRIPT_DIR"; }
stage2_skip_summary_copy() { printf 'skipped\n'; }
_stage2_source_env() { :; }
_stage2_is_interactive() { return 0; }
_env_write_kv() {
    printf 'write-error:simulated\n'
    return 6
}
_env_write_kv_warn() { :; }
# ui_choose is read through a command substitution, so the menu is recorded in a
# file rather than a variable that the subshell would discard.
STAGE2_MENU_FILE="$TMP_ROOT/stage2-failed-state/menu"
STAGE2_DIAGNOSIS=""
ui_choose() {
    printf 'shown\n' >>"$STAGE2_MENU_FILE"
    printf '%s\n' "Abort setup"
}
log_warn() { STAGE2_DIAGNOSIS="$*"; }
LE_GATE_RC=0
stage2_le_gate example.test || LE_GATE_RC=$?
assert_eq "1" "$LE_GATE_RC" "Stage 2 gate still fails when HTTPS is not ready"
assert_eq "1" "$(wc -l <"$STAGE2_MENU_FILE" 2>/dev/null || echo 0)" \
    "Stage 2 failed-state write still reaches the recovery menu"
assert_contains "$STAGE2_DIAGNOSIS" "certificate diagnosis" \
    "Stage 2 failed-state write still shows the certificate diagnosis"
if [[ -f "$TMP_ROOT/stage2-failed-state/configured" ]]; then
    pass "Stage 2 failed-state write still re-renders the proxy config"
else
    fail "Stage 2 failed-state write still re-renders the proxy config"
fi

scenario_end "$CURRENT_SCENARIO"
summary

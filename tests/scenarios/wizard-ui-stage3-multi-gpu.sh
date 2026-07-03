# tests/scenarios/wizard-ui-stage3-multi-gpu.sh — detected-only vendor selection.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-multi-gpu.sh"
    local steps="/tmp/wizard-stage3-multi-gpu.steps.json"
    local plain_log="/tmp/wizard-stage3-multi-gpu.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'RUNNER'
detect_env
GPU_CANDIDATES=(nvidia amd intel)
GPU_TYPE=nvidia
run_stage3
RUNNER"

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        gpu_vendor 2

    wizard_stage3_run_pty "wizard-ui stage3 multi-GPU" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NVIDIA — NVENC" "wizard-ui stage3 multi-GPU: NVIDIA choice shown"
    assert_contains "$transcript" "AMD — VAAPI" "wizard-ui stage3 multi-GPU: AMD choice shown"
    assert_contains "$transcript" "Intel — Quick Sync" "wizard-ui stage3 multi-GPU: Intel choice shown"
    assert_eq "amd" "$(env_get JELLYFIN_GPU)" "wizard-ui stage3 multi-GPU: selected AMD route completes"
}

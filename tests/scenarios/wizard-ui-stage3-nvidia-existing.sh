# tests/scenarios/wizard-ui-stage3-nvidia-existing.sh — externally managed NVIDIA driver.
#
# Detection reports a healthy driver managed outside MediaStack. The wizard
# offers to use it as-is; the user accepts. Asserts mode=existing is
# recorded and the flow verifies/completes against the existing driver.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-existing.sh"
    local steps="/tmp/wizard-stage3-nvidia-existing.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-existing.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'BASH'
nvidia_driver_source() { printf 'foreign\n'; }
nvidia_driver_healthy() { return 0; }
nvidia_driver_version() { printf '550.90\n'; }
BASH"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        nvidia_managed_outside 1

    wizard_stage3_run_pty "wizard-ui stage3 nvidia existing" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NVIDIA driver managed outside MediaStack" "wizard-ui stage3 nvidia existing: external-driver menu shown"
    assert_eq "nvidia" "$(env_get JELLYFIN_GPU)" "wizard-ui stage3 nvidia existing: JELLYFIN_GPU=nvidia"
    assert_eq "existing" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia existing: NVIDIA_DRIVER_MODE=existing"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 nvidia existing: STAGE_3_GPU_STATE=complete"
}

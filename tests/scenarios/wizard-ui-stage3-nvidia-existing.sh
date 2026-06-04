# tests/scenarios/wizard-ui-stage3-nvidia-existing.sh — pre-existing foreign NVIDIA driver.
#
# The apt install path reports a pre-existing non-Debian driver (rc=2). The
# wizard offers to use it as-is; the user accepts. Asserts mode=existing is
# recorded and the flow verifies/completes against the existing driver.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-existing.sh"
    local steps="/tmp/wizard-stage3-nvidia-existing.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-existing.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'BASH'
install_nvidia_drivers_apt() { return 2; }
BASH"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        driver_mode 1 \
        use_existing 1

    wizard_stage3_run_pty "wizard-ui stage3 nvidia existing" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Existing NVIDIA driver detected" "wizard-ui stage3 nvidia existing: existing-driver box shown"
    assert_eq "nvidia"   "$(env_get JELLYFIN_GPU)"       "wizard-ui stage3 nvidia existing: JELLYFIN_GPU=nvidia"
    assert_eq "existing" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia existing: NVIDIA_DRIVER_MODE=existing"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)"  "wizard-ui stage3 nvidia existing: STAGE_3_GPU_STATE=complete"
}

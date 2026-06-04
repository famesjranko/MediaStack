# tests/scenarios/wizard-ui-stage3-nvidia-unlock-accept.sh — Unlock NVENC accepted.
#
# User selects "Unlock NVENC limit" and confirms. With no pre-existing Debian
# driver and the install reporting no reboot needed, the patch-managed path runs
# the patch + verification and reaches the complete state with mode=unlock.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-unlock-accept.sh"
    local steps="/tmp/wizard-stage3-nvidia-unlock-accept.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-unlock-accept.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        driver_mode 2 \
        unlock_patch_offer y

    wizard_stage3_run_pty "wizard-ui stage3 nvidia unlock accept" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NVIDIA NVENC configured and verified" "wizard-ui stage3 nvidia unlock accept: verified success message"
    assert_eq "nvidia" "$(env_get JELLYFIN_GPU)"       "wizard-ui stage3 nvidia unlock accept: JELLYFIN_GPU=nvidia"
    assert_eq "unlock" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia unlock accept: NVIDIA_DRIVER_MODE=unlock"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 nvidia unlock accept: STAGE_3_GPU_STATE=complete"
}

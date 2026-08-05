# tests/scenarios/wizard-ui-stage3-nvidia-standard.sh — NVIDIA Standard driver mode.
#
# Headline path: GPU detected, user configures transcoding, then picks the
# Standard (Debian-managed, official NVENC limits) driver mode. With the driver
# install reporting no reboot needed and verification passing, the flow reaches
# the verified/complete state. Asserts NVIDIA_DRIVER_MODE=standard is recorded.

source tests/lib/wizard-stage3-common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-standard.sh"
    local steps="/tmp/wizard-stage3-nvidia-standard.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-standard.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        driver_mode 1

    wizard_stage3_run_pty "wizard-ui stage3 nvidia standard" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NVIDIA driver setup" "wizard-ui stage3 nvidia standard: driver-mode box shown"
    assert_contains "$transcript" "Standard driver: Debian-managed" "wizard-ui stage3 nvidia standard: standard option described"
    assert_contains "$transcript" "NVIDIA NVENC configured and verified" "wizard-ui stage3 nvidia standard: verified success message"
    assert_eq "nvidia" "$(env_get JELLYFIN_GPU)" "wizard-ui stage3 nvidia standard: JELLYFIN_GPU=nvidia"
    assert_eq "standard" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia standard: NVIDIA_DRIVER_MODE=standard"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 nvidia standard: STAGE_3_GPU_STATE=complete"
}

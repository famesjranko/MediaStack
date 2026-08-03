# tests/scenarios/wizard-ui-stage3-intel.sh — Intel Quick Sync path.
#
# Intel GPU detected; user configures transcoding. Driver install + verification
# succeed, so QSV is configured and verified (no driver-mode prompt — that's
# NVIDIA-only). Asserts JELLYFIN_GPU=intel and complete state.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-intel.sh"
    local steps="/tmp/wizard-stage3-intel.steps.json"
    local plain_log="/tmp/wizard-stage3-intel.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" intel

    wizard_stage3_steps "$steps" \
        transcode_offer 1

    wizard_stage3_run_pty "wizard-ui stage3 intel" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Intel Quick Sync configured and verified" "wizard-ui stage3 intel: QSV verified message"
    assert_eq "intel" "$(env_get JELLYFIN_GPU)" "wizard-ui stage3 intel: JELLYFIN_GPU=intel"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 intel: STAGE_3_GPU_STATE=complete"
}

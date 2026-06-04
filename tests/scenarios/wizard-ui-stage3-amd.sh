# tests/scenarios/wizard-ui-stage3-amd.sh — AMD VAAPI path.
#
# AMD GPU detected; user configures transcoding. Driver install + verification
# succeed, so VAAPI is configured and verified. Asserts JELLYFIN_GPU=amd and
# complete state.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-amd.sh"
    local steps="/tmp/wizard-stage3-amd.steps.json"
    local plain_log="/tmp/wizard-stage3-amd.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" amd

    wizard_stage3_steps "$steps" \
        transcode_offer 1

    wizard_stage3_run_pty "wizard-ui stage3 amd" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "AMD VAAPI transcoding configured and verified" "wizard-ui stage3 amd: VAAPI verified message"
    assert_eq "amd"      "$(env_get JELLYFIN_GPU)"      "wizard-ui stage3 amd: JELLYFIN_GPU=amd"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 amd: STAGE_3_GPU_STATE=complete"
}

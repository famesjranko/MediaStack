# tests/scenarios/wizard-ui-stage3-no-gpu.sh — no supported GPU detected.
#
# With GPU_TYPE=none, Stage 3 auto-skips without any prompt and leaves Jellyfin
# on software transcoding. No interactive steps — just verify the skip outcome.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-no-gpu.sh"
    local steps="/tmp/wizard-stage3-no-gpu.steps.json"
    local plain_log="/tmp/wizard-stage3-no-gpu.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" none

    dind_exec 'cat >/tmp/wizard-stage3-no-gpu.steps.json <<"JSON"
[]
JSON'

    wizard_stage3_run_pty "wizard-ui stage3 no gpu" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "no supported GPU detected" "wizard-ui stage3 no gpu: auto-skip message shown"
    assert_eq "none"    "$(env_get JELLYFIN_GPU)"      "wizard-ui stage3 no gpu: JELLYFIN_GPU=none"
    assert_eq "skipped" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 no gpu: STAGE_3_GPU_STATE=skipped"
}

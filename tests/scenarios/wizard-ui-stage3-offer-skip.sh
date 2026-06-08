# tests/scenarios/wizard-ui-stage3-offer-skip.sh — Stage 3 offer + "Skip for now".
#
# A GPU is detected (nvidia) but the user declines hardware transcoding at the
# offer. Verifies the explanatory offer box renders (both Stage 2 and Stage 3
# route it to stderr via { ... } >&2 so it survives command substitution) and
# that declining leaves Jellyfin on software transcoding (JELLYFIN_GPU=none,
# state=skipped).

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-offer-skip.sh"
    local steps="/tmp/wizard-stage3-offer-skip.steps.json"
    local plain_log="/tmp/wizard-stage3-offer-skip.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 2

    wizard_stage3_run_pty "wizard-ui stage3 offer skip" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Hardware transcoding is optional" "wizard-ui stage3 offer skip: offer box shown (Stage 3 routes box to stderr)"
    assert_contains "$transcript" "Detected GPU: NVIDIA" "wizard-ui stage3 offer skip: detected GPU surfaced"
    assert_eq "none"    "$(env_get JELLYFIN_GPU)"      "wizard-ui stage3 offer skip: JELLYFIN_GPU=none"
    assert_eq "skipped" "$(env_get STAGE_3_GPU_STATE)" "wizard-ui stage3 offer skip: STAGE_3_GPU_STATE=skipped"
}

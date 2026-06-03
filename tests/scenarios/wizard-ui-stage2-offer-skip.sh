# tests/scenarios/wizard-ui-stage2-offer-skip.sh — Stage 2 offer + "Skip for now".
#
# Simplest Stage 2 interactive path: the remote-access offer is shown and the
# user declines. Verifies the offer box renders and that declining writes
# REMOTE_WEB_STATE=skipped while preserving the Stage 1 completion marker.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-offer-skip.sh"
    local steps="/tmp/wizard-stage2-offer-skip.steps.json"
    local plain_log="/tmp/wizard-stage2-offer-skip.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage2-offer-skip.steps.json <<"JSON"
[
  {"expect": "Set up remote access now\\?"},
  {"send": "2\n"}
]
JSON'

    wizard_stage2_run_pty "wizard-ui stage2 offer skip" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    # F-003 (fixed): _stage2_offer now wraps its ui_section/ui_box in { ... } >&2
    # (mirroring _stage3_offer), so the explanatory box reaches the user instead of
    # being swallowed by offer_action=$(_stage2_offer). Assert it is visible.
    assert_contains "$transcript" "Remote access is not configured yet" "wizard-ui stage2 offer skip: F-003 offer box now visible (fixed)"
    assert_contains "$transcript" "Enable remote access" "wizard-ui stage2 offer skip: enable option shown (menu via stderr)"
    assert_contains "$transcript" "HTTPS skipped" "wizard-ui stage2 offer skip: skip summary shown"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 offer skip: REMOTE_WEB_STATE=skipped"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "wizard-ui stage2 offer skip: Stage 1 marker preserved"
}

# tests/scenarios/wizard-ui-stage2-tell-me-more.sh — offer "Tell me more" loop.
#
# Selects "Tell me more" at the offer, confirms the explanatory copy renders,
# then loops back to the offer and skips. Covers the third offer branch.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-tell-me-more.sh"
    local steps="/tmp/wizard-stage2-tell-me-more.steps.json"
    local plain_log="/tmp/wizard-stage2-tell-me-more.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    # After "Tell me more", the offer loops. We wait for a line unique to the
    # tell-me-more output, then send "2" — buffered and consumed by the second
    # offer's ui_choose (re-matching the duplicate offer prompt would match the
    # already-buffered first prompt instantly, so we key off the unique line).
    dind_exec 'cat >/tmp/wizard-stage2-tell-me-more.steps.json <<"JSON"
[
  {"expect": "Set up remote access now\\?"},
  {"send": "3\n"},
  {"expect": "Dynu is recommended because the free tier supports wildcard records"},
  {"send": "2\n"}
]
JSON'

    wizard_stage2_run_pty "wizard-ui stage2 tell me more" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "WireGuard gives you a VPN for admin pages" "wizard-ui stage2 tell me more: explanatory copy shown"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 tell me more: loops back and skips -> REMOTE_WEB_STATE=skipped"
}

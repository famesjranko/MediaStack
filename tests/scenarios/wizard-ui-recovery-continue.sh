# tests/scenarios/wizard-ui-recovery-continue.sh — day-2 recovery menu, continue path.
#
# On a re-run with a completed install, the user picks "Use existing install",
# then "Continue without changes" in the recovery submenu. Asserts both menus
# render and no changes are made (.env preserved).

source tests/lib/wizard_recovery_common.sh

run_scenario() {
    local fixture="/tmp/wizard-recovery-continue.sh"
    local steps="/tmp/wizard-recovery-continue.steps.json"
    local plain_log="/tmp/wizard-recovery-continue.plain.log"

    wizard_recovery_write_base_fixture "$fixture"
    wizard_recovery_append_runner "$fixture"

    # Two menus share the prompt "What would you like to do?"; key the second
    # send off a line unique to the submenu box instead of re-matching it.
    dind_exec 'cat >/tmp/wizard-recovery-continue.steps.json <<"JSON"
[
  {"expect": "What would you like to do\\?"},
  {"send": "1\n"},
  {"expect": "You can add skipped features to this install"},
  {"send": "2\n"}
]
JSON'

    wizard_recovery_run_pty "wizard-ui recovery continue" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Existing MediaStack install detected" "wizard-ui recovery continue: top-level detection prompt shown"
    assert_contains "$transcript" "Existing install detected" "wizard-ui recovery continue: recovery submenu box shown"
    assert_contains "$transcript" "Continuing with existing install. No changes made." "wizard-ui recovery continue: continue path message"
    if dind_exec "test -f .env"; then
        pass "wizard-ui recovery continue: .env preserved (no changes)"
    else
        fail "wizard-ui recovery continue: .env preserved (no changes)"
    fi
}

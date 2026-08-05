# tests/scenarios/wizard-ui-recovery-wipe-guard.sh — DESTROY typed-confirmation guard.
#
# Safety-critical: choosing "Wipe everything and start fresh" must require typing
# DESTROY exactly. Here the user types something else; the guard must abort with
# no destruction (.env preserved). One typo aborts.

source tests/lib/wizard-recovery-common.sh

run_scenario() {
    local fixture="/tmp/wizard-recovery-wipe-guard.sh"
    local steps="/tmp/wizard-recovery-wipe-guard.steps.json"
    local plain_log="/tmp/wizard-recovery-wipe-guard.plain.log"

    wizard_recovery_write_base_fixture "$fixture"
    wizard_recovery_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-recovery-wipe-guard.steps.json <<"JSON"
[
  {"expect": "What would you like to do\\?"},
  {"send": "2\n"},
  {"expect": "Type DESTROY to confirm"},
  {"send": "destroy please\n"}
]
JSON'

    wizard_recovery_run_pty "wizard-ui recovery wipe guard" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "This will DELETE" "wizard-ui recovery wipe guard: destroy preview shown"
    assert_contains "$transcript" "Type DESTROY to confirm" "wizard-ui recovery wipe guard: typed-confirmation prompt shown"
    assert_contains "$transcript" "Aborted. No changes made." "wizard-ui recovery wipe guard: non-DESTROY input aborts"
    if dind_exec "test -f .env"; then
        pass "wizard-ui recovery wipe guard: .env preserved (guard held)"
    else
        fail "wizard-ui recovery wipe guard: .env preserved (guard held)"
    fi
}

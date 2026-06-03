# tests/scenarios/wizard-ui-stage3-nvidia-unlock-decline.sh — Unlock confirm decline + loop.
#
# Exercises the mode picker's loop: the user selects "Unlock NVENC limit", reads
# the advisory box, declines the confirmation, views "Tell me more", then falls
# back to the Standard driver. Asserts the picker recovers to standard mode.

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-unlock-decline.sh"
    local steps="/tmp/wizard-stage3-nvidia-unlock-decline.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-unlock-decline.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    wizard_stage3_append_runner "$fixture" nvidia

    # Key off lines unique to each post-action state rather than re-matching the
    # (duplicate) mode-picker prompt, which would match the already-buffered first
    # occurrence instantly.
    dind_exec 'cat >/tmp/wizard-stage3-nvidia-unlock-decline.steps.json <<"JSON"
[
  {"expect": "Configure hardware transcoding now\\?"},
  {"send": "1\n"},
  {"expect": "How should MediaStack set up the NVIDIA driver\\?"},
  {"send": "2\n"},
  {"expect": "Install the patch-managed driver and apply nvidia-patch\\?"},
  {"send": "n\n"},
  {"expect": "Leaving the patch unapplied"},
  {"send": "3\n"},
  {"expect": "Debian.s packaged NVIDIA driver"},
  {"send": "1\n"}
]
JSON'

    wizard_stage3_run_pty "wizard-ui stage3 nvidia unlock decline" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Unlock NVENC limit (advanced)" "wizard-ui stage3 nvidia unlock decline: unlock advisory box shown"
    assert_contains "$transcript" "Leaving the patch unapplied" "wizard-ui stage3 nvidia unlock decline: decline message shown"
    assert_eq "standard" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia unlock decline: recovered to standard mode"
    assert_eq "complete" "$(env_get STAGE_3_GPU_STATE)"  "wizard-ui stage3 nvidia unlock decline: STAGE_3_GPU_STATE=complete"
}

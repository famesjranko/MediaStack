# tests/scenarios/wizard-ui-stage3-nvidia-reboot.sh — NVIDIA Standard, reboot required.
#
# Standard driver install reports a reboot is required (kernel module not yet
# loaded). The wizard queues finalization, writes the resume marker, and shows
# the reboot prompt; the user picks "Reboot manually later". Asserts the pending
# state + marker are recorded (no actual reboot — `reboot` is stubbed).

source tests/lib/wizard_stage3_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage3-nvidia-reboot.sh"
    local steps="/tmp/wizard-stage3-nvidia-reboot.steps.json"
    local plain_log="/tmp/wizard-stage3-nvidia-reboot.plain.log"

    wizard_stage3_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'BASH'
install_nvidia_drivers_apt() { NEEDS_REBOOT=true; return 0; }
BASH"
    wizard_stage3_append_runner "$fixture" nvidia

    wizard_stage3_steps "$steps" \
        transcode_offer 1 \
        driver_mode 1 \
        reboot_now 2

    wizard_stage3_run_pty "wizard-ui stage3 nvidia reboot" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Reboot needed to finish NVIDIA transcoding" "wizard-ui stage3 nvidia reboot: reboot box shown"
    assert_contains "$transcript" "Reboot manually when ready" "wizard-ui stage3 nvidia reboot: manual-later path message"
    assert_eq "standard" "$(env_get NVIDIA_DRIVER_MODE)" "wizard-ui stage3 nvidia reboot: NVIDIA_DRIVER_MODE=standard"
    assert_eq "pending"  "$(env_get STAGE_3_GPU_STATE)"  "wizard-ui stage3 nvidia reboot: STAGE_3_GPU_STATE=pending"
    if dind_exec "test -f .nvidia-finalize-pending"; then
        pass "wizard-ui stage3 nvidia reboot: finalize marker written"
    else
        fail "wizard-ui stage3 nvidia reboot: finalize marker written"
    fi
    assert_eq "standard" "$(dind_exec "python3 -c \"import json; print(json.load(open('.nvidia-finalize-pending')).get('nvidia_driver_mode',''))\" 2>/dev/null")" "wizard-ui stage3 nvidia reboot: marker records standard mode"
}

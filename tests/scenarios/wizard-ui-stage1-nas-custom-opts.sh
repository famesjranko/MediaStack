# tests/scenarios/wizard-ui-stage1-nas-custom-opts.sh — custom NFS options + re-verify.
#
# After the connection is verified and confirmed, the user declines the
# recommended NFS options and enters their own. Those options are unproven, so
# the wizard must re-run the probe with them before accepting. This asserts the
# custom value lands in .env and the probe ran a second time (initial + reprobe).
source tests/lib/wizard_stage1_common.sh

wizard_ui_stage1_nas_custom_opts_write_fixture() {
    wizard_stage1_write_base_fixture "/tmp/wizard-stage1-nas-custom.sh" "wizard-nas-custom-key"
    # Probe always succeeds (share is reachable); count invocations so we can prove
    # the custom options triggered a second, re-verifying probe.
    dind_exec "cat >>/tmp/wizard-stage1-nas-custom.sh <<'BASH'
rm -f /tmp/wizard-nas-custom-attempts
mkdir -p /tmp/ms-wizard-nas-custom
storage_probe_nas() {
    local attempts=0
    [[ -f /tmp/wizard-nas-custom-attempts ]] && attempts=\$(cat /tmp/wizard-nas-custom-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' \"\$attempts\" > /tmp/wizard-nas-custom-attempts
    _STORAGE_PROBE_CLASS=empty
}
BASH"
    wizard_stage1_append_runner "/tmp/wizard-stage1-nas-custom.sh"
}

wizard_ui_stage1_nas_custom_opts_write_steps() {
    wizard_build_steps "/tmp/wizard-stage1-nas-custom.steps.json" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@custom.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-custom \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/mediastack \
        stage1_nas_share_empty NONE \
        stage1_nas_nfs_options_confirm n \
        stage1_nas_nfs_options vers=4.1,proto=tcp,rw,soft,timeo=100,retrans=3 \
        stage1_nas_watchdog ENTER \
        stage1_nas_review 1 \
        stage1_bazarr ENTER \
        stage1_subtitle_confirm 1 \
        stage1_smb ENTER \
        stage1_smb_confirm 1 \
        stage1_quality_resolution 1 stage1_quality_size 1 \
        stage1_quality_confirm 1 \
        stage1_indexers ENTER \
        stage1_indexers_confirm 1 \
        stage1_image_channel 1 \
        stage1_qbt_download ENTER \
        stage1_qbt_upload ENTER \
        stage1_qbt_port ENTER \
        stage1_qbit_confirm 1 \
        stage1_security_ufw ENTER stage1_security_hardening ENTER \
        stage1_proceed 1
}

run_scenario() {
    local plain_log="/tmp/wizard-stage1-nas-custom.plain.log"
    wizard_ui_stage1_nas_custom_opts_write_fixture
    wizard_ui_stage1_nas_custom_opts_write_steps

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command /tmp/wizard-stage1-nas-custom.sh \
        --steps /tmp/wizard-stage1-nas-custom.steps.json \
        --raw-log /tmp/wizard-stage1-nas-custom.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui stage1 NAS custom opts: PTY flow exits 0"
    else
        fail "wizard-ui stage1 NAS custom opts: PTY flow exits 0"
        dind_exec "tail -120 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Custom NFS options are advanced" "wizard-ui stage1 NAS custom opts: risk warning shown"

    # Probe runs once during verification, then again to re-verify the custom opts.
    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-custom-attempts")" "wizard-ui stage1 NAS custom opts: probe re-ran for custom options"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS custom opts: STORAGE_MODE=nas"
    assert_eq "vers=4.1,proto=tcp,rw,soft,timeo=100,retrans=3" "$(env_get STORAGE_NFS_OPTS)" "wizard-ui stage1 NAS custom opts: custom options written to .env"
}

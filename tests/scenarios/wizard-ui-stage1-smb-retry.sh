# tests/scenarios/wizard-ui-stage1-smb-retry.sh — SMB port retry UX.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-smb-retry.sh"
    local steps="/tmp/wizard-stage1-smb-retry.steps.json"
    local plain_log="/tmp/wizard-stage1-smb-retry.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-smb-retry-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-smb-retry
validate_smb_port() {
    local attempts=0
    [[ -f /tmp/wizard-smb-port-attempts ]] && attempts=\$(cat /tmp/wizard-smb-port-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' \$attempts > /tmp/wizard-smb-port-attempts
    (( attempts >= 2 ))
}
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@smb-retry.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-smb-retry \
        stage1_storage_confirm 1 \
        stage1_bazarr ENTER \
        stage1_subtitle_confirm 1 \
        stage1_smb y \
        stage1_smb_port_conflict 1 \
        stage1_smb_scope 1 \
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

    wizard_stage1_run_pty "wizard-ui stage1 SMB retry" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "SMB needs TCP port 445. What should setup do?" "wizard-ui stage1 SMB retry: retry menu shown"
    assert_contains "$transcript" "Retry port check" "wizard-ui stage1 SMB retry: retry option shown"
    assert_contains "$transcript" "Disable SMB" "wizard-ui stage1 SMB retry: disable option shown"
    assert_eq "2" "$(dind_exec "cat /tmp/wizard-smb-port-attempts")" "wizard-ui stage1 SMB retry: port check retried"
    assert_eq "true" "$(env_get SMB_ENABLED)" "wizard-ui stage1 SMB retry: SMB enabled after successful retry"
    assert_eq "data" "$(env_get SMB_SHARE_SCOPE)" "wizard-ui stage1 SMB retry: data scope selected"
}

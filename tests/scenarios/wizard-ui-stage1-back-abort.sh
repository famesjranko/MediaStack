# tests/scenarios/wizard-ui-stage1-back-abort.sh — install confirmation back/abort safety.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-back-abort.sh"
    local steps="/tmp/wizard-stage1-back-abort.steps.json"
    local plain_log="/tmp/wizard-stage1-back-abort.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-back-abort-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-back-one /tmp/ms-wizard-back-two
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@back-abort.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-back-one \
        stage1_storage_confirm 1 \
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
        stage1_proceed 2 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@back-abort.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-back-two \
        stage1_storage_confirm 1 \
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
        stage1_proceed 3

    wizard_stage1_run_pty "wizard-ui stage1 back abort" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Core Media Server: Install Plan" "wizard-ui stage1 back abort: install plan shown"
    assert_contains "$transcript" "Setup aborted" "wizard-ui stage1 back abort: abort message shown"
    if dind_exec "test ! -f .env"; then
        pass "wizard-ui stage1 back abort: abort leaves no .env"
    else
        fail "wizard-ui stage1 back abort: abort leaves no .env"
    fi
}

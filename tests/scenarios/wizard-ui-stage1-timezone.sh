# tests/scenarios/wizard-ui-stage1-timezone.sh — Stage 1 timezone-override branch.
#
# The system screen offers Continue / Override timezone / Abort. This drives the
# middle branch: pick "Override timezone", enter a valid zone that differs from
# the detected default, and confirm it lands in .env as TZ. This is the only run
# that covers the override path (the all-defaults runs take "Continue"). The DinD image
# ships a full tzdata tree, so America/New_York validates against
# /usr/share/zoneinfo without extra setup.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-timezone.sh"
    local steps="/tmp/wizard-stage1-timezone.steps.json"
    local plain_log="/tmp/wizard-stage1-timezone.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-tz-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-tz
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 2 \
        stage1_timezone America/New_York \
        stage1_admin_username ENTER \
        stage1_admin_email owner@stage1-tz.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-tz \
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
        stage1_proceed 1

    wizard_stage1_run_pty "wizard-ui stage1 timezone" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Override timezone" "wizard-ui stage1 timezone: override option shown"
    assert_contains "$transcript" "Timezone" "wizard-ui stage1 timezone: timezone input prompt shown"
    assert_eq "America/New_York" "$(env_get TZ)" "wizard-ui stage1 timezone: TZ override persisted to .env"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "wizard-ui stage1 timezone: Stage 1 completed"
}

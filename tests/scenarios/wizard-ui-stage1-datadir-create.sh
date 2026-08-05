# tests/scenarios/wizard-ui-stage1-datadir-create.sh — Stage 1 data-dir create branch.
#
# When the chosen local data directory does not yet exist, validate_data_dir
# (scripts/lib/validators.sh) prompts "Path <p> does not exist. Create it?" and
# creates it on yes. The all-defaults and options runs pre-create the directory,
# so this is the only scenario that drives the create-it confirmation. Asserts
# the directory is created, validation continues, and DATA_DIR persists.

source tests/lib/wizard-stage1-common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-datadir-create.sh"
    local steps="/tmp/wizard-stage1-datadir-create.steps.json"
    local plain_log="/tmp/wizard-stage1-datadir-create.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-datadir-key"
    # Start from a guaranteed-absent path so validate_data_dir takes the
    # create-it branch (idempotent across re-runs).
    dind_exec "cat >>$fixture <<'BASH'
rm -rf /tmp/ms-wizard-newdir
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@stage1-datadir.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-newdir \
        stage1_datadir_create_confirm y \
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

    wizard_stage1_run_pty "wizard-ui stage1 datadir create" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "does not exist. Create it?" "wizard-ui stage1 datadir create: create-it prompt shown"
    assert_eq "/tmp/ms-wizard-newdir" "$(env_get DATA_DIR)" "wizard-ui stage1 datadir create: DATA_DIR persisted"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "wizard-ui stage1 datadir create: Stage 1 completed"
    if dind_exec "test -d /tmp/ms-wizard-newdir"; then
        pass "wizard-ui stage1 datadir create: directory created on confirm"
    else
        fail "wizard-ui stage1 datadir create: directory created on confirm"
    fi
}

# tests/scenarios/wizard-ui-stage1-nas-edit-retry.sh — edit NAS settings after mount failure.

source tests/lib/wizard-stage1-common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-nas-edit-retry.sh"
    local steps="/tmp/wizard-stage1-nas-edit-retry.steps.json"
    local plain_log="/tmp/wizard-stage1-nas-edit-retry.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-nas-edit-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-nas-edit
storage_probe_nas() {
    local attempts=0
    [[ -f /tmp/wizard-nas-edit-attempts ]] && attempts=\$(cat /tmp/wizard-nas-edit-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' \$attempts > /tmp/wizard-nas-edit-attempts
    [[ \${STORAGE_NFS_HOST:-} == 127.0.0.2 ]] || return 1
    _STORAGE_PROBE_CLASS=empty
}
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@edit-retry.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-edit \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/bad \
        stage1_nas_mount_failed 1 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-edit \
        stage1_nas_host 127.0.0.2 \
        stage1_nas_nfs_export /exports/good \
        stage1_nas_share_empty NONE \
        stage1_nas_nfs_options_confirm ENTER \
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

    wizard_stage1_run_pty "wizard-ui stage1 NAS edit retry" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 NAS edit retry: edit option shown"
    assert_contains "$transcript" "nas at /tmp/ms-wizard-nas-edit" "wizard-ui stage1 NAS edit retry: plan summarizes NAS storage"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-edit-attempts")" "wizard-ui stage1 NAS edit retry: mount attempted before and after edit"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS edit retry: STORAGE_MODE=nas"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS edit retry: app wiring managed"
    assert_eq "127.0.0.2" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS edit retry: corrected host persisted"
    assert_eq "/exports/good" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS edit retry: corrected export persisted"
    assert_eq "/tmp/ms-wizard-nas-edit/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS edit retry: sentinel follows mountpoint"
}

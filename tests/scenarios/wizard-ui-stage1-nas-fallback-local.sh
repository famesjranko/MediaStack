# tests/scenarios/wizard-ui-stage1-nas-fallback-local.sh — NAS failure to local storage.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-nas-fallback-local.sh"
    local steps="/tmp/wizard-stage1-nas-fallback-local.steps.json"
    local plain_log="/tmp/wizard-stage1-nas-fallback-local.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-nas-local-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-nas-local
storage_probe_nas() { return 1; }
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@fallback-local.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-local \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/bad \
        stage1_nas_mount_failed 3 \
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

    wizard_stage1_run_pty "wizard-ui stage1 NAS fallback local" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS mount failed. What should setup do?" "wizard-ui stage1 NAS fallback local: failure menu shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 NAS fallback local: local fallback option shown"
    assert_contains "$transcript" "local at /data" "wizard-ui stage1 NAS fallback local: plan summarizes local fallback"

    assert_eq "local" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS fallback local: STORAGE_MODE=local"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS fallback local: app wiring managed"
    assert_eq "/data" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS fallback local: DATA_DIR reset to local default"
    assert_eq "" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS fallback local: NFS host cleared"
    assert_eq "" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS fallback local: NFS export cleared"
    assert_eq "/data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS fallback local: local sentinel set"
}

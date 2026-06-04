# tests/scenarios/wizard-ui-stage1-final-nas-preflight.sh — final NAS preflight retry gate.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-final-nas-preflight.sh"
    local steps="/tmp/wizard-stage1-final-nas-preflight.steps.json"
    local plain_log="/tmp/wizard-stage1-final-nas-preflight.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-final-nas-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-final-nas
storage_preflight_nas() {
    local attempts=0
    [[ -f /tmp/wizard-final-nas-attempts ]] && attempts=\$(cat /tmp/wizard-final-nas-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' "\$attempts" > /tmp/wizard-final-nas-attempts
    (( attempts >= 2 ))
}
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@final-nas.test \
        stage1_admin_password ENTER \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-final-nas \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/final \
        stage1_nas_nfs_options ENTER \
        stage1_nas_sentinel ENTER \
        stage1_nas_share_empty NONE \
        stage1_bazarr ENTER \
        stage1_smb ENTER \
        stage1_quality 1 \
        stage1_subtitle_langs ENTER \
        stage1_indexers ENTER \
        stage1_image_channel 1 \
        stage1_qbt_download ENTER \
        stage1_qbt_upload ENTER \
        stage1_qbt_port ENTER \
        stage1_proceed 1 \
        stage1_nas_storage_check_failed 1

    wizard_stage1_run_pty "wizard-ui stage1 final NAS preflight" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS storage check failed. What should setup do?" "wizard-ui stage1 final NAS preflight: final gate shown"
    assert_contains "$transcript" "Retry NAS check" "wizard-ui stage1 final NAS preflight: retry option shown"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 final NAS preflight: edit option shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 final NAS preflight: local fallback shown"
    assert_contains "$transcript" "Advanced manual storage" "wizard-ui stage1 final NAS preflight: manual fallback shown"
    assert_contains "$transcript" "Quit installer" "wizard-ui stage1 final NAS preflight: quit option shown"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-final-nas-attempts")" "wizard-ui stage1 final NAS preflight: preflight retried once"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 final NAS preflight: NAS state preserved after retry"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 final NAS preflight: app wiring managed"
    assert_eq "/tmp/ms-wizard-final-nas" "$(env_get DATA_DIR)" "wizard-ui stage1 final NAS preflight: DATA_DIR preserved"
    assert_eq "127.0.0.1" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 final NAS preflight: NFS host preserved"
}

# tests/scenarios/wizard-ui-stage1-nas-retry.sh — Stage 1 NAS retry wizard UX.
#
# Simulates an NFS mount failure followed by "Retry with the same settings".
# The scenario runs real prompts through a PTY and asserts both transcript UX
# and generated storage state.

# Reuses the shared Stage-1 fixture builders (wizard_stage1_common.sh) so the stub vocabulary
# lives in one place (tests/lib/wizard_stub_common.sh). That source is side-effect-free in this
# shell — its only top-level statement is `source wizard_steps_common.sh` (the step-builder); the
# `source ./setup.sh` lives INSIDE the fixture heredoc, so it runs in the DinD container, not here.
# This scenario still drives wizard_pty.py directly (keeping its own assertions) rather than via
# wizard_stage1_run_pty.
source tests/lib/wizard_stage1_common.sh

wizard_ui_stage1_nas_retry_write_fixture() {
    wizard_stage1_write_base_fixture "/tmp/wizard-stage1-nas-retry.sh" "wizard-nas-key"
    # Reset the attempt counter, pre-create the NAS mountpoint, and override the base
    # storage_mount_nfs stub so the first mount attempt fails and the retry succeeds.
    dind_exec "cat >>/tmp/wizard-stage1-nas-retry.sh <<'BASH'
rm -f /tmp/wizard-nas-mount-attempts
mkdir -p /tmp/ms-wizard-nas-data
storage_probe_nas() {
    local attempts=0
    [[ -f /tmp/wizard-nas-mount-attempts ]] && attempts=\$(cat /tmp/wizard-nas-mount-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' \"\$attempts\" > /tmp/wizard-nas-mount-attempts
    (( attempts >= 2 )) || return 1
    _STORAGE_PROBE_CLASS=empty
}
BASH"
    wizard_stage1_append_runner "/tmp/wizard-stage1-nas-retry.sh"
}

wizard_ui_stage1_nas_retry_write_steps() {
    wizard_build_steps "/tmp/wizard-stage1-nas-retry.steps.json" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@nas.test \
        stage1_admin_password WizardAdminPw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-data \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/mediastack \
        stage1_nas_mount_failed 2 \
        stage1_nas_share_empty NONE \
        stage1_nas_nfs_options_confirm ENTER \
        stage1_nas_watchdog ENTER \
        stage1_nas_review 2 \
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
}

run_scenario() {
    local plain_log="/tmp/wizard-stage1-nas-retry.plain.log"
    wizard_ui_stage1_nas_retry_write_fixture
    wizard_ui_stage1_nas_retry_write_steps

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command /tmp/wizard-stage1-nas-retry.sh \
        --steps /tmp/wizard-stage1-nas-retry.steps.json \
        --raw-log /tmp/wizard-stage1-nas-retry.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui stage1 NAS retry: PTY flow exits 0"
    else
        fail "wizard-ui stage1 NAS retry: PTY flow exits 0"
        dind_exec "tail -120 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS mount failed. What should setup do?" "wizard-ui stage1 NAS retry: failure menu shown"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 NAS retry: edit option shown"
    assert_contains "$transcript" "Retry with the same settings" "wizard-ui stage1 NAS retry: retry option shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 NAS retry: local fallback shown"
    assert_contains "$transcript" "Advanced manual storage" "wizard-ui stage1 NAS retry: manual fallback shown"
    assert_contains "$transcript" "nas at /tmp/ms-wizard-nas-data" "wizard-ui stage1 NAS retry: plan summarizes NAS storage"
    assert_contains "$transcript" "Storage choices to lock in" "wizard-ui stage1 NAS retry: review box shown"
    assert_contains "$transcript" "Change NFS options / watchdog" "wizard-ui stage1 NAS retry: review offers per-layer navigation"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-mount-attempts")" "wizard-ui stage1 NAS retry: mount retried once"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS retry: STORAGE_MODE=nas"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS retry: app wiring managed"
    assert_eq "nfs" "$(env_get STORAGE_PROTOCOL)" "wizard-ui stage1 NAS retry: protocol nfs"
    assert_eq "/tmp/ms-wizard-nas-data" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS retry: DATA_DIR is NAS mountpoint"
    assert_eq "127.0.0.1" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS retry: NFS host preserved"
    assert_eq "/exports/mediastack" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS retry: NFS export preserved"
    assert_eq "/tmp/ms-wizard-nas-data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS retry: sentinel default preserved"
}

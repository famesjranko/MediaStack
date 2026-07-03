# tests/scenarios/wizard-ui-stage1-local.sh — Stage 1 local-storage wizard UX.
#
# Drives real Stage 1 prompts through a PTY while stubbing slow/dangerous install
# operations. This validates interactive UI flow and generated state without
# pulling images or starting the stack.

# Reuses the shared Stage-1 fixture builders (wizard_stage1_common.sh) so the stub vocabulary
# lives in one place (tests/lib/wizard_stub_common.sh). That source is side-effect-free in this
# shell — its only top-level statement is `source wizard_steps_common.sh` (the step-builder); the
# `source ./setup.sh` lives INSIDE the fixture heredoc, so it runs in the DinD container, not here.
# This scenario still drives wizard_pty.py directly (keeping its own assertions) rather than via
# wizard_stage1_run_pty.
source tests/lib/wizard_stage1_common.sh

wizard_ui_stage1_local_write_fixture() {
    wizard_stage1_write_base_fixture "/tmp/wizard-stage1-local.sh" "wizard-local-key"
    dind_exec "cat >>/tmp/wizard-stage1-local.sh <<'BASH'
mkdir -p /tmp/ms-wizard-local-data
BASH"
    wizard_stage1_append_runner "/tmp/wizard-stage1-local.sh"
}

wizard_ui_stage1_local_write_steps() {
    wizard_build_steps "/tmp/wizard-stage1-local.steps.json" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@lan.test \
        stage1_admin_password MaskMe-Secret-Pw123 \
        stage1_admin_confirm 1 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-local-data \
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
}

run_scenario() {
    local plain_log="/tmp/wizard-stage1-local.plain.log"
    wizard_ui_stage1_local_write_fixture
    wizard_ui_stage1_local_write_steps

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command /tmp/wizard-stage1-local.sh \
        --steps /tmp/wizard-stage1-local.steps.json \
        --raw-log /tmp/wizard-stage1-local.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui stage1 local: PTY flow exits 0"
    else
        fail "wizard-ui stage1 local: PTY flow exits 0"
        dind_exec "tail -100 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Where should MediaStack store media and downloads?" "wizard-ui stage1 local: storage menu shown"
    assert_contains "$transcript" "Local disk (/data)" "wizard-ui stage1 local: local storage option shown"
    assert_contains "$transcript" "Core Media Server: Install Plan" "wizard-ui stage1 local: confirm plan shown"
    assert_contains "$transcript" "local at /tmp/ms-wizard-local-data" "wizard-ui stage1 local: plan summarizes local storage"

    assert_eq "local" "$(env_get STORAGE_MODE)" "wizard-ui stage1 local: STORAGE_MODE=local"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 local: app wiring managed"
    assert_eq "/tmp/ms-wizard-local-data" "$(env_get DATA_DIR)" "wizard-ui stage1 local: DATA_DIR from prompt"
    assert_eq "" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 local: NFS host blank"
    assert_eq "/tmp/ms-wizard-local-data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 local: local sentinel default"
    assert_eq "false" "$(env_get BAZARR_ENABLED)" "wizard-ui stage1 local: Bazarr disabled by default"
    assert_eq "false" "$(env_get SMB_ENABLED)" "wizard-ui stage1 local: SMB disabled by prompt"

    # The admin password is now collected visibly (ui_input_validated) by design —
    # a single shared home-server admin password, ease-of-use over masking.
    # Positive control — the typed value was accepted and persisted:
    assert_eq "MaskMe-Secret-Pw123" "$(env_get JELLYFIN_ADMIN_PASSWORD)" "wizard-ui stage1 local: typed admin password persisted"
    # Visible-by-design proof — the typed value is shown in the prompt transcript.
    case "$transcript" in
        *MaskMe-Secret-Pw123*) pass "wizard-ui stage1 local: admin password shown (visible by design)" ;;
        *)                     fail "wizard-ui stage1 local: admin password shown (visible by design)" "expected typed password visible in transcript" ;;
    esac
}

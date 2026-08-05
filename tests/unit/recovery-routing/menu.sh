#!/usr/bin/env bash
# tests/unit/recovery-routing/menu.sh
#
# Existing-install recovery menu: contextual availability, action dispatch,
# main() re-entry stops, and launcher-capstone exit-token honesty.

# ---------------------------------------------------------------------------
# Existing-install recovery menu is contextual and non-destructive.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "menu-context"
seed_env "unchecked" "intel" "skipped"
set -a
source "$SCRIPT_DIR/.env"
set +a
GPU_TYPE="intel"
if is_pending_helper recovery_menu_remote_available || is_pending_helper recovery_menu_transcoding_available; then
    skip "contextual existing-install menu availability pending implementation"
else
    recovery_menu_remote_available
    remote_rc=$?
    recovery_menu_transcoding_available
    transcoding_rc=$?
    assert_eq "0" "$remote_rc" "menu includes remote retry for REMOTE_WEB_STATE=unchecked"
    assert_eq "0" "$transcoding_rc" "menu includes transcoding when GPU is present and Stage 3 is not complete"

    REMOTE_WEB_STATE=ready
    recovery_menu_remote_available
    remote_ready_rc=$?
    assert_eq "1" "$remote_ready_rc" "menu hides remote retry for REMOTE_WEB_STATE=ready"

    # shellcheck disable=SC2034 # read by recovery_menu_remote_available in scripts/launcher/recovery.sh, sourced by the suite entry point
    REMOTE_WEB_STATE=failed
    recovery_menu_remote_available
    remote_failed_rc=$?
    assert_eq "0" "$remote_failed_rc" "menu includes remote retry for REMOTE_WEB_STATE=failed"

    GPU_TYPE=none
    STAGE_3_GPU_STATE=skipped
    recovery_menu_transcoding_available
    no_gpu_rc=$?
    assert_eq "1" "$no_gpu_rc" "menu hides transcoding when no GPU is detected"

    GPU_TYPE=intel
    # shellcheck disable=SC2034 # read by recovery_menu_transcoding_available in scripts/launcher/recovery.sh, sourced by the suite entry point
    STAGE_3_GPU_STATE=complete
    recovery_menu_transcoding_available
    complete_rc=$?
    assert_eq "1" "$complete_rc" "menu hides transcoding when Stage 3 is complete"
fi

checks_source="$(cat "$REPO_ROOT/scripts/setup/checks/existing-install.sh" "$REPO_ROOT/scripts/setup/checks/destroy.sh")"
assert_contains "$checks_source" "Wipe everything and start fresh" "destructive wipe copy remains present"
assert_contains "$checks_source" "nuke_existing_install" "destructive wipe delegates to nuke_existing_install"

if [[ -f "$REPO_ROOT/scripts/setup/recovery.sh" ]]; then
    recovery_source="$(sed -n '1,760p' "$REPO_ROOT/scripts/setup/recovery.sh")"
    if [[ "$recovery_source" == *"docker compose"*"down -v"* ]]; then
        fail "recovery menu does not invoke docker compose down -v directly"
    else
        pass "recovery menu does not invoke docker compose down -v directly"
    fi
else
    skip "recovery menu direct-destroy check pending scripts/setup/recovery.sh"
fi

if ! is_pending_helper show_existing_install_menu; then
    ui_box() {
        record ui_box
        # Capture the box body (intro + "Current setup:" feature-state block) so
        # tests can assert the re-entry menu surfaces current state. The intro
        # title is $1; the remaining args are content lines.
        if [[ -n "${BOX_CAPTURE:-}" ]]; then
            shift
            printf '%s\n' "$@" >"$BOX_CAPTURE"
        fi
    }
    ui_choose() {
        # Recording hook for debugging; not asserted.
        # shellcheck disable=SC2034
        MENU_PROMPT="$1"
        shift
        printf '%s\n' "$*" >"$MENU_CAPTURE"
        printf '%s\n' "$MENU_CHOICE"
    }
    run_remote_recovery() {
        record run_remote_recovery
        return "${REMOTE_RECOVERY_RC:-0}"
    }
    run_transcoding_recovery() {
        record run_transcoding_recovery
        return "${TRANSCODING_RECOVERY_RC:-0}"
    }
    nuke_existing_install() {
        record nuke_existing_install
        return 0
    }

    reset_route_state
    seed_script_dir "menu-remote-action"
    seed_env "unchecked" "none" "skipped"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    BOX_CAPTURE="$SCRIPT_DIR/menu-box"
    MENU_CHOICE="Add remote access"
    MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    MENU_BOX=$(cat "$BOX_CAPTURE")
    assert_eq "0" "$rc" "remote menu action returns helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "remote menu action sets RECOVERY_MENU_ACTION=completed"
    assert_eq "completed" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "successful sub-action records 'completed' for the strict launcher capstone"
    unset MEDIASTACK_LAUNCHER_RESULT
    assert_order_has "run_remote_recovery" "remote menu action dispatches to run_remote_recovery"
    assert_order_lacks "nuke_existing_install" "remote menu action does not wipe"
    assert_contains "$MENU_OPTIONS" "Add remote access" "menu shows add remote when unchecked"
    assert_contains "$MENU_OPTIONS" "Add hardware transcoding" "menu shows transcoding when GPU is fresh"

    # The re-entry menu surfaces the CURRENT state of every offered
    # feature in the intro box, reusing the print_final_summary
    # labels. Index safety: this state must live in the printed box, NOT as a
    # ui_choose option (a status line consuming a selection index would break
    # the position-based PTY drivers wizard-ui-recovery-continue/-wipe-guard).
    assert_contains "$MENU_BOX" "Current setup:" "re-entry box shows a Current setup status block"
    assert_contains "$MENU_BOX" "Remote access: not configured" "box reports remote-access state (unchecked -> not configured)"
    assert_contains "$MENU_BOX" "Hardware transcoding: skipped - software transcoding" "box reports transcoding state from STAGE_3_GPU_STATE"
    if [[ "$MENU_OPTIONS" == *"Current setup"* || "$MENU_OPTIONS" == *"Remote access:"* || "$MENU_OPTIONS" == *"Hardware transcoding:"* ]]; then
        fail "feature-state text must NOT be a ui_choose option (index safety)" "$MENU_OPTIONS"
    else
        pass "feature-state text is not a selectable ui_choose option (index safety)"
    fi
    # Index safety: the full selectable option list (ui_choose args) must be
    # byte-identical to pre-change order, so the position-based PTY drivers keep
    # working. ui_choose joins args with a single space (see its stub above).
    assert_eq "Add remote access Add hardware transcoding Continue without changes Wipe everything and start fresh Abort" "$MENU_OPTIONS" "selectable option order is unchanged (state block did not add a ui_choose item)"
    unset BOX_CAPTURE

    # Exact replay of the wizard-ui-recovery-continue PTY fixture state
    # (REMOTE_WEB_STATE empty, GPU none) — the driver sends "2" expecting
    # "Continue without changes". Confirm the state block did not shift it and
    # only the offered (remote) feature gets a status line.
    reset_route_state
    seed_script_dir "menu-state-continue-index"
    seed_env "" "none" ""
    GPU_TYPE="none"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    BOX_CAPTURE="$SCRIPT_DIR/menu-box"
    MENU_CHOICE="Continue without changes"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    MENU_BOX=$(cat "$BOX_CAPTURE")
    assert_eq "0" "$rc" "continue path returns 0 in PTY fixture state"
    assert_eq "continue" "$RECOVERY_MENU_ACTION" "PTY fixture state -> Continue at position 2 dispatches continue"
    assert_eq "Add remote access Continue without changes Wipe everything and start fresh Abort" "$MENU_OPTIONS" "PTY fixture state keeps Continue at position 2 (recovery-continue driver sends 2)"
    assert_contains "$MENU_BOX" "Remote access: not configured" "PTY fixture state shows offered remote feature state"
    if [[ "$MENU_BOX" == *"Hardware transcoding:"* ]]; then
        fail "no transcoding status line when GPU absent (not offered)" "$MENU_BOX"
    else
        pass "no transcoding status line when GPU absent (state shown only for offered features)"
    fi
    unset BOX_CAPTURE

    reset_route_state
    seed_script_dir "menu-transcoding-action"
    seed_env "ready" "none" "skipped"
    GPU_TYPE="amd"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Add hardware transcoding"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    assert_eq "0" "$rc" "transcoding menu action returns helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "transcoding menu action sets RECOVERY_MENU_ACTION=completed"
    assert_order_has "run_transcoding_recovery" "transcoding menu action dispatches to run_transcoding_recovery"
    if [[ "$MENU_OPTIONS" == *"Add remote access"* ]]; then
        fail "menu hides add remote when REMOTE_WEB_STATE=ready" "$MENU_OPTIONS"
    else
        pass "menu hides add remote when REMOTE_WEB_STATE=ready"
    fi

    reset_route_state
    seed_script_dir "menu-pending-reboot-action"
    seed_env "skipped" "none" "pending"
    GPU_TYPE=nvidia
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Reboot to finish hardware transcoding"
    stage3_pending_nvidia_reboot_same_boot() { return 0; }
    stage3_prompt_pending_nvidia_reboot() {
        record stage3_prompt_pending_nvidia_reboot
        return 0
    }
    print_final_summary() { record print_final_summary; }
    MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    assert_eq "0" "$rc" "pending NVIDIA reboot menu action returns 0"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "pending NVIDIA reboot menu action sets RECOVERY_MENU_ACTION=completed"
    assert_eq "reboot-pending" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "deferred reboot records 'reboot-pending', not a flat 'completed'"
    unset MEDIASTACK_LAUNCHER_RESULT
    assert_contains "$MENU_OPTIONS" "Reboot to finish hardware transcoding" "menu shows pending NVIDIA reboot action"
    assert_order_has "print_final_summary" "pending NVIDIA reboot action prints final summary"
    assert_order_has "stage3_prompt_pending_nvidia_reboot" "pending NVIDIA reboot action dispatches final reboot gate"
    eval "$PRODUCTION_STAGE3_PENDING_DEF"
    eval "$PRODUCTION_STAGE3_PROMPT_DEF"
    eval "$PRODUCTION_PRINT_FINAL_SUMMARY_DEF"

    reset_route_state
    seed_script_dir "menu-failed-action"
    seed_env "skipped" "none" "skipped"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Add remote access"
    REMOTE_RECOVERY_RC=33
    MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    assert_eq "33" "$rc" "failed add-stage menu action propagates helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "failed add-stage preserves RECOVERY_MENU_ACTION=completed"
    assert_eq "" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "failed sub-action writes NO token → launcher shows the real error"
    unset MEDIASTACK_LAUNCHER_RESULT REMOTE_RECOVERY_RC

    reset_route_state
    seed_script_dir "menu-continue-action"
    seed_env "ready" "none" "complete"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Continue without changes"
    MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    assert_eq "0" "$rc" "continue menu action returns 0"
    assert_eq "continue" "$RECOVERY_MENU_ACTION" "continue menu action sets RECOVERY_MENU_ACTION=continue"
    assert_eq "unchanged" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "continue records 'unchanged' for the launcher capstone"
    unset MEDIASTACK_LAUNCHER_RESULT

    reset_route_state
    seed_script_dir "menu-wipe-action"
    seed_env "ready" "none" "complete"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Wipe everything and start fresh"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    assert_eq "0" "$rc" "wipe menu action returns 0 for caller-owned wipe"
    assert_eq "wipe" "$RECOVERY_MENU_ACTION" "wipe menu action sets RECOVERY_MENU_ACTION=wipe"
    assert_order_lacks "nuke_existing_install" "wipe menu action does not call nuke_existing_install directly"

    reset_route_state
    seed_script_dir "menu-abort-action"
    seed_env "ready" "none" "complete"
    # shellcheck disable=SC2034 # read by the recovery menu dispatch in scripts/launcher/recovery.sh, sourced by the suite entry point
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Abort"
    MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
    show_existing_install_menu >/dev/null 2>&1
    rc=$?
    assert_eq "1" "$rc" "abort menu action returns non-zero"
    assert_eq "abort" "$RECOVERY_MENU_ACTION" "abort menu action sets RECOVERY_MENU_ACTION=abort"
    assert_eq "aborted" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "submenu Abort records 'aborted' for the launcher capstone"
    unset MEDIASTACK_LAUNCHER_RESULT
else
    skip "show_existing_install_menu action transport pending implementation"
fi

# ---------------------------------------------------------------------------
# setup.sh stops after existing-install menu outcomes.
# ---------------------------------------------------------------------------

run_wizard() {
    record run_wizard
    # shellcheck disable=SC2034 # read by the recovery menu dispatch in scripts/launcher/recovery.sh, sourced by the suite entry point
    WIZARD_RAN_INSTALL=true
}

eval "${PRODUCTION_DETECT_EXISTING_INSTALL_DEF/detect_existing_install/production_detect_existing_install}"
reset_route_state
seed_script_dir "main-existing-incomplete-stage1"
seed_env "skipped" "none" "skipped" ""
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
printf '{}\n' >"$SCRIPT_DIR/config/ddns-updater/config.json"
ui_choose() {
    record ui_choose
    printf '%s\n' "Use existing install"
}
detect_existing_install() {
    record detect_existing_install
    production_detect_existing_install
}
main >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "incomplete Stage 1 with existing-install evidence exits 0"
assert_order_has "storage_pause_watchdog_for_install" "incomplete Stage 1 pauses watchdog before resume"
assert_order_has "detect_existing_install" "incomplete Stage 1 checks existing-install evidence"
assert_order_has "run_wizard" "incomplete Stage 1 resumes wizard despite existing-install evidence"
assert_order_lacks "ui_choose" "incomplete Stage 1 bypasses existing-install menu"
assert_eq "false" "${EXISTING_INSTALL_DETECTED:-}" "incomplete Stage 1 does not set existing-install flag"

assert_main_existing_install_outcome() {
    local action="$1"
    local detect_rc="$2"
    local expected_rc="$3"
    local name="$4"

    reset_route_state
    seed_script_dir "main-existing-${name}"
    seed_env "ready" "none" "complete"
    MAIN_ACTION="$action"
    MAIN_RC="$detect_rc"
    detect_existing_install() {
        record detect_existing_install
        RECOVERY_MENU_ACTION="$MAIN_ACTION"
        return "$MAIN_RC"
    }

    main >/dev/null 2>&1
    rc=$?
    assert_eq "$expected_rc" "$rc" "main ${name} returns expected status"
    assert_order_has "detect_existing_install" "main ${name} reaches existing-install detection"
    assert_order_lacks "run_wizard" "main ${name} stops before run_wizard"
}

assert_main_existing_install_outcome "continue" "0" "0" "continue"
assert_main_existing_install_outcome "completed" "0" "0" "completed"
assert_main_existing_install_outcome "abort" "1" "1" "abort"
assert_main_existing_install_outcome "completed" "42" "42" "failed-add-stage"

reset_route_state
seed_script_dir "main-existing-wipe"
seed_env "ready" "none" "complete"
detect_existing_install() {
    record detect_existing_install
    RECOVERY_MENU_ACTION=""
    return 0
}
MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
main >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "main after successful wipe-cleared action continues setup"
assert_order_has "run_wizard" "main after successful wipe-cleared action reaches run_wizard"
assert_eq "completed" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "completed install records 'completed' so the strict launcher reports success"
unset MEDIASTACK_LAUNCHER_RESULT

# ---------------------------------------------------------------------------
# Launcher capstone honesty. The day-2 launcher runs setup.sh
# as a child and reads a one-word outcome token (MEDIASTACK_LAUNCHER_RESULT) so
# "user backed out" never renders as "completed successfully" and a deliberate
# abort never renders as an error. Here we drive the REAL recovery exit points
# (not the wholesale stubs above) and assert the token they leave behind. The
# `exit 0` paths run in a subshell so they don't tear down the test process.
# ---------------------------------------------------------------------------

# Non-DESTROY at the wipe guard must record 'aborted' (declined wipe), NOT leave
# the launcher to read the bare exit 0 as a successful destroy.
eval "${PRODUCTION_NUKE_DEF/nuke_existing_install/production_nuke_existing_install}"
reset_route_state
seed_script_dir "nuke-declined-destroy"
seed_env "ready" "none" "complete"
ui_input() { printf '%s\n' "destroy please"; }
MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
(production_nuke_existing_install) >/dev/null 2>&1
nuke_rc=$?
assert_eq "0" "$nuke_rc" "non-DESTROY wipe guard exits 0 (declined)"
assert_eq "aborted" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "declined wipe guard records 'aborted', not a false success"
assert_eq "yes" "$([[ -f "$SCRIPT_DIR/.env" ]] && echo yes || echo no)" "declined wipe guard preserves .env"
unset MEDIASTACK_LAUNCHER_RESULT

# Top-level "Abort" at the first three-way prompt must record 'aborted' too —
# it is a different function (detect_existing_install) with its own exit 0.
eval "${PRODUCTION_DETECT_EXISTING_INSTALL_DEF/detect_existing_install/production_detect_existing_install}"
reset_route_state
seed_script_dir "detect-toplevel-abort"
seed_env "ready" "none" "complete"
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
printf '{}\n' >"$SCRIPT_DIR/config/ddns-updater/config.json"
ui_choose() { printf '%s\n' "Abort"; }
MEDIASTACK_LAUNCHER_RESULT="$SCRIPT_DIR/launcher-result"
(production_detect_existing_install) >/dev/null 2>&1
detect_rc=$?
assert_eq "0" "$detect_rc" "top-level Abort exits 0"
assert_eq "aborted" "$(cat "$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null)" "top-level Abort records 'aborted' for the launcher capstone"
unset MEDIASTACK_LAUNCHER_RESULT

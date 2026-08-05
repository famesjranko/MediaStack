#!/usr/bin/env bash
# tests/unit/recovery-routing/remote.sh
#
# --remote requires Stage 1 and isolates to Stage 2; ready-state remote
# recovery is verify/heal, not Stage 2 collection.

# ---------------------------------------------------------------------------
# --remote requires Stage 1 and isolates to Stage 2.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "remote-no-env"
out=$(run_remote_recovery 2>&1)
rc=$?
if is_pending_helper run_remote_recovery; then
    # The current production surface still has inline `main --remote`; assert
    # the visible command contract there until scripts/setup/recovery.sh lands.
    reset_route_state
    seed_script_dir "main-remote-no-env"
    out=$(main --remote 2>&1)
    rc=$?
    assert_eq "1" "$rc" "--remote without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "--remote without .env tells user to run setup first"
else
    assert_eq "1" "$rc" "run_remote_recovery without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "run_remote_recovery without .env tells user to run setup first"
fi

reset_route_state
seed_script_dir "remote-incomplete-stage1"
seed_env "skipped" "none" "skipped" ""
out=$(run_remote_recovery 2>&1)
rc=$?
if is_pending_helper run_remote_recovery; then
    main --remote >/dev/null 2>&1
    rc=$?
    assert_eq "1" "$rc" "--remote with incomplete Stage 1 exits non-zero"
else
    assert_eq "1" "$rc" "run_remote_recovery with incomplete Stage 1 exits non-zero"
    assert_contains "$out" "Stage 1 is not complete" "incomplete Stage 1 tells user to finish setup first"
fi
assert_order_lacks "run_stage2" "incomplete Stage 1 remote recovery does not call Stage 2"

reset_route_state
seed_script_dir "remote-skipped"
seed_env "skipped"
if is_pending_helper run_remote_recovery; then
    main --remote >/dev/null 2>&1
else
    run_remote_recovery >/dev/null 2>&1
fi
assert_order_has "run_stage2" "skipped remote recovery calls Stage 2"
assert_order_lacks "run_stage1" "skipped remote recovery does not call Stage 1"
assert_order_lacks "run_stage3" "skipped remote recovery does not call Stage 3"
assert_order_lacks "run_wizard" "skipped remote recovery does not call wizard"
assert_order_lacks "start_stack" "skipped remote recovery does not run legacy stack install"

# ---------------------------------------------------------------------------
# Ready-state remote recovery is verify/heal, not Stage 2 collection.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "remote-ready"
seed_env "ready"
if is_pending_helper run_remote_recovery; then
    skip "ready-state run_remote_recovery verify/heal path pending scripts/setup/recovery.sh"
    skip "ready-state recovery keeps MEDIASTACK_NPM_ATTEMPT_REMOTE unset pending scripts/setup/recovery.sh"
    skip "ready-state recovery preserves REMOTE_WEB_STATE=ready pending scripts/setup/recovery.sh"
else
    run_remote_recovery >/dev/null 2>&1
    assert_order_lacks "run_stage2" "ready-state remote recovery does not call Stage 2"
    assert_contains "$(order_text)" "repair_ddns_updater_config_permissions pull_images start_stack" "AUDIT: ready-state recovery repairs DDNS config before stack start"
    assert_order_has "pull_images" "ready-state remote recovery uses heal path"
    assert_order_has "print_access_info" "ready-state remote recovery prints access info"
    configure_args="$(configure_args_from "$SCRIPT_DIR")"
    assert_eq "--only npm,jellyfin,homepage,ddns-updater,wireguard" "$configure_args" "ready-state recovery runs exact scoped remote configure services"
    assert_eq "" "${MEDIASTACK_NPM_ATTEMPT_REMOTE:-}" "ready-state recovery does not set MEDIASTACK_NPM_ATTEMPT_REMOTE"
    assert_eq "ready" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "ready-state recovery preserves REMOTE_WEB_STATE=ready"

    reset_route_state
    seed_script_dir "remote-ready-ddns-repair-fails"
    seed_env "ready"
    repair_ddns_updater_config_permissions() {
        record repair_ddns_updater_config_permissions
        return 1
    }
    run_remote_recovery >/dev/null 2>&1
    ready_repair_rc=$?
    assert_eq "1" "$ready_repair_rc" "AUDIT: ready-state recovery returns failure when DDNS repair fails"
    assert_order_has "repair_ddns_updater_config_permissions" "AUDIT: ready-state recovery attempts DDNS repair"
    assert_order_lacks "pull_images" "AUDIT: failed ready-state DDNS repair aborts before pull_images"
    assert_order_lacks "start_stack" "AUDIT: failed ready-state DDNS repair aborts before start_stack"
    assert_eq "" "$(configure_args_from "$SCRIPT_DIR")" "AUDIT: failed ready-state DDNS repair aborts before remote configure"

    eval "$PRODUCTION_REPAIR_DDNS_DEF"
    reset_route_state
    seed_script_dir "remote-ready-ddns-real-symlink"
    seed_env "ready"
    mkdir -p "$SCRIPT_DIR/config" "$TMP_ROOT/ready-ddns-real-target"
    ln -s "$TMP_ROOT/ready-ddns-real-target" "$SCRIPT_DIR/config/ddns-updater"
    run_remote_recovery >/dev/null 2>&1
    ready_repair_real_rc=$?
    assert_eq "1" "$ready_repair_real_rc" "AUDIT: ready-state recovery returns failure for real symlinked DDNS dir"
    assert_order_has "log_warn" "AUDIT: real DDNS repair rejects symlinked config dir"
    assert_order_lacks "pull_images" "AUDIT: real symlinked DDNS dir aborts before pull_images"
    assert_order_lacks "start_stack" "AUDIT: real symlinked DDNS dir aborts before start_stack"
    assert_eq "" "$(configure_args_from "$SCRIPT_DIR")" "AUDIT: real symlinked DDNS dir aborts before remote configure"
    assert_eq "no" "$([[ -f "$TMP_ROOT/ready-ddns-real-target/config.json" ]] && echo yes || echo no)" "AUDIT: real ready-state repair does not write through symlinked DDNS dir"
    repair_ddns_updater_config_permissions() { record repair_ddns_updater_config_permissions; }
fi

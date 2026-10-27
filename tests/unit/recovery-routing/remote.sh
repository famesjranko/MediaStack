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
    assert_contains "$out" "Choose Install MediaStack in ./mediastack first" "--remote without .env tells user to run setup first"
else
    assert_eq "1" "$rc" "run_remote_recovery without .env exits non-zero"
    assert_contains "$out" "Choose Install MediaStack in ./mediastack first" "run_remote_recovery without .env tells user to run setup first"
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

# ---------------------------------------------------------------------------
# run_wireguard_recovery: opt-in WireGuard on a ready-HTTPS install.
# Prompts are scripted, and effects land in files so a killed (cancelled)
# subshell still leaves a record to assert on.
# ---------------------------------------------------------------------------

WG_STUBBED_FNS=(ui_confirm ui_input_validated ui_choose net_detect_lan_cidr pull_images start_stack
    setup_ufw_wireguard_clients setup_ufw_service_ports service_container_running)
WG_SAVED_DEFS=()
for _wg_fn in "${WG_STUBBED_FNS[@]}"; do
    WG_SAVED_DEFS+=("$(declare -f "$_wg_fn" 2>/dev/null)")
done

wg_effect() { printf '%s\n' "$1" >>"$WG_EFFECTS"; }
wg_hit() {
    local n
    printf '%s\n' "$1" >>"$WG_PROMPTS"
    n=$(wc -l <"$WG_PROMPTS")
    ((n == ${WG_CANCEL_AT:-0})) && kill -KILL "$WG_MAIN_PID"
    ((n != ${WG_DECLINE_AT:-0}))
}
ui_confirm() { wg_hit confirm; }
ui_input_validated() {
    wg_hit input
    echo "$2"
}
ui_choose() {
    wg_hit choose
    echo "${WG_TIER_LABEL:-$2}"
}
net_detect_lan_cidr() { echo "192.168.1.0/24"; }
pull_images() {
    wg_effect pull_images
    [[ -z "${WG_PULL_FAIL:-}" ]]
}
start_stack() { wg_effect start_stack; }
setup_ufw_wireguard_clients() { wg_effect setup_ufw_wireguard_clients; }
setup_ufw_service_ports() { wg_effect setup_ufw_service_ports; }
# wg-easy counts as running only when a case sets WG_RUNNING.
service_container_running() { [[ "$1" == wireguard && -n "${WG_RUNNING:-}" ]]; }

# Given a completed install; $2 is REMOTE_WEB_STATE and $3 the WG_INIT_PASSWORD.
wg_seed() {
    seed_script_dir "$1"
    cat >"$SCRIPT_DIR/.env" <<ENV
STAGE_1_COMPLETE=1
REMOTE_WEB_STATE=$2
DOMAIN=gate.test
HOST_ADDRESS=192.168.1.10
JELLYFIN_ADMIN_USER=admin
JELLYFIN_ADMIN_PASSWORD='S3cret!pass'
NPM_ADMIN_EMAIL=admin@gate.test
SONARR_API_KEY=keep-me
WG_HOST=example.com
WG_PORT=51820
WG_INIT_PASSWORD='$3'
WG_ACCESS_TIER=full-lan
ENV
    chmod 600 "$SCRIPT_DIR/.env"
    printf 'quality_profile:\n  name: hd\n' >"$SCRIPT_DIR/config.yml"
}
wg_fingerprint() { (cd "$SCRIPT_DIR" && sha256sum .env config.yml && stat -c '%a' .env); }
wg_run() {
    WG_PROMPTS="$TMP_ROOT/wg-prompts"
    WG_EFFECTS="$TMP_ROOT/wg-effects"
    WG_RESULT="$TMP_ROOT/wg-result"
    : >"$WG_PROMPTS"
    : >"$WG_EFFECTS"
    : >"$WG_RESULT"
    export MEDIASTACK_LAUNCHER_RESULT="$WG_RESULT"
    (
        WG_MAIN_PID=$BASHPID
        run_wireguard_recovery
    ) >"$TMP_ROOT/wg-out" 2>&1
    WG_RC=$?
    unset MEDIASTACK_LAUNCHER_RESULT
}
wg_effects_text() { tr '\n' ' ' <"$WG_EFFECTS"; }

if ! type run_wireguard_recovery >/dev/null 2>&1; then
    fail "run_wireguard_recovery is defined by scripts/setup/recovery.sh"
else
    # Given HTTPS is ready and WireGuard is absent, and the user declines or
    # cancels at each of the five full-LAN prompts
    # When the add-WireGuard action runs
    # Then .env, config.yml and the file mode are byte-identical and no stack or firewall step ran
    for wg_case in decline:1 cancel:2 cancel:3 cancel:4 decline:5; do
        reset_route_state
        wg_seed "wg-stop-${wg_case/:/-}" ready ""
        wg_before=$(wg_fingerprint)
        WG_CANCEL_AT=0 WG_DECLINE_AT=0
        if [[ "${wg_case%%:*}" == "cancel" ]]; then WG_CANCEL_AT="${wg_case##*:}"; else WG_DECLINE_AT="${wg_case##*:}"; fi
        wg_run
        assert_eq "$wg_before" "$(wg_fingerprint)" "WireGuard add: ${wg_case/:/ at prompt } leaves .env and config.yml byte-identical"
        assert_eq "" "$(wg_effects_text)" "WireGuard add: ${wg_case/:/ at prompt } runs no stack or firewall step"
        assert_eq "" "$(configure_args_from "$SCRIPT_DIR")" "WireGuard add: ${wg_case/:/ at prompt } runs no configure step"
    done
    WG_CANCEL_AT=0 WG_DECLINE_AT=0

    # Given HTTPS is ready, WireGuard is absent and the user accepts the server-only tier
    # When the add-WireGuard action runs
    # Then only the WG_ keys change, the stack and firewall steps run, and the outcome is completed
    reset_route_state
    wg_seed "wg-accept" ready ""
    grep -v '^WG_' "$SCRIPT_DIR/.env" >"$TMP_ROOT/wg-nonwg-before"
    WG_TIER_LABEL="Server only - reach this MediaStack box (all ports, including SSH)"
    wg_run
    unset WG_TIER_LABEL
    assert_eq "0" "$WG_RC" "WireGuard add: accepting exits 0"
    grep -v '^WG_' "$SCRIPT_DIR/.env" >"$TMP_ROOT/wg-nonwg-after"
    assert_eq "$(cat "$TMP_ROOT/wg-nonwg-before")" "$(cat "$TMP_ROOT/wg-nonwg-after")" "WireGuard add: HTTPS, domain and every credential line outside WG_ stay unchanged"
    assert_eq "S3cret!pass" "$(env_val_from "$SCRIPT_DIR/.env" WG_INIT_PASSWORD | tr -d "'")" "WireGuard add: WG_INIT_PASSWORD takes the admin password"
    assert_eq "server" "$(env_val_from "$SCRIPT_DIR/.env" WG_ACCESS_TIER | tr -d "'")" "WireGuard add: selected access tier is saved"
    assert_eq "gate.test" "$(env_val_from "$SCRIPT_DIR/.env" WG_HOST | tr -d "'")" "WireGuard add: endpoint follows the ready domain"
    assert_eq "ready" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "WireGuard add: REMOTE_WEB_STATE stays ready"
    assert_eq "600" "$(stat -c '%a' "$SCRIPT_DIR/.env")" "WireGuard add: .env keeps mode 600"
    assert_eq "setup_ufw_wireguard_clients setup_ufw_service_ports pull_images start_stack " "$(wg_effects_text)" "WireGuard add: firewall rules converge, then the stack starts"
    assert_eq "--only npm,jellyfin,homepage,ddns-updater,wireguard" "$(configure_args_from "$SCRIPT_DIR")" "WireGuard add: reuses the ready-state configure scope"
    assert_eq "completed" "$(cat "$WG_RESULT")" "WireGuard add: reports the completed outcome"

    # Given WireGuard is already configured and wg-easy is running
    # When the add-WireGuard action runs
    # Then no prompt, stack, firewall or heal step runs and .env is unchanged
    reset_route_state
    wg_seed "wg-configured" ready "S3cret!pass"
    wg_before=$(wg_fingerprint)
    WG_RUNNING=1 wg_run
    assert_eq "0" "$WG_RC" "WireGuard add: an already-configured install exits 0"
    assert_eq "$wg_before" "$(wg_fingerprint)" "WireGuard add: an already-configured install keeps .env and config.yml byte-identical"
    assert_eq "" "$(cat "$WG_PROMPTS")$(wg_effects_text)" "WireGuard add: an already-configured install asks nothing and changes nothing"
    assert_order_lacks "pull_images" "WireGuard add: a running wg-easy runs no heal step"
    assert_eq "" "$(configure_args_from "$SCRIPT_DIR")" "WireGuard add: a running wg-easy runs no configure step"
    assert_eq "unchanged" "$(cat "$WG_RESULT")" "WireGuard add: an already-configured install reports unchanged"

    # Given the WireGuard settings are saved but wg-easy is not running
    # When the add-WireGuard action runs
    # Then it asks nothing, keeps .env, runs the heal steps and reports completed
    reset_route_state
    wg_seed "wg-saved-not-running" ready "S3cret!pass"
    wg_before=$(wg_fingerprint)
    log_info() { echo "$*"; }
    wg_run
    log_info() { record log_info; }
    assert_eq "0" "$WG_RC" "WireGuard add: saved settings with wg-easy stopped exit 0"
    assert_contains "$(cat "$TMP_ROOT/wg-out")" "wg-easy is not running; starting it now" "WireGuard add: saved settings with wg-easy stopped say it is starting"
    assert_eq "$wg_before" "$(wg_fingerprint)" "WireGuard add: saved settings with wg-easy stopped keep .env and config.yml byte-identical"
    assert_eq "" "$(cat "$WG_PROMPTS")" "WireGuard add: saved settings with wg-easy stopped ask nothing"
    assert_eq "pull_images start_stack " "$(wg_effects_text)" "WireGuard add: saved settings with wg-easy stopped run the heal steps"
    assert_eq "--only npm,jellyfin,homepage,ddns-updater,wireguard" "$(configure_args_from "$SCRIPT_DIR")" "WireGuard add: saved settings with wg-easy stopped reuse the ready-state configure scope"
    assert_eq "completed" "$(cat "$WG_RESULT")" "WireGuard add: saved settings with wg-easy stopped report completed"

    # Given the settings are saved, wg-easy is not running and the stack start fails
    # When the add-WireGuard action runs
    # Then it reports failed with a non-zero status and says the settings are saved but not started
    reset_route_state
    wg_seed "wg-saved-start-fails" ready "S3cret!pass"
    start_stack() {
        wg_effect start_stack
        return 1
    }
    wg_run
    start_stack() { wg_effect start_stack; }
    assert_eq "1" "$WG_RC" "WireGuard add: a failed stack start on heal returns non-zero"
    assert_eq "failed" "$(cat "$WG_RESULT")" "WireGuard add: a failed stack start on heal reports the failed outcome"
    assert_contains "$(cat "$TMP_ROOT/wg-out")" "saved but the stack did not finish starting" "WireGuard add: a failed stack start on heal warns that settings are saved but not started"

    # Given remote access is not ready
    # When the add-WireGuard action runs
    # Then it refuses, points at Add remote access and changes nothing
    reset_route_state
    wg_seed "wg-not-ready" skipped ""
    wg_before=$(wg_fingerprint)
    wg_run
    assert_eq "1" "$WG_RC" "WireGuard add: refused when remote access is not ready"
    assert_contains "$(cat "$TMP_ROOT/wg-out")" "Add remote access" "WireGuard add: not-ready refusal names Add remote access"
    assert_eq "$wg_before" "$(wg_fingerprint)" "WireGuard add: not-ready refusal leaves .env unchanged"
    assert_eq "" "$(cat "$WG_PROMPTS")$(wg_effects_text)" "WireGuard add: not-ready refusal asks nothing"

    # Given the real opt-in prompt and an input of end of file or a bare Enter
    # When the add-WireGuard action runs
    # Then the prompt defaults to no, .env and config.yml stay byte-identical and nothing starts
    eval "${WG_SAVED_DEFS[0]}"
    for wg_input in eof enter; do
        reset_route_state
        wg_seed "wg-optin-$wg_input" ready ""
        wg_before=$(wg_fingerprint)
        wg_run < <([[ "$wg_input" == "enter" ]] && printf '\n' || true)
        assert_eq "0" "$WG_RC" "WireGuard add: $wg_input at the opt-in prompt exits 0"
        assert_eq "$wg_before" "$(wg_fingerprint)" "WireGuard add: $wg_input at the opt-in prompt leaves .env and config.yml byte-identical"
        assert_eq "" "$(wg_effects_text)" "WireGuard add: $wg_input at the opt-in prompt runs no stack or firewall step"
        assert_eq "unchanged" "$(cat "$WG_RESULT")" "WireGuard add: $wg_input at the opt-in prompt reports unchanged"
    done
    ui_confirm() { wg_hit confirm; }

    # Given the user accepts but the image pull fails
    # When the add-WireGuard action runs
    # Then it reports failed with a non-zero status and says the settings are saved but not started
    reset_route_state
    wg_seed "wg-pull-fails" ready ""
    WG_PULL_FAIL=1
    wg_run
    unset WG_PULL_FAIL
    assert_eq "1" "$WG_RC" "WireGuard add: a failed image pull returns non-zero"
    assert_eq "failed" "$(cat "$WG_RESULT")" "WireGuard add: a failed image pull reports the failed outcome"
    assert_contains "$(cat "$TMP_ROOT/wg-out")" "saved but the stack did not finish starting" "WireGuard add: a failed image pull warns that settings are saved but not started"
    assert_eq "setup_ufw_wireguard_clients setup_ufw_service_ports pull_images " "$(wg_effects_text)" "WireGuard add: a failed image pull stops before the stack starts"
fi

for _wg_fn in "${WG_STUBBED_FNS[@]}"; do unset -f "$_wg_fn"; done
for _wg_def in "${WG_SAVED_DEFS[@]}"; do [[ -z "$_wg_def" ]] || eval "$_wg_def"; done

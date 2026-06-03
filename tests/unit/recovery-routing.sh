#!/usr/bin/env bash
# tests/unit/recovery-routing.sh
#
# Contract tests for recovery routing and stage re-entry.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="recovery-routing"
scenario_begin "$CURRENT_SCENARIO"

# Source setup.sh first so future recovery helpers loaded by setup.sh are tested
# in the same environment the real entrypoint uses.
source "$REPO_ROOT/setup.sh"

# setup.sh enables strict mode; unit assertions need to continue after expected
# non-zero branches.
set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

ORDER=()
CONFIGURE_ENV=()

record() {
    ORDER+=("$1")
}

order_text() {
    printf '%s ' "${ORDER[@]}"
}

reset_route_state() {
    ORDER=()
    CONFIGURE_ENV=()
    unset STAGE_1_COMPLETE REMOTE_WEB_STATE JELLYFIN_GPU
    unset STAGE_3_GPU_STATE STAGE_3_GPU_VENDOR STAGE_3_GPU_ENCODER
    unset MEDIASTACK_NPM_ATTEMPT_REMOTE
    unset WIZARD_RAN_INSTALL RECOVERY_MENU_ACTION EXISTING_INSTALL_DETECTED
}

seed_script_dir() {
    local name="$1"
    SCRIPT_DIR="$TMP_ROOT/$name"
    mkdir -p "$SCRIPT_DIR/scripts"
    cat > "$SCRIPT_DIR/scripts/configure.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> configure.args
printf 'configure:%s\n' "$*"
SH
    chmod +x "$SCRIPT_DIR/scripts/configure.sh"
}

seed_env() {
    local remote_state="$1"
    local gpu="${2:-none}"
    local stage3_state="${3:-skipped}"
    local stage1_complete="${4-1}"
    cat > "$SCRIPT_DIR/.env" <<ENV
STAGE_1_COMPLETE=${stage1_complete}
REMOTE_WEB_STATE=${remote_state}
JELLYFIN_GPU=${gpu}
STAGE_3_GPU_STATE=${stage3_state}
STAGE_3_GPU_VENDOR=
STAGE_3_GPU_ENCODER=
ENV
    chmod 600 "$SCRIPT_DIR/.env"
}

env_val_from() {
    local env_path="$1"
    local key="$2"
    awk -F= -v key="$key" '$1 == key {print $2; exit}' "$env_path" 2>/dev/null
}

configure_args_from() {
    local script_dir="$1"
    [[ -f "$script_dir/configure.args" ]] || return 0
    cat "$script_dir/configure.args"
}

assert_order_has() {
    local token="$1"
    local name="$2"
    if [[ " $(order_text) " == *" $token "* ]]; then
        pass "$name"
    else
        fail "$name" "order: $(order_text)"
    fi
}

assert_order_lacks() {
    local token="$1"
    local name="$2"
    if [[ " $(order_text) " == *" $token "* ]]; then
        fail "$name" "order: $(order_text)"
    else
        pass "$name"
    fi
}

is_pending_helper() {
    local fn="$1"
    [[ "$(declare -f "$fn" 2>/dev/null)" == *"__not_implemented__"* ]]
}

__not_implemented__() {
    printf '__not_implemented__:%s\n' "${1:-recovery-helper}"
    return 127
}

if ! type run_remote_recovery >/dev/null 2>&1; then
    run_remote_recovery() { __not_implemented__ run_remote_recovery; }
fi
if ! type run_transcoding_recovery >/dev/null 2>&1; then
    run_transcoding_recovery() { __not_implemented__ run_transcoding_recovery; }
fi
if ! type recovery_menu_remote_available >/dev/null 2>&1; then
    recovery_menu_remote_available() { __not_implemented__ recovery_menu_remote_available; }
fi
if ! type recovery_menu_transcoding_available >/dev/null 2>&1; then
    recovery_menu_transcoding_available() { __not_implemented__ recovery_menu_transcoding_available; }
fi
if ! type show_existing_install_menu >/dev/null 2>&1; then
    show_existing_install_menu() { __not_implemented__ show_existing_install_menu; }
fi

PRODUCTION_DETECT_EXISTING_INSTALL_DEF=$(declare -f detect_existing_install)
PRODUCTION_REPAIR_DDNS_DEF=$(declare -f repair_ddns_updater_config_permissions)
PRODUCTION_STAGE3_PENDING_DEF=$(declare -f stage3_pending_nvidia_reboot_same_boot)
PRODUCTION_STAGE3_PROMPT_DEF=$(declare -f stage3_prompt_pending_nvidia_reboot)
PRODUCTION_PRINT_FINAL_SUMMARY_DEF=$(declare -f print_final_summary)

# Side-effect stubs. Route tests assert these tokens rather than grepping only
# source strings.
ui_banner() { record ui_banner; }
log_warn() { printf '%s\n' "$1"; record log_warn; }
log_info() { record log_info; }
log_ok() { record log_ok; }
log_error() { printf '%s\n' "$1"; record log_error; }
check_not_root() { record check_not_root; }
check_debian() { record check_debian; }
check_docker() { record check_docker; }
check_compose() { record check_compose; }
check_internet_reachability() { record check_internet_reachability; }
prompt_sudo_cache() { record prompt_sudo_cache; }
detect_env() { record detect_env; }
_wizard_load_existing_env() { record _wizard_load_existing_env; }
run_stage1() { record run_stage1; }
run_stage2() { record run_stage2; }
run_stage3() { record run_stage3; }
run_wizard() { record run_wizard; }
pull_images() { record pull_images; }
repair_ddns_updater_config_permissions() { record repair_ddns_updater_config_permissions; }
start_stack() { record start_stack; }
wait_all_healthy() { record wait_all_healthy; }
stash_gpu_type() { record stash_gpu_type; GPU_TYPE="${GPU_TYPE:-intel}"; }
detect_existing_install() { record detect_existing_install; }
stop_existing_stack() { record stop_existing_stack; }
create_data_dirs() { record create_data_dirs; }
create_config_dirs() { record create_config_dirs; }
generate_override() { record generate_override; }
print_access_info() { record print_access_info; }
cleanup_post_reboot() { record cleanup_post_reboot; }
write_setup_result() { record "write_setup_result:$1"; }
detect_host_memory() { record detect_host_memory; }
setup_hardening() { record setup_hardening; }
setup_ufw_service_ports() { record setup_ufw_service_ports; }
setup_samba() { record setup_samba; }
storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; }
python3() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "import yaml" ]]; then
        return 0
    fi
    command python3 "$@"
}

# ---------------------------------------------------------------------------
# REC-01: --remote requires Stage 1 and isolates to Stage 2.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "remote-no-env"
out=$(run_remote_recovery 2>&1); rc=$?
if is_pending_helper run_remote_recovery; then
    # The current production surface still has inline `main --remote`; assert
    # the visible command contract there until scripts/setup/recovery.sh lands.
    reset_route_state
    seed_script_dir "main-remote-no-env"
    out=$(main --remote 2>&1); rc=$?
    assert_eq "1" "$rc" "REC-01: --remote without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "REC-01: --remote without .env tells user to run setup first"
else
    assert_eq "1" "$rc" "REC-01: run_remote_recovery without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "REC-01: run_remote_recovery without .env tells user to run setup first"
fi

reset_route_state
seed_script_dir "remote-incomplete-stage1"
seed_env "skipped" "none" "skipped" ""
out=$(run_remote_recovery 2>&1); rc=$?
if is_pending_helper run_remote_recovery; then
    main --remote >/dev/null 2>&1
    rc=$?
    assert_eq "1" "$rc" "REC-01: --remote with incomplete Stage 1 exits non-zero"
else
    assert_eq "1" "$rc" "REC-01: run_remote_recovery with incomplete Stage 1 exits non-zero"
    assert_contains "$out" "Stage 1 is not complete" "REC-01: incomplete Stage 1 tells user to finish setup first"
fi
assert_order_lacks "run_stage2" "REC-01: incomplete Stage 1 remote recovery does not call Stage 2"

reset_route_state
seed_script_dir "remote-skipped"
seed_env "skipped"
if is_pending_helper run_remote_recovery; then
    main --remote >/dev/null 2>&1
else
    run_remote_recovery >/dev/null 2>&1
fi
assert_order_has "run_stage2" "REC-01: skipped remote recovery calls Stage 2"
assert_order_lacks "run_stage1" "REC-01: skipped remote recovery does not call Stage 1"
assert_order_lacks "run_stage3" "REC-01: skipped remote recovery does not call Stage 3"
assert_order_lacks "run_wizard" "REC-01: skipped remote recovery does not call wizard"
assert_order_lacks "start_stack" "REC-01: skipped remote recovery does not run legacy stack install"

# ---------------------------------------------------------------------------
# REC-02: ready-state remote recovery is verify/heal, not Stage 2 collection.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "remote-ready"
seed_env "ready"
if is_pending_helper run_remote_recovery; then
    skip "REC-02: ready-state run_remote_recovery verify/heal path pending scripts/setup/recovery.sh"
    skip "REC-02: ready-state recovery keeps MEDIASTACK_NPM_ATTEMPT_REMOTE unset pending scripts/setup/recovery.sh"
    skip "REC-02: ready-state recovery preserves REMOTE_WEB_STATE=ready pending scripts/setup/recovery.sh"
else
    run_remote_recovery >/dev/null 2>&1
    assert_order_lacks "run_stage2" "REC-02: ready-state remote recovery does not call Stage 2"
    assert_contains "$(order_text)" "repair_ddns_updater_config_permissions pull_images start_stack" "AUDIT: ready-state recovery repairs DDNS config before stack start"
    assert_order_has "pull_images" "REC-02: ready-state remote recovery uses heal path"
    assert_order_has "print_access_info" "REC-02: ready-state remote recovery prints access info"
    configure_args="$(configure_args_from "$SCRIPT_DIR")"
    assert_eq "--only npm,jellyfin,homepage,ddns-updater,wireguard" "$configure_args" "REC-02: ready-state recovery runs exact scoped remote configure services"
    assert_eq "" "${MEDIASTACK_NPM_ATTEMPT_REMOTE:-}" "REC-02: ready-state recovery does not set MEDIASTACK_NPM_ATTEMPT_REMOTE"
    assert_eq "ready" "$(env_val_from "$SCRIPT_DIR/.env" REMOTE_WEB_STATE)" "REC-02: ready-state recovery preserves REMOTE_WEB_STATE=ready"

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
# REC-03: --transcoding requires Stage 1 and isolates to Stage 3.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "transcoding-no-env"
out=$(run_transcoding_recovery 2>&1); rc=$?
if is_pending_helper run_transcoding_recovery; then
    skip "REC-03: run_transcoding_recovery .env precondition pending implementation"
else
    assert_eq "1" "$rc" "REC-03: --transcoding without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "REC-03: --transcoding without .env tells user to run setup first"
fi

reset_route_state
seed_script_dir "transcoding-stage3"
seed_env "skipped" "none" "skipped"
GPU_TYPE="intel"
if is_pending_helper run_transcoding_recovery; then
    skip "REC-03: run_transcoding_recovery route isolation pending implementation"
else
    run_transcoding_recovery >/dev/null 2>&1
    assert_order_has "stash_gpu_type" "REC-03: transcoding recovery re-detects GPU"
    assert_order_has "run_stage3" "REC-03: transcoding recovery calls Stage 3"
    assert_order_lacks "run_stage1" "REC-03: transcoding recovery does not call Stage 1"
    assert_order_lacks "run_stage2" "REC-03: transcoding recovery does not call Stage 2"
fi

# ---------------------------------------------------------------------------
# REC-04: existing-install recovery menu is contextual and non-destructive.
# ---------------------------------------------------------------------------

reset_route_state
seed_script_dir "menu-context"
seed_env "unchecked" "intel" "skipped"
set -a
source "$SCRIPT_DIR/.env"
set +a
GPU_TYPE="intel"
if is_pending_helper recovery_menu_remote_available || is_pending_helper recovery_menu_transcoding_available; then
    skip "REC-04: contextual existing-install menu availability pending implementation"
else
    recovery_menu_remote_available; remote_rc=$?
    recovery_menu_transcoding_available; transcoding_rc=$?
    assert_eq "0" "$remote_rc" "REC-04: menu includes remote retry for REMOTE_WEB_STATE=unchecked"
    assert_eq "0" "$transcoding_rc" "REC-04: menu includes transcoding when GPU is present and Stage 3 is not complete"

    REMOTE_WEB_STATE=ready
    recovery_menu_remote_available; remote_ready_rc=$?
    assert_eq "1" "$remote_ready_rc" "REC-04: menu hides remote retry for REMOTE_WEB_STATE=ready"

    REMOTE_WEB_STATE=failed
    recovery_menu_remote_available; remote_failed_rc=$?
    assert_eq "0" "$remote_failed_rc" "REC-04: menu includes remote retry for REMOTE_WEB_STATE=failed"

    GPU_TYPE=none
    STAGE_3_GPU_STATE=skipped
    recovery_menu_transcoding_available; no_gpu_rc=$?
    assert_eq "1" "$no_gpu_rc" "REC-04: menu hides transcoding when no GPU is detected"

    GPU_TYPE=intel
    STAGE_3_GPU_STATE=complete
    recovery_menu_transcoding_available; complete_rc=$?
    assert_eq "1" "$complete_rc" "REC-04: menu hides transcoding when Stage 3 is complete"
fi

checks_source="$(sed -n '1,760p' "$REPO_ROOT/scripts/setup/checks.sh")"
assert_contains "$checks_source" "Wipe everything and start fresh" "REC-04: destructive wipe copy remains present"
assert_contains "$checks_source" "nuke_existing_install" "REC-04: destructive wipe delegates to nuke_existing_install"

if [[ -f "$REPO_ROOT/scripts/setup/recovery.sh" ]]; then
    recovery_source="$(sed -n '1,760p' "$REPO_ROOT/scripts/setup/recovery.sh")"
    if [[ "$recovery_source" == *"docker compose"*"down -v"* ]]; then
        fail "REC-04: recovery menu does not invoke docker compose down -v directly"
    else
        pass "REC-04: recovery menu does not invoke docker compose down -v directly"
    fi
else
    skip "REC-04: recovery menu direct-destroy check pending scripts/setup/recovery.sh"
fi

if ! is_pending_helper show_existing_install_menu; then
    ui_box() { record ui_box; }
    ui_choose() {
        MENU_PROMPT="$1"
        shift
        printf '%s\n' "$*" > "$MENU_CAPTURE"
        printf '%s\n' "$MENU_CHOICE"
    }
    run_remote_recovery() { record run_remote_recovery; return "${REMOTE_RECOVERY_RC:-0}"; }
    run_transcoding_recovery() { record run_transcoding_recovery; return "${TRANSCODING_RECOVERY_RC:-0}"; }
    nuke_existing_install() { record nuke_existing_install; return 0; }

    reset_route_state
    seed_script_dir "menu-remote-action"
    seed_env "unchecked" "none" "skipped"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Retry remote access"
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    assert_eq "0" "$rc" "REC-04: remote menu action returns helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "REC-04: remote menu action sets RECOVERY_MENU_ACTION=completed"
    assert_order_has "run_remote_recovery" "REC-04: remote menu action dispatches to run_remote_recovery"
    assert_order_lacks "nuke_existing_install" "REC-04: remote menu action does not wipe"
    assert_contains "$MENU_OPTIONS" "Retry remote access" "REC-04: menu shows retry remote when unchecked"
    assert_contains "$MENU_OPTIONS" "Configure hardware transcoding" "REC-04: menu shows transcoding when GPU is fresh"

    reset_route_state
    seed_script_dir "menu-transcoding-action"
    seed_env "ready" "none" "skipped"
    GPU_TYPE="amd"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Configure hardware transcoding"
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    assert_eq "0" "$rc" "REC-04: transcoding menu action returns helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "REC-04: transcoding menu action sets RECOVERY_MENU_ACTION=completed"
    assert_order_has "run_transcoding_recovery" "REC-04: transcoding menu action dispatches to run_transcoding_recovery"
    if [[ "$MENU_OPTIONS" == *"Retry remote access"* ]]; then
        fail "REC-04: menu hides retry remote when REMOTE_WEB_STATE=ready" "$MENU_OPTIONS"
    else
        pass "REC-04: menu hides retry remote when REMOTE_WEB_STATE=ready"
    fi

    reset_route_state
    seed_script_dir "menu-pending-reboot-action"
    seed_env "skipped" "none" "pending"
    GPU_TYPE=nvidia
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Reboot to finish hardware transcoding"
    stage3_pending_nvidia_reboot_same_boot() { return 0; }
    stage3_prompt_pending_nvidia_reboot() { record stage3_prompt_pending_nvidia_reboot; return 0; }
    print_final_summary() { record print_final_summary; }
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    MENU_OPTIONS=$(cat "$MENU_CAPTURE")
    assert_eq "0" "$rc" "REC-04: pending NVIDIA reboot menu action returns 0"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "REC-04: pending NVIDIA reboot menu action sets RECOVERY_MENU_ACTION=completed"
    assert_contains "$MENU_OPTIONS" "Reboot to finish hardware transcoding" "REC-04: menu shows pending NVIDIA reboot action"
    assert_order_has "print_final_summary" "REC-04: pending NVIDIA reboot action prints final summary"
    assert_order_has "stage3_prompt_pending_nvidia_reboot" "REC-04: pending NVIDIA reboot action dispatches final reboot gate"
    eval "$PRODUCTION_STAGE3_PENDING_DEF"
    eval "$PRODUCTION_STAGE3_PROMPT_DEF"
    eval "$PRODUCTION_PRINT_FINAL_SUMMARY_DEF"

    reset_route_state
    seed_script_dir "menu-failed-action"
    seed_env "skipped" "none" "skipped"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Retry remote access"
    REMOTE_RECOVERY_RC=33
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    assert_eq "33" "$rc" "REC-04: failed add-stage menu action propagates helper status"
    assert_eq "completed" "$RECOVERY_MENU_ACTION" "REC-04: failed add-stage preserves RECOVERY_MENU_ACTION=completed"
    unset REMOTE_RECOVERY_RC

    reset_route_state
    seed_script_dir "menu-continue-action"
    seed_env "ready" "none" "complete"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Continue without changes"
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    assert_eq "0" "$rc" "REC-04: continue menu action returns 0"
    assert_eq "continue" "$RECOVERY_MENU_ACTION" "REC-04: continue menu action sets RECOVERY_MENU_ACTION=continue"

    reset_route_state
    seed_script_dir "menu-wipe-action"
    seed_env "ready" "none" "complete"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Wipe everything and start fresh"
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    assert_eq "0" "$rc" "REC-04: wipe menu action returns 0 for caller-owned wipe"
    assert_eq "wipe" "$RECOVERY_MENU_ACTION" "REC-04: wipe menu action sets RECOVERY_MENU_ACTION=wipe"
    assert_order_lacks "nuke_existing_install" "REC-04: wipe menu action does not call nuke_existing_install directly"

    reset_route_state
    seed_script_dir "menu-abort-action"
    seed_env "ready" "none" "complete"
    GPU_TYPE="intel"
    MENU_CAPTURE="$SCRIPT_DIR/menu-options"
    MENU_CHOICE="Abort"
    show_existing_install_menu >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "REC-04: abort menu action returns non-zero"
    assert_eq "abort" "$RECOVERY_MENU_ACTION" "REC-04: abort menu action sets RECOVERY_MENU_ACTION=abort"
else
    skip "REC-04: show_existing_install_menu action transport pending implementation"
fi

# ---------------------------------------------------------------------------
# REC-04: setup.sh stops after existing-install menu outcomes.
# ---------------------------------------------------------------------------

run_wizard() { record run_wizard; WIZARD_RAN_INSTALL=true; }

eval "${PRODUCTION_DETECT_EXISTING_INSTALL_DEF/detect_existing_install/production_detect_existing_install}"
reset_route_state
seed_script_dir "main-existing-incomplete-stage1"
seed_env "skipped" "none" "skipped" ""
mkdir -p "$SCRIPT_DIR/config/ddns-updater"
printf '{}\n' > "$SCRIPT_DIR/config/ddns-updater/config.json"
ui_choose() {
    record ui_choose
    printf '%s\n' "Use existing install"
}
detect_existing_install() {
    record detect_existing_install
    production_detect_existing_install
}
main >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "REC-04: incomplete Stage 1 with existing-install evidence exits 0"
assert_order_has "storage_pause_watchdog_for_install" "REC-04: incomplete Stage 1 pauses watchdog before resume"
assert_order_has "detect_existing_install" "REC-04: incomplete Stage 1 checks existing-install evidence"
assert_order_has "run_wizard" "REC-04: incomplete Stage 1 resumes wizard despite existing-install evidence"
assert_order_lacks "ui_choose" "REC-04: incomplete Stage 1 bypasses existing-install menu"
assert_eq "false" "${EXISTING_INSTALL_DETECTED:-}" "REC-04: incomplete Stage 1 does not set existing-install flag"

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
    assert_eq "$expected_rc" "$rc" "REC-04: main ${name} returns expected status"
    assert_order_has "detect_existing_install" "REC-04: main ${name} reaches existing-install detection"
    assert_order_lacks "run_wizard" "REC-04: main ${name} stops before run_wizard"
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
main >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "REC-04: main after successful wipe-cleared action continues setup"
assert_order_has "run_wizard" "REC-04: main after successful wipe-cleared action reaches run_wizard"

scenario_end "$CURRENT_SCENARIO"
summary

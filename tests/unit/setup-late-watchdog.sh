#!/usr/bin/env bash
# tests/unit/setup-late-watchdog.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="setup-late-watchdog"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/setup.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

ORDER=()

record() {
    ORDER+=("$1")
}

order_text() {
    printf '%s ' "${ORDER[@]}"
}

check_not_root() { record check_not_root; }
check_debian() { record check_debian; }
check_disk_floor() { record check_disk_floor; }
check_internet_reachability() { record check_internet_reachability; }
check_ram_warn() { record check_ram_warn; }
prompt_sudo_cache() { record prompt_sudo_cache; }
stash_gpu_type() { record stash_gpu_type; GPU_TYPE=none; }
check_docker() { record check_docker; }
check_compose() { record check_compose; }
detect_existing_install() { record detect_existing_install; }
cleanup_post_reboot() { record cleanup_post_reboot; }
detect_host_memory() { record detect_host_memory; HOST_MEMORY_MB=4096; }
setup_hardening() { record setup_hardening; }
detect_env() {
    record detect_env
    _ENV_TZ=Etc/UTC
    _ENV_PUID=1000
    _ENV_PGID=1000
    _ENV_HOST_ADDRESS=127.0.0.1
}
setup_ufw_service_ports() { record setup_ufw_service_ports; }
setup_samba() { record setup_samba; }
storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; }
stop_existing_stack() { record stop_existing_stack; }
create_data_dirs() { record create_data_dirs; }
create_config_dirs() { record create_config_dirs; }
generate_override() { record generate_override; }
pull_images() { record pull_images; }
start_stack() { record start_stack; }
storage_install_watchdog() {
    if storage_is_nas; then
        record storage_install_watchdog
    fi
}
wait_all_healthy() { record wait_all_healthy; }
print_access_info() { record print_access_info; }
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
log_skip() { record log_skip; }
run_stage1() { record run_stage1; WIZARD_RAN_INSTALL=true; }
run_stage2() { record run_stage2; }
run_stage3() { record run_stage3; }

python3() {
    if [[ "${1:-}" == "-c" ]]; then
        case "${2:-}" in
            "import yaml") return 0 ;;
            *"wizard_completed"*) grep -q '^wizard_completed: true' "$SCRIPT_DIR/config.yml" ;;
            *) command python3 "$@" ;;
        esac
        return $?
    fi
    command python3 "$@"
}

sudo() {
    record sudo
    return 0
}

seed_late_install_fixture() {
    local name="$1" storage_mode="$2" app_wiring="$3"
    local stage1_complete="${4-}"
    SCRIPT_DIR="$TMP_ROOT/$name"
    mkdir -p "$SCRIPT_DIR/scripts"
    cat > "$SCRIPT_DIR/config.yml" <<'YAML'
wizard_completed: true
YAML
    cat > "$SCRIPT_DIR/.env" <<ENV
TZ=Etc/UTC
PUID=1000
PGID=1000
DATA_DIR=/tmp/ms-late-${name}
HOST_ADDRESS=127.0.0.1
JELLYFIN_ADMIN_USER='admin'
JELLYFIN_ADMIN_PASSWORD='GeneratedDemoPassword123'
NPM_ADMIN_EMAIL=
JELLYFIN_GPU=none
DOMAIN=example.com
REMOTE_WEB_STATE=skipped
WG_INIT_PASSWORD=''
TORRENT_PORT=6881
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
BAZARR_ENABLED=false
SMB_ENABLED=false
STORAGE_MODE=${storage_mode}
STORAGE_APP_WIRING=${app_wiring}
STAGE_1_COMPLETE=${stage1_complete}
ENV
    cat > "$SCRIPT_DIR/scripts/configure.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$SCRIPT_DIR/scripts/configure.sh"
}

run_late_install_case() {
    local name="$1" storage_mode="$2" app_wiring="$3"
    local stage1_complete="${4-}"
    ORDER=()
    unset WIZARD_RAN_INSTALL STAGE_1_COMPLETE STORAGE_MODE STORAGE_APP_WIRING RECOVERY_MENU_ACTION
    seed_late_install_fixture "$name" "$storage_mode" "$app_wiring" "$stage1_complete"
    main >/dev/null 2>&1
    printf '%s\n' "$(order_text)"
}

nas_order="$(run_late_install_case nas nas managed)"
assert_contains "$nas_order" "prompt_sudo_cache storage_pause_watchdog_for_install stash_gpu_type" "interrupted NAS: incomplete rerun pauses watchdog before Docker/existing-install checks"
assert_contains "$nas_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install" "interrupted NAS: pause precedes existing-install detection"
assert_contains "$nas_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install cleanup_post_reboot detect_host_memory setup_hardening" "interrupted NAS: pause precedes hardening"
assert_contains "$nas_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install cleanup_post_reboot detect_host_memory setup_hardening detect_env run_stage1 run_stage3 run_stage2 setup_ufw_service_ports setup_samba" "interrupted NAS: wizard resumes core, hardware add-on, and remote instead of self-skipping"
case "$nas_order" in
    *"stash_gpu_type"*"storage_pause_watchdog_for_install"*|*"check_docker"*"storage_pause_watchdog_for_install"*|\
    *"check_compose"*"storage_pause_watchdog_for_install"*|*"detect_existing_install"*"storage_pause_watchdog_for_install"*|\
    *"setup_hardening"*"storage_pause_watchdog_for_install"*|*"run_stage1"*"storage_pause_watchdog_for_install"*|\
    *"setup_ufw_service_ports"*"storage_pause_watchdog_for_install"*|*"setup_samba"*"storage_pause_watchdog_for_install"*|*"stop_existing_stack"*"storage_pause_watchdog_for_install"*)
        fail "interrupted NAS: pre-wizard/hardening/stage work does not precede watchdog pause" "order: $nas_order"
        ;;
    *)
        pass "interrupted NAS: pre-wizard/hardening/stage work does not precede watchdog pause"
        ;;
esac
case "$nas_order" in
    *"log_skip"*|*"stop_existing_stack"*|*"pull_images"*|*"start_stack"*|*"storage_install_watchdog"*)
        fail "interrupted NAS: markerless late install path is not used" "order: $nas_order"
        ;;
    *)
        pass "interrupted NAS: markerless late install path is not used"
        ;;
esac

local_order="$(run_late_install_case local local manual)"
assert_contains "$local_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install cleanup_post_reboot detect_host_memory setup_hardening detect_env run_stage1 run_stage3 run_stage2 setup_ufw_service_ports setup_samba" "interrupted local fallback: stale watchdog paused before resumed core/hardware/remote and host integration"
case "$local_order" in
    *"stop_existing_stack"*|*"pull_images"*|*"start_stack"*|*"storage_install_watchdog"*)
        fail "interrupted local fallback: markerless late install path is not used" "order: $local_order"
        ;;
    *)
        pass "interrupted local fallback: markerless late install path is not used"
        ;;
esac

completed_order="$(run_late_install_case completed nas managed 1)"
case "$completed_order" in
    *"storage_pause_watchdog_for_install"*)
        fail "late install completed NAS rerun: valid watchdog is not preemptively paused" "order: $completed_order"
        ;;
    *)
        pass "late install completed NAS rerun: valid watchdog is not preemptively paused"
        ;;
esac

ORDER=()
storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; return 1; }
unset WIZARD_RAN_INSTALL STAGE_1_COMPLETE STORAGE_MODE STORAGE_APP_WIRING RECOVERY_MENU_ACTION
seed_late_install_fixture fail nas managed
main >/dev/null 2>&1
late_fail_rc=$?
late_fail_order="$(order_text)"
assert_eq "1" "$late_fail_rc" "late install: pause failure aborts setup"
case "$late_fail_order" in
    *"stash_gpu_type"*|*"check_docker"*|*"detect_existing_install"*|*"setup_hardening"*|*"log_skip"*|*"setup_ufw_service_ports"*|*"setup_samba"*|*"stop_existing_stack"*|*"start_stack"*)
        fail "late install: pause failure stops before pre-wizard work/stack churn" "order: $late_fail_order"
        ;;
    *)
        pass "late install: pause failure stops before pre-wizard work/stack churn"
        ;;
esac

# Focused pre-wizard coverage with an explicit run_wizard shim. The
# production self-skip path above records log_skip from inside run_wizard;
# these cases make the run_wizard boundary itself visible.
run_wizard() {
    record run_wizard
    WIZARD_RAN_INSTALL=true
}
storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; }
ORDER=()
unset WIZARD_RAN_INSTALL STAGE_1_COMPLETE STORAGE_MODE STORAGE_APP_WIRING RECOVERY_MENU_ACTION
seed_late_install_fixture prewizard nas managed
main >/dev/null 2>&1
prewizard_order="$(order_text)"
assert_contains "$prewizard_order" "prompt_sudo_cache storage_pause_watchdog_for_install stash_gpu_type" "pre-wizard incomplete install: pause happens before Docker/existing-install checks"
assert_contains "$prewizard_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install cleanup_post_reboot detect_host_memory setup_hardening" "pre-wizard incomplete install: pause happens before hardening"
assert_contains "$prewizard_order" "storage_pause_watchdog_for_install stash_gpu_type check_docker check_compose detect_existing_install cleanup_post_reboot detect_host_memory setup_hardening detect_env run_wizard" "pre-wizard incomplete install: pause happens before run_wizard"
case "$prewizard_order" in
    *"stash_gpu_type"*"storage_pause_watchdog_for_install"*|*"detect_existing_install"*"storage_pause_watchdog_for_install"*|\
    *"setup_hardening"*"storage_pause_watchdog_for_install"*|*"run_wizard"*"storage_pause_watchdog_for_install"*)
        fail "pre-wizard incomplete install: pre-wizard work does not precede watchdog pause" "order: $prewizard_order"
        ;;
    *)
        pass "pre-wizard incomplete install: pre-wizard work does not precede watchdog pause"
        ;;
esac

storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; return 1; }
ORDER=()
unset WIZARD_RAN_INSTALL STAGE_1_COMPLETE STORAGE_MODE STORAGE_APP_WIRING RECOVERY_MENU_ACTION
seed_late_install_fixture prewizard-fail nas managed
main >/dev/null 2>&1
prewizard_fail_rc=$?
prewizard_fail_order="$(order_text)"
assert_eq "1" "$prewizard_fail_rc" "pre-wizard incomplete install: pause failure aborts setup"
case "$prewizard_fail_order" in
    *"stash_gpu_type"*|*"detect_existing_install"*|*"setup_hardening"*|*"run_wizard"*)
        fail "pre-wizard incomplete install: pause failure prevents pre-wizard work" "order: $prewizard_fail_order"
        ;;
    *)
        pass "pre-wizard incomplete install: pause failure prevents pre-wizard work"
        ;;
esac

storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; }
run_wizard() { record run_wizard; }
ORDER=()
unset WIZARD_RAN_INSTALL STAGE_1_COMPLETE STORAGE_MODE STORAGE_APP_WIRING RECOVERY_MENU_ACTION
seed_late_install_fixture prewizard-complete nas managed 1
main >/dev/null 2>&1
prewizard_complete_order="$(order_text)"
assert_contains "$prewizard_complete_order" "run_wizard" "pre-wizard completed install: run_wizard still runs"
case "$prewizard_complete_order" in
    *"storage_pause_watchdog_for_install"*)
        fail "pre-wizard completed install: valid watchdog is not paused" "order: $prewizard_complete_order"
        ;;
    *)
        pass "pre-wizard completed install: valid watchdog is not paused"
        ;;
esac

scenario_end "$CURRENT_SCENARIO"
summary

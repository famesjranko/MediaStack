#!/usr/bin/env bash
# tests/unit/recovery-routing.sh
#
# Contract tests for recovery routing and stage re-entry.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
RECOVERY_ROUTING_TEST_DIR="$UNIT_DIR/recovery-routing"

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
    # Fixture consumed by the sourced product code under test.
    # shellcheck disable=SC2034
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
    cat >"$SCRIPT_DIR/scripts/configure.sh" <<'SH'
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
    cat >"$SCRIPT_DIR/.env" <<ENV
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

# Consumed by the sourced scenario files below (remote.sh, menu.sh), not in
# this file, so shellcheck cannot see the use across the source boundary.
# shellcheck disable=SC2034
PRODUCTION_DETECT_EXISTING_INSTALL_DEF=$(declare -f detect_existing_install)
# shellcheck disable=SC2034
PRODUCTION_NUKE_DEF=$(declare -f nuke_existing_install)
# shellcheck disable=SC2034
PRODUCTION_REPAIR_DDNS_DEF=$(declare -f repair_ddns_updater_config_permissions)
# shellcheck disable=SC2034
PRODUCTION_STAGE3_PENDING_DEF=$(declare -f stage3_pending_nvidia_reboot_same_boot)
# shellcheck disable=SC2034
PRODUCTION_STAGE3_PROMPT_DEF=$(declare -f stage3_prompt_pending_nvidia_reboot)
# shellcheck disable=SC2034
PRODUCTION_PRINT_FINAL_SUMMARY_DEF=$(declare -f print_final_summary)

# Side-effect stubs. Route tests assert these tokens rather than grepping only
# source strings.
ui_banner() { record ui_banner; }
log_warn() {
    printf '%s\n' "$1"
    record log_warn
}
log_info() { record log_info; }
log_ok() { record log_ok; }
log_error() {
    printf '%s\n' "$1"
    record log_error
}
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
stash_gpu_type() {
    record stash_gpu_type
    GPU_TYPE="${GPU_TYPE:-intel}"
}
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

# Keep the historical assertion order: the children are sourced, not run as
# independent suites, so the frozen output and summary remain one suite.
# shellcheck source=recovery-routing/remote.sh
source "$RECOVERY_ROUTING_TEST_DIR/remote.sh"
# shellcheck source=recovery-routing/transcoding.sh
source "$RECOVERY_ROUTING_TEST_DIR/transcoding.sh"
# shellcheck source=recovery-routing/menu.sh
source "$RECOVERY_ROUTING_TEST_DIR/menu.sh"

scenario_end "$CURRENT_SCENARIO"
summary

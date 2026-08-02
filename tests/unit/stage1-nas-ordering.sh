#!/usr/bin/env bash
# tests/unit/stage1-nas-ordering.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-nas-ordering"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage1.sh"

set +e
set +u

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$TMP_DIR"
mkdir -p "$SCRIPT_DIR/scripts"
cat >"$SCRIPT_DIR/.env" <<'ENV'
DATA_DIR=/tmp/ms-stage1-ordering
HOST_ADDRESS=127.0.0.1
JELLYFIN_API_KEY=stage1-ordering-key
STORAGE_MODE=nas
STAGE_1_COMPLETE=
ENV
cat >"$SCRIPT_DIR/scripts/configure.sh" <<'CONFIGURE'
#!/usr/bin/env bash
exit 0
CONFIGURE
chmod +x "$SCRIPT_DIR/scripts/configure.sh"

ORDER=()
record() {
    ORDER+=("$1")
}

log_info() { :; }
log_ok() { :; }
log_warn() { :; }
_wizard_apply_settings() { record wizard_apply; }
_stage1_source_env() {
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
    record source_env
}
_stage1_final_nas_preflight() { record final_nas_preflight; }
storage_pause_watchdog_for_install() { record storage_pause_watchdog_for_install; }
stop_existing_stack() { record stop_existing_stack; }
create_data_dirs() { record create_data_dirs; }
create_config_dirs() { record create_config_dirs; }
generate_override() { record generate_override; }
storage_install_watchdog() { record storage_install_watchdog; }
pull_images() { record pull_images; }
start_stack() { record start_stack; }
wait_all_healthy() { record wait_all_healthy; }
print_access_info() { record print_access_info; }
curl() { return 0; }
df() {
    printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n'
    printf 'fixture 1000G 1G 500G 1%% /\n'
}

_WIZ_DATA_DIR=/tmp/ms-stage1-ordering
_WIZ_QUALITY_RESOLUTION=1080p
_WIZ_QUALITY_SIZE=balanced
_WIZ_SUBTITLE_LANGS=english
_ENV_HOST_ADDRESS=127.0.0.1

_stage1_install >/dev/null 2>&1
rc=$?
order_text="${ORDER[*]}"

assert_eq "0" "$rc" "stage1 NAS ordering: install path exits with stubs"
assert_contains "$order_text" "source_env storage_pause_watchdog_for_install final_nas_preflight stop_existing_stack" "stage1 NAS ordering: partial rerun pauses watchdog before final preflight and stack stop"
assert_contains "$order_text" "pull_images start_stack storage_install_watchdog wait_all_healthy" "stage1 NAS ordering: watchdog starts only after initial stack start"
case "$order_text" in
    *"storage_install_watchdog"*"pull_images"* | *"storage_install_watchdog"*"start_stack"*)
        fail "stage1 NAS ordering: watchdog is not installed before pull/start" "order: $order_text"
        ;;
    *)
        pass "stage1 NAS ordering: watchdog is not installed before pull/start"
        ;;
esac
case "$order_text" in
    *"final_nas_preflight"*"storage_pause_watchdog_for_install"* | *"stop_existing_stack"*"storage_pause_watchdog_for_install"*)
        fail "stage1 NAS ordering: final preflight/stack stop do not run before watchdog pause" "order: $order_text"
        ;;
    *)
        pass "stage1 NAS ordering: final preflight/stack stop do not run before watchdog pause"
        ;;
esac

ORDER=()
storage_pause_watchdog_for_install() {
    record storage_pause_watchdog_for_install
    return 1
}
_stage1_install >/dev/null 2>&1
rc=$?
order_text="${ORDER[*]}"
assert_eq "1" "$rc" "stage1 NAS ordering: pause failure aborts install"
case "$order_text" in
    *"final_nas_preflight"* | *"stop_existing_stack"* | *"start_stack"*)
        fail "stage1 NAS ordering: pause failure stops before preflight/stack churn" "order: $order_text"
        ;;
    *)
        pass "stage1 NAS ordering: pause failure stops before preflight/stack churn"
        ;;
esac

scenario_end "$CURRENT_SCENARIO"
summary

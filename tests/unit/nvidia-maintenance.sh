#!/usr/bin/env bash
# Guard and ordering coverage for day-2 NVIDIA Unlock maintenance.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="nvidia-maintenance"
scenario_begin "$CURRENT_SCENARIO"
source "$REPO_ROOT/setup.sh"
set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT_DIR="$TMP_ROOT"
TRACE="$TMP_ROOT/trace"

seed_unlock_env() {
    cat > "$SCRIPT_DIR/.env" <<'ENV'
STAGE_1_COMPLETE=1
JELLYFIN_GPU=nvidia
NVIDIA_DRIVER_MODE=unlock
ENV
}

seed_unlock_env
log_warn() { :; }
log_error() { :; }
log_skip() { :; }
log_info() { :; }
prompt_sudo_cache() { printf '%s\n' sudo >> "$TRACE"; }
check_internet_reachability() { printf '%s\n' internet >> "$TRACE"; }
nvidia_driver_source() { printf foreign; }
nvidia_driver_healthy() { return 0; }
stage3_marker_exists() { return 1; }
ui_confirm() { printf '%s\n' confirm >> "$TRACE"; return 0; }
_resolve_nvidia_driver() {
    printf '%s\n' resolve >> "$TRACE"
    _driver_ver=550.90
    _run_file="$_nvidia_tmp/NVIDIA.run"
    : > "$_run_file"
}
docker() {
    printf 'docker:%s\n' "$*" >> "$TRACE"
    [[ "$*" == "compose ps --status running --services" ]] && printf '%s\n' jellyfin
    return 0
}
_nvidia_unload_loaded_modules() { printf '%s\n' unload >> "$TRACE"; return 0; }
_install_nvidia_run_file() { printf 'install:%s\n' "$2" >> "$TRACE"; return 0; }
_configure_nvidia_container_toolkit() { printf '%s\n' toolkit >> "$TRACE"; return 0; }
_stage3_nvidia_queue_reboot() { printf 'marker:%s:%s:%s\n' "$1" "$2" "$3" >> "$TRACE"; }

run_nvidia_unlock_maintenance update
trace=$(cat "$TRACE")
assert_contains "$trace" $'resolve\ndocker:compose ps' "NVIDIA update: resolves/downloads before stopping consumers"
assert_contains "$trace" $'docker:compose stop jellyfin\nunload\ninstall:550.90\ntoolkit\ndocker:compose start jellyfin\nmarker:unlock:run-update:550.90' \
    "NVIDIA update: stop, unload, install, toolkit, restart, marker ordering"
assert_eq "1" "$(grep -c '^install:' "$TRACE")" "NVIDIA update: installer executes once"
assert_eq "1" "$(grep -c '^toolkit$' "$TRACE")" "NVIDIA update: toolkit configuration executes once"

: > "$TRACE"
_nvidia_unload_loaded_modules() { printf '%s\n' unload-failed >> "$TRACE"; return 1; }
run_nvidia_unlock_maintenance update >/dev/null 2>&1
trace=$(cat "$TRACE")
assert_contains "$trace" "docker:compose start jellyfin" "NVIDIA update: unload failure restarts stopped consumer"
case "$trace" in
    *install:*|*marker:*) fail "NVIDIA update: unload failure does not install or queue finalization" ;;
    *) pass "NVIDIA update: unload failure does not install or queue finalization" ;;
esac

: > "$TRACE"
_nvidia_unload_loaded_modules() { return 0; }
ui_confirm() { return 1; }
run_nvidia_unlock_maintenance update
trace=$(cat "$TRACE")
case "$trace" in
    *resolve*|*docker:*|*install:*|*marker:*) fail "NVIDIA update: default-No cancellation mutates nothing" "$trace" ;;
    *) pass "NVIDIA update: default-No cancellation mutates nothing" ;;
esac

seed_unlock_env
# Exercise the REAL apply_nvidia_patch (stub only the impl) under an active
# `set -e`, mirroring how setup.sh --nvidia-unlock-repatch reaches it bare. A
# failed patch must return 1 AND drop the .nvidia-nvenc-unpatched marker — never
# let errexit abort before the marker is written (would leave a false
# "session limit removed" banner state).
_apply_nvidia_patch_impl() { return 1; }
rm -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched"
: > "$SCRIPT_DIR/.setup-result"
( set -e; run_nvidia_unlock_maintenance repatch ) >/dev/null 2>&1
assert_eq "1" "$?" "NVIDIA repatch: patch failure propagates to the guarded setup action"
if [[ -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched" ]]; then
    pass "NVIDIA repatch: patch failure drops the unpatched marker (no errexit abort)"
else
    fail "NVIDIA repatch: patch failure drops the unpatched marker (no errexit abort)"
fi
assert_eq "present" "$([[ -e "$SCRIPT_DIR/.setup-result" ]] && echo present || echo absent)" \
    "NVIDIA repatch: failed patch keeps the stale login banner (still accurate)"
unset -f _apply_nvidia_patch_impl

# A successful re-patch makes any stale "session limit NOT removed" banner wrong,
# so it must be cleared.
seed_unlock_env
_apply_nvidia_patch_impl() { return 0; }
: > "$SCRIPT_DIR/.setup-result"
run_nvidia_unlock_maintenance repatch >/dev/null 2>&1
assert_eq "0" "$?" "NVIDIA repatch: successful patch returns 0"
assert_eq "absent" "$([[ -e "$SCRIPT_DIR/.setup-result" ]] && echo present || echo absent)" \
    "NVIDIA repatch: successful patch clears the stale login banner"
unset -f _apply_nvidia_patch_impl

seed_unlock_env
nvidia_driver_source() { printf debian; }
if _nvidia_unlock_maintenance_guard --nvidia-unlock-update >/dev/null 2>&1; then
    fail "NVIDIA update: refuses apt ownership drift"
else
    pass "NVIDIA update: refuses apt ownership drift"
fi

scenario_end "$CURRENT_SCENARIO"
summary

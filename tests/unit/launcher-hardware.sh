#!/usr/bin/env bash
# tests/unit/launcher-hardware.sh
#
# Launcher coverage for the day-2 hardware transcoding surface.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-hardware"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-hardware${NC}"

menu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  stage3_pending_nvidia_reboot_same_boot(){ return 1; }
  pause_for_menu(){ :; }
  STAGE_1_COMPLETE=1
  menu_post >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$menu_out" "Manage hardware transcoding (GPU)" \
    "launcher: post-install menu exposes day-2 hardware transcoding"

submenu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 1; }
  JELLYFIN_GPU=nvidia
  NVIDIA_DRIVER_MODE=unlock
  submenu_manage_hardware >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$submenu_out" "Configure or change hardware transcoding" \
    "launcher: hardware submenu offers configure/change path"
assert_contains "$submenu_out" "Update NVIDIA driver + reapply Unlock patch" \
    "launcher: hardware submenu offers driver update in NVIDIA/Unlock context"
assert_contains "$submenu_out" "Reapply Unlock patch only" \
    "launcher: hardware submenu offers patch-only action in NVIDIA/Unlock context"

standard_submenu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 1; }
  JELLYFIN_GPU=nvidia
  NVIDIA_DRIVER_MODE=standard
  submenu_manage_hardware >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
case "$standard_submenu_out" in
    *"Reapply Unlock patch"* | *"Update NVIDIA driver"*)
        fail "launcher: Standard mode does not show Unlock-only actions"
        ;;
    *)
        pass "launcher: Standard mode does not show Unlock-only actions"
        ;;
esac

pending_submenu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 0; }
  JELLYFIN_GPU=nvidia
  NVIDIA_DRIVER_MODE=unlock
  submenu_manage_hardware >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$pending_submenu_out" "Reboot to finish hardware transcoding" \
    "launcher: hardware submenu exposes pending NVIDIA reboot action"

dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  ui_choose(){ echo "Configure or change hardware transcoding"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 1; }
  action_transcode(){ echo ACTION_TRANSCODE; exit 0; }
  submenu_manage_hardware
' 2>&1)
assert_contains "$dispatch_out" "ACTION_TRANSCODE" \
    "launcher: hardware submenu dispatches configure/change to transcoding recovery"

update_dispatch=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  ui_choose(){ echo "Update NVIDIA driver + reapply Unlock patch"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 1; }
  action_update_nvidia_driver(){ echo ACTION_UPDATE; exit 0; }
  JELLYFIN_GPU=nvidia
  NVIDIA_DRIVER_MODE=unlock
  submenu_manage_hardware
' 2>&1)
assert_contains "$update_dispatch" "ACTION_UPDATE" \
    "launcher: Unlock driver-update action dispatches to guarded setup route"

# --- _warn_gpu_runtime_fallback ---

# Fires when GPU state=complete but Jellyfin API reports software mode.
gpu_fallback_warn=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ printf "jellyfin\n"; }
  curl(){ printf '"'"'{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'"'"'; }
  JELLYFIN_GPU=nvidia JELLYFIN_API_KEY=testkey STAGE_3_GPU_STATE=complete
  _warn_gpu_runtime_fallback 2>&1
' 2>&1)
assert_contains "$gpu_fallback_warn" "software mode" \
    "launcher: _warn_gpu_runtime_fallback emits warning when Jellyfin reports SW transcoding"

# Silent when Jellyfin API confirms HW mode is active.
gpu_hw_ok=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ printf "jellyfin\n"; }
  curl(){ printf '"'"'{"HardwareAccelerationType":"nvenc","EnableHardwareEncoding":true}'"'"'; }
  JELLYFIN_GPU=nvidia JELLYFIN_API_KEY=testkey STAGE_3_GPU_STATE=complete
  _warn_gpu_runtime_fallback 2>&1
' 2>&1)
case "$gpu_hw_ok" in
    *"software mode"*) fail "launcher: _warn_gpu_runtime_fallback must be silent when HW mode is active" ;;
    *) pass "launcher: _warn_gpu_runtime_fallback silent when HW mode is active" ;;
esac

# No-op when GPU state is not complete (skipped/pending/unset).
gpu_noop=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  JELLYFIN_GPU=nvidia JELLYFIN_API_KEY=testkey STAGE_3_GPU_STATE=skipped
  _warn_gpu_runtime_fallback 2>&1
' 2>&1)
case "$gpu_noop" in
    *"software mode"*) fail "launcher: _warn_gpu_runtime_fallback must be no-op when state != complete" ;;
    *) pass "launcher: _warn_gpu_runtime_fallback no-op when GPU state != complete" ;;
esac

echo -e "${CYAN}◀ launcher-hardware done${NC}"
summary

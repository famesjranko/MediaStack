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
  diag_status(){ :; }
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
  NVIDIA_DRIVER_MODE=unlock
  submenu_manage_hardware >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$submenu_out" "Configure or change hardware transcoding" \
    "launcher: hardware submenu offers configure/change path"
assert_contains "$submenu_out" "Repatch NVIDIA driver (Unlock mode)" \
    "launcher: hardware submenu offers NVIDIA repatch in NVIDIA/Unlock context"

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
    *"Repatch NVIDIA driver (Unlock mode)"*)
        fail "launcher: Standard mode does not show Unlock-only repatch action"
        ;;
    *)
        pass "launcher: Standard mode does not show Unlock-only repatch action"
        ;;
esac

pending_submenu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  stage3_pending_nvidia_reboot_same_boot(){ return 0; }
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
  action_transcode(){ echo ACTION_TRANSCODE; }
  submenu_manage_hardware
' 2>&1)
assert_contains "$dispatch_out" "ACTION_TRANSCODE" \
    "launcher: hardware submenu dispatches configure/change to transcoding recovery"

echo -e "${CYAN}◀ launcher-hardware done${NC}"
summary

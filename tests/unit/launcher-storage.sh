#!/usr/bin/env bash
# tests/unit/launcher-storage.sh
#
# Launcher coverage for the day-2 "View storage & data mount" surface.
# The item is NAS-gated: it appears only when STORAGE_MODE=nas, so local installs
# keep an unchanged menu (and the local-mode PTY scenarios' numeric sends stay
# valid). Selections are asserted by label, position-agnostic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-storage"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-storage${NC}"

# 1. NAS install → the storage item is present in the post-install menu.
nas_menu=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  _warn_gpu_runtime_fallback(){ :; }
  launcher_pause_for_menu(){ :; }
  STAGE_1_COMPLETE=1
  STORAGE_MODE=nas
  launcher_menu_post >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$nas_menu" "View storage & data mount" \
    "launcher: NAS install exposes day-2 storage/data-mount item"

# 2. Local install → the storage item is absent (gating).
local_menu=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  _warn_gpu_runtime_fallback(){ :; }
  launcher_pause_for_menu(){ :; }
  STAGE_1_COMPLETE=1
  STORAGE_MODE=local
  launcher_menu_post >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
case "$local_menu" in
    *"View storage"*) fail "launcher: local install hides the storage item" ;;
    *) pass "launcher: local install hides the storage item" ;;
esac

# 3. Storage submenu offers "Re-check NAS now" and a Back path.
submenu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  STORAGE_MODE=nas
  submenu_storage >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$submenu_out" "Re-check NAS now" \
    "launcher: storage submenu offers the re-check action"

# 4. Selecting "Re-check NAS now" dispatches to action_recheck_nas.
dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  ui_choose(){ echo "Re-check NAS now"; }
  action_recheck_nas(){ echo ACTION_RECHECK; exit 0; }
  STORAGE_MODE=nas
  submenu_storage
' 2>&1)
assert_contains "$dispatch_out" "ACTION_RECHECK" \
    "launcher: storage submenu dispatches re-check to action_recheck_nas"

# 5. A failing NAS check propagates its non-zero exit status into the shared
# action-result report instead of always reporting success.
fail_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  storage_nas_ok(){ return 1; }
  launcher_pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1 label=$2"; }
  action_recheck_nas
' 2>&1)
assert_contains "$fail_out" "RESULT rc=1 label=Re-check NAS" \
    "launcher: a failing NAS re-check propagates rc=1 into the action result"

# 6. A healthy NAS check reports rc=0 into the same shared action-result path.
ok_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  storage_nas_ok(){ return 0; }
  launcher_pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1 label=$2"; }
  action_recheck_nas
' 2>&1)
assert_contains "$ok_out" "RESULT rc=0 label=Re-check NAS" \
    "launcher: a healthy NAS re-check reports rc=0 into the action result"

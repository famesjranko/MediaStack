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

# 7. The re-check warning names the watchdog state the host really has.
# Given a NAS that fails the check and each possible watchdog state
# When the operator runs "Re-check NAS now"
# Then the warning only claims retrying when a watchdog runs, and otherwise gives the remedy
recheck_hint() { # <enabled> <installed rc> <active rc>
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" WD_ENABLED="$1" WD_INSTALLED="$2" WD_ACTIVE="$3" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  storage_nas_ok(){ return 1; }
  storage_watchdog_enabled(){ [[ "$WD_ENABLED" == yes ]]; }
  storage_watchdog_installed(){ return "$WD_INSTALLED"; }
  systemctl(){ return "$WD_ACTIVE"; }
  launcher_pause_for_menu(){ :; }
  _show_action_result(){ :; }
  action_recheck_nas
' 2>&1
}
not_installed_out="$(recheck_hint yes 1 3)"
assert_contains "$not_installed_out" "No watchdog is installed" \
    "launcher: re-check says no watchdog is installed when the unit is missing"
assert_contains "$not_installed_out" "Apply changes from a MediaStack update" \
    "launcher: re-check names the remedy for a missing watchdog"
assert_not_contains "$not_installed_out" "keeps retrying" \
    "launcher: re-check does not claim retrying without a watchdog"
assert_contains "$(recheck_hint yes 0 0)" "keeps retrying" \
    "launcher: re-check says the watchdog keeps retrying when it runs"
stopped_out="$(recheck_hint yes 0 3)"
assert_contains "$stopped_out" "installed but not running" \
    "launcher: re-check says an installed watchdog is not running"
assert_not_contains "$stopped_out" "keeps retrying" \
    "launcher: re-check does not claim retrying from a stopped watchdog"
assert_contains "$(recheck_hint no 1 3)" "turned off" \
    "launcher: re-check says a disabled watchdog is off"

# 8. The view row for the watchdog tells the same story.
# Given a NAS install with no watchdog unit
# When the storage view renders
# Then the Watchdog row says it is not installed
view_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ shift; printf "%s\n" "$@"; }
  storage_sentinel_ok(){ return 0; }
  storage_mount_matches(){ return 0; }
  storage_watchdog_enabled(){ return 0; }
  storage_watchdog_installed(){ return 1; }
  docker(){ :; }
  STORAGE_MODE=nas
  _storage_info
' 2>&1)
assert_contains "$view_out" "not installed" \
    "launcher: storage view shows the watchdog as not installed"

# 9. A timed-out probe (rc 124) is reported as a plain failure, not "exited with code 124".
# Given the NAS check times out
# When the operator runs "Re-check NAS now"
# Then the action result carries rc=1
timeout_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  storage_nas_ok(){ return 124; }
  launcher_pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1 label=$2"; }
  action_recheck_nas
' 2>&1)
assert_contains "$timeout_out" "RESULT rc=1 label=Re-check NAS" \
    "launcher: a timed-out NAS re-check reports rc=1"

summary

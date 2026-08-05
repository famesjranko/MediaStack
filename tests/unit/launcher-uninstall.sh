#!/usr/bin/env bash
# tests/unit/launcher-uninstall.sh
#
# Launcher coverage for the "Uninstall MediaStack" day-2 menu option.
# Verifies:
#   1. "Uninstall MediaStack" appears in launcher_menu_post labels.
#   2. launcher_menu_post routes the selection to action_uninstall.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-uninstall"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-uninstall${NC}"

# 1. Menu presence
menu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  STAGE_1_COMPLETE=1
  launcher_menu_post >/dev/null 2>&1
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
  rm -f "$LABELS"
' 2>&1)
assert_contains "$menu_out" "Uninstall MediaStack" \
    "launcher: post-install menu exposes Uninstall MediaStack option"

# 2. Dispatch routing (action_uninstall gets called on selection)
dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  ui_choose(){ echo "Uninstall MediaStack"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  action_uninstall(){ echo DISPATCH_UNINSTALL; exit 0; }
  STAGE_1_COMPLETE=1
  launcher_menu_post 2>&1
' 2>&1)
assert_contains "$dispatch_out" "DISPATCH_UNINSTALL" \
    "launcher: Uninstall MediaStack routes to action_uninstall"

failed_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s\n" "$*"; }
  _show_action_result 1 Uninstall failed 1
' 2>&1)
assert_contains "$failed_out" "did not complete" \
    "launcher: failed uninstall is not reported as aborted or successful"

echo -e "${CYAN}◀ launcher-uninstall done${NC}"
summary

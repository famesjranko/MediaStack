#!/usr/bin/env bash
# tests/unit/launcher-action-result.sh
#
# Launcher capstone honesty (issue #4). _show_action_result is the single most
# authoritative line a user sees after an action. Contract:
#   token completed → "<label> completed successfully."
#   token aborted   → "<label> aborted — no changes were made."  (wins over rc)
#   token unchanged → "No changes were made."
#   no token, STRICT (install/wipe): rc!=0 → error; rc==0 → "did not complete"
#       (a bare exit 0 with no completion token means the wizard was aborted
#        before finishing — must NOT be reported as success)
#   no token, non-strict (remote/transcoding/port-check/update): rc-based.
# setup.sh hands the token over via MEDIASTACK_LAUNCHER_RESULT (see
# scripts/setup/checks.sh:record_launcher_outcome, recovery.sh, and setup.sh
# main()). This tests the launcher half — the (rc, token, strict) → verdict map.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-action-result"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-action-result${NC}"

# Source the launcher (guarded main → sourcing only exposes helpers; EUID guard
# passes as the non-root unit user, non-TTY guard bypassed by
# MEDIASTACK_NONINTERACTIVE=1). Stub ui_log to "<level>|<message>" so we see both
# the severity and the copy the capstone chose. Run all mappings, tag each.
verdicts=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  echo "C1:"; _show_action_result 0 "Wipe / reinstall" completed 1
  echo "C2:"; _show_action_result 0 "Install"          completed 0
  echo "C3:"; _show_action_result 0 "Wipe / reinstall" unchanged 1
  echo "C4:"; _show_action_result 0 "Wipe / reinstall" aborted   1
  echo "C5:"; _show_action_result 0 "Add remote access" "" 0
  echo "C6:"; _show_action_result 1 "Add remote access" "" 0
  echo "C7:"; _show_action_result 0 "Wipe / reinstall" reboot-pending 1
' 2>&1)

assert_contains "$verdicts" "ok|Wipe / reinstall completed successfully." \
    "launcher: 'completed' token (strict) → genuine success"
assert_contains "$verdicts" "ok|Install completed successfully." \
    "launcher: 'completed' token (non-strict) → genuine success"
assert_contains "$verdicts" "info|No changes were made." \
    "launcher: 'unchanged' token → calm no-change line"
assert_contains "$verdicts" "info|Wipe / reinstall aborted — no changes were made." \
    "launcher: 'aborted' token → calm abort line, not success"
assert_contains "$verdicts" "ok|Add remote access completed successfully." \
    "launcher: non-strict + no token + rc 0 → success"
assert_contains "$verdicts" "error|Add remote access exited with code 1." \
    "launcher: non-strict + no token + rc 1 → genuine failure"
assert_contains "$verdicts" "warn|Reboot to finish — hardware transcoding activates after you reboot." \
    "launcher: 'reboot-pending' token → reboot-to-finish, not a flat success"

# Load-bearing: STRICT action, no completion token, exit 0 = wizard aborted
# before finishing. Must NOT say "completed successfully".
strict_abort=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 0 "Wipe / reinstall" "" 1
' 2>&1)
assert_contains "$strict_abort" "did not complete" \
    "launcher: strict + no token + rc 0 → 'did not complete'"
if [[ "$strict_abort" == *"completed successfully"* ]]; then
    fail "launcher: strict bare exit 0 must NOT render as success" "$strict_abort"
else
    pass "launcher: strict bare exit 0 must NOT render as success"
fi

# STRICT genuine failure (rc!=0, no token) still surfaces as an error.
strict_fail=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 1 "Wipe / reinstall" "" 1
' 2>&1)
assert_contains "$strict_fail" "error|Wipe / reinstall exited with code 1." \
    "launcher: strict + no token + rc 1 → genuine failure still shown"

# A deliberate abort exits non-zero in some paths, but the token must override
# the rc so a safe choice never renders as an error.
aborted_rc1=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 1 "Wipe / reinstall" aborted 1
' 2>&1)
assert_contains "$aborted_rc1" "info|Wipe / reinstall aborted — no changes were made." \
    "launcher: 'aborted' token wins over a non-zero exit code"
if [[ "$aborted_rc1" == *"exited with code"* ]]; then
    fail "launcher: deliberate abort must not render as an error" "$aborted_rc1"
else
    pass "launcher: deliberate abort must not render as an error"
fi

# Per-service starts use the same NAS guard as starting the whole stack.
service_guard=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ [[ "$*" == *"ps --filter status=exited"* ]] && echo jellyfin || echo DOCKER_CALLED; }
  ui_choose(){ echo jellyfin; }; storage_guard_before_start(){ return 1; }; pause_for_menu(){ :; }
  action_service_start
' 2>&1)
if [[ "$service_guard" == *DOCKER_CALLED* ]]; then
    fail "launcher: NAS guard blocks a per-service start" "$service_guard"
else
    pass "launcher: NAS guard blocks a per-service start"
fi

# Compose failures must reach the existing action-result renderer.
service_failure=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ [[ "$*" == *"ps --filter status=running"* ]] && { echo jellyfin; return; }; return 42; }
  ui_choose(){ echo jellyfin; }; pause_for_menu(){ :; }; ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  action_service_stop
' 2>&1)
assert_contains "$service_failure" "error|Stop jellyfin exited with code 42." \
    "launcher: per-service Compose failures are reported honestly"

echo -e "${CYAN}◀ launcher-action-result done${NC}"
summary

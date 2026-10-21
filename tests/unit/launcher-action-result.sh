#!/usr/bin/env bash
# tests/unit/launcher-action-result.sh
#
# Launcher capstone honesty. _show_action_result is the single most
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

# Given a transcoding run that ended on software fallback, the launcher must say so.
# Given: the token the setup side writes for a Secure Boot fallback
# When: the launcher renders the result
# Then: it names software transcoding, the reason and the remedy, never "completed successfully"
fallback_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 0 "Hardware transcoding" "software-fallback:secure_boot" 0
' 2>&1)
assert_contains "$fallback_out" "warn|Hardware transcoding finished with software transcoding" "launcher: 'software-fallback' token → software-transcoding line"
assert_contains "$fallback_out" "Secure Boot blocks the NVIDIA driver" "launcher: 'software-fallback' token → stored reason shown"
assert_contains "$fallback_out" "Fix: disable Secure Boot" "launcher: 'software-fallback' token → remedy shown"
if [[ "$fallback_out" == *"completed successfully"* ]]; then
    fail "launcher: software fallback must NOT render as success" "$fallback_out"
else
    pass "launcher: software fallback must NOT render as success"
fi

# Given: a setup run where STAGE_3_GPU_STATE ends as fallback, or as complete
# When: the transcoding outcome is recorded
# Then: fallback writes software-fallback:<reason>; a real completion writes completed
tok=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  f=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$f"
  STAGE_3_GPU_STATE=fallback STAGE_3_GPU_FALLBACK_REASON=verify_failed record_transcoding_outcome
  echo "A:$(<"$f")"
  STAGE_3_GPU_STATE=complete STAGE_3_GPU_FALLBACK_REASON="" record_transcoding_outcome
  echo "B:$(<"$f")"; rm -f "$f"
' 2>&1)
assert_contains "$tok" "A:software-fallback:verify_failed" "setup: fallback state records the software-fallback token"
assert_contains "$tok" "B:completed" "setup: a real completion still records completed"

# Given: a setup run that prepared the NVIDIA driver and still needs a reboot (state pending)
# When: the transcoding outcome is recorded and the launcher renders it
# Then: the token asks for the reboot and the launcher never says "completed successfully"
pend_tok=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  f=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$f"
  STAGE_3_GPU_STATE=pending record_transcoding_outcome
  tok=$(<"$f"); rm -f "$f"
  echo "T:$tok"
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 0 "Hardware transcoding" "$tok" 0
' 2>&1)
assert_contains "$pend_tok" "warn|Hardware transcoding ready — reboot to finish; MediaStack resumes after the reboot." \
    "launcher: pending GPU state → reboot-to-finish line"
if [[ "$pend_tok" == *"completed successfully"* ]]; then
    fail "launcher: pending GPU state must NOT render as completed" "$pend_tok"
else
    pass "launcher: pending GPU state must NOT render as completed"
fi

# Given: nvidia-smi fails with its error text on stdout and exit 9, or works
# When: the launcher builds the Transcoding status line
# Then: a broken driver reads "driver not loaded" without the error text; a working one shows its version
_tc_line() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" SMI="$1" bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      if [[ "$SMI" == bad ]]; then
        nvidia-smi(){ echo "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver"; return 9; }
      else
        nvidia-smi(){ echo "535.261.03"; }
      fi
      _compose_running_summary(){ return 1; }
      ui_kv(){ printf "%s=%s\n" "$1" "$2"; }
      _ddns_configured(){ return 1; }
      JELLYFIN_GPU=nvidia NVIDIA_DRIVER_MODE=standard _stack_system_lines
    ' 2>&1
}
bad_tc=$(_tc_line bad | grep '^Transcoding=')
assert_contains "$bad_tc" "Transcoding=not active — driver not loaded (repair from Manage hardware transcoding)" \
    "launcher: failing nvidia-smi → status line says not active, driver not loaded"
assert_not_contains "$bad_tc" "NVIDIA NVENC" "launcher: an unloaded driver is not shown as active NVENC"
if [[ "$bad_tc" == *"NVIDIA-SMI has failed"* ]]; then
    fail "launcher: nvidia-smi error text must not reach the status line" "$bad_tc"
else
    pass "launcher: nvidia-smi error text must not reach the status line"
fi
good_tc=$(_tc_line good | grep '^Transcoding=')
assert_contains "$good_tc" "Transcoding=NVIDIA NVENC — driver 535.261.03 (standard)" \
    "launcher: working nvidia-smi → status line shows driver version"

# Given: software transcoding with a recorded Secure Boot fallback, or no record at all
# When: the launcher builds the Transcoding status line
# Then: the recorded one shows its reason; the unrecorded one keeps the plain wording
_tc_sw() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      _compose_running_summary(){ return 1; }
      ui_kv(){ printf "%s=%s\n" "$1" "$2"; }
      _ddns_configured(){ return 1; }
      JELLYFIN_GPU=none STAGE_3_GPU_STATE="$1" STAGE_3_GPU_FALLBACK_REASON="$2" _stack_system_lines
    ' _ "$1" "$2" 2>&1 | grep '^Transcoding='
}
assert_eq "Transcoding=Software (Secure Boot blocks the NVIDIA driver)" "$(_tc_sw fallback secure_boot)" \
    "launcher: recorded fallback → status line shows Software with the reason"
assert_eq "Transcoding=Software (no GPU acceleration)" "$(_tc_sw "" "")" \
    "launcher: no recorded fallback → status line unchanged"

# Given: an install that finished while hardware transcoding fell back (Secure Boot)
# When: the launcher renders the Install result
# Then: it says Install completed with software transcoding, the reason and the remedy
install_fb=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  _show_action_result 0 "Install" "completed-software:secure_boot" 0
' 2>&1)
assert_contains "$install_fb" "warn|Install completed with software transcoding (Secure Boot blocks the NVIDIA driver)" \
    "launcher: install after a fallback → names software transcoding and the reason"
assert_contains "$install_fb" "Fix: disable Secure Boot" "launcher: install after a fallback → remedy shown"
assert_not_contains "$install_fb" "completed successfully" "launcher: install after a fallback is not a plain success"

# Given: setup.sh finishes an install with a recorded Secure Boot fallback, then with none
# When: it records the launcher outcome
# Then: the fallback writes the software token with the reason; no fallback writes completed
_outcome_for() {
    REPO_ROOT="$REPO_ROOT" F="$(mktemp)" bash -c '
      source "$REPO_ROOT/scripts/setup/checks.sh" 2>/dev/null
      source "$REPO_ROOT/scripts/setup/recovery.sh" 2>/dev/null
      MEDIASTACK_LAUNCHER_RESULT="$F" STAGE_3_GPU_STATE="$1" STAGE_3_GPU_FALLBACK_REASON="$2" record_install_outcome
      cat "$F"; rm -f "$F"
    ' _ "$1" "$2"
}
assert_eq "completed-software:secure_boot" "$(_outcome_for fallback secure_boot)" \
    "setup: install with a fallback records the software token and reason"
assert_eq "completed" "$(_outcome_for complete "")" "setup: install without a fallback records completed"

# Per-service starts use the same NAS guard as starting the whole stack.
service_guard=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ [[ "$*" == *"ps --filter status=exited"* ]] && echo jellyfin || echo DOCKER_CALLED; }
  ui_choose(){ echo jellyfin; }; storage_guard_before_start(){ return 1; }; launcher_pause_for_menu(){ :; }
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
  ui_choose(){ echo jellyfin; }; launcher_pause_for_menu(){ :; }; ui_log(){ printf "%s|%s\n" "$1" "$2"; }
  action_service_stop
' 2>&1)
assert_contains "$service_failure" "error|Stop jellyfin exited with code 42." \
    "launcher: per-service Compose failures are reported honestly"

echo -e "${CYAN}◀ launcher-action-result done${NC}"
summary

#!/usr/bin/env bash
# tests/unit/ui-choose-abort.sh
#
# Regression guard for the gum Ctrl-C menu bug found on real hardware (gum
# v0.17.0). `gum choose` exits 130 on Ctrl-C; the gum backend re-raises SIGINT
# to the main shell, but that signal stays PENDING while ui_choose is blocked in
# `result=$(_render_choose ...)`. The backend must therefore return a DISTINCT
# 130 so ui_choose BREAKS its loop and returns — only then does the caller's
# command substitution complete and the pending trap fire (clean "Goodbye").
#
# Before the fix, _render_choose collapsed 130 into the generic 3, so ui_choose's
# rc=3 branch reprompted forever ("Enter a number between 1 and N"), swallowing
# the signal. This test pins the contract at the ui.sh boundary — no gum/TTY
# needed: we stub the backend _render_choose to return 130 and assert ui_choose
# aborts after a SINGLE render instead of looping.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-choose-abort"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/ui.sh"

set +e

# Silence the reprompt warning so a regression is observable via call count, not
# stdout noise.
ui_log() { :; }
_render_log() { :; }

# Backend stub: model `gum choose` under Ctrl-C — always returns 130. A call
# counter (via file, to survive the $(...) subshell in ui_choose) both proves
# "aborts after one render" and, if the fix regresses, breaks the otherwise
# infinite reprompt loop after a few iterations so this test FAILS instead of
# hanging to the 300s unit timeout.
CALL_FILE=$(mktemp)
trap 'rm -f "$CALL_FILE"' EXIT
printf '0\n' > "$CALL_FILE"
_render_choose() {
    local n; n=$(cat "$CALL_FILE"); n=$((n + 1)); printf '%s\n' "$n" > "$CALL_FILE"
    (( n > 3 )) && { echo "REGRESSED-DID-NOT-ABORT"; return 0; }
    return 130
}

# ui_choose runs in a command substitution exactly like every real call site.
out=$(ui_choose "What would you like to do?" "View access" "Manage stack" "Quit"); rc=$?
calls=$(cat "$CALL_FILE")

assert_eq "130" "$rc" "ui_choose: gum Ctrl-C (backend 130) propagates 130, does not reprompt-loop"
assert_eq "1" "$calls" "ui_choose: gum Ctrl-C aborts after ONE render (no reprompt loop)"
assert_eq "" "$out" "ui_choose: aborted choice emits no selection"

scenario_end "$CURRENT_SCENARIO"
summary

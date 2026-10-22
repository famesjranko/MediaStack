#!/usr/bin/env bash
# tests/unit/ui-input-exhaustion-signal.sh
#
# Input exhaustion must signal only the top-level shell, never the whole process
# group. A group-kill also hits a `timeout` wrapper in that group; uutils
# `timeout` (the default on Ubuntu 26.04) then exits 143 itself instead of
# passing the child's exit 3 through. GNU timeout hid this, so the check here
# observes the signal's reach directly (a same-group sibling) instead of
# relying on the wrapper.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-input-exhaustion-signal"
scenario_begin "$CURRENT_SCENARIO"

# Runs one exhausted-stdin prompt under a documented TERM trap, with a sibling
# process in the same process group. Prints "<rc> <sibling state>".
probe() {
    local prompt_call="$1"
    env -u UI_DEMO -u DEMO REPO_ROOT="$REPO_ROOT" PROMPT_CALL="$prompt_call" \
        setsid bash -c '
      _src=source
      "$_src" "$REPO_ROOT/scripts/lib/ui.sh"
      "$_src" "$REPO_ROOT/scripts/lib/validators.sh"
      sleep 30 &
      sibling=$!
      trap "exit ${UI_EXIT_INPUT_EXHAUSTED}" TERM
      # The prompt call is intentionally evaluated from the environment.
      out=$(eval "$PROMPT_CALL" </dev/null)
      echo "REACHED_PAST_PROMPT=$out"
    ' >/dev/null 2>&1 &
    local pid=$!
    # A background job of a script is not a group leader, so setsid execs in place
    # and $pid is both the shell and its new process group.
    local rc sibling_state
    wait "$pid"
    rc=$?
    sibling_state=gone
    if pgrep -g "$pid" -x sleep >/dev/null 2>&1; then
        sibling_state=alive
        pkill -g "$pid" -x sleep 2>/dev/null || true
    fi
    echo "$rc $sibling_state"
}

# Given a non-interactive session whose stdin is already empty
# When ui_choose, ui_input_validated or ui_password_validated hits EOF
# Then the TERM-trapped parent exits 3 and a same-group sibling is left running
for _call in \
    'ui_choose "Pick one:" A B C' \
    'ui_input_validated "Required field" "" validate_admin_email' \
    'ui_password_validated "Required field" "" validate_ddns_password'; do
    got=$(probe "$_call")
    assert_eq "3 alive" "$got" "${_call%% *}: input exhaustion exits 3 without signalling the process group"
done

scenario_end "$CURRENT_SCENARIO"
summary

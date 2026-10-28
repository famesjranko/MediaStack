#!/usr/bin/env bash
# =============================================================================
# Unit test — label-based menu selection in tests/lib/wizard_pty.py
# =============================================================================
# The install-e2e scenario drives the real ./mediastack menus, whose item
# numbers change with install state. Its "choose" steps pick an item by label
# from the next menu with the given prompt. These cases prove the driver picks
# by label when the numbering moves in a redrawn menu, answers only a menu with
# the given prompt, and fails when the label is missing or ambiguous. The menus
# are drawn by the product's own fallback renderer (_render_choose), so a change
# to its format breaks these cases too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-pty-choose"
scenario_begin "$CURRENT_SCENARIO"

PTY="$REPO_ROOT/tests/lib/wizard_pty.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Menu programs. "redraw": the same menu twice with other numbering, as the
# launcher does after an action, and between them a menu with another prompt
# that offers the same label. That menu waits two seconds (TMOUT), then goes on
# unanswered. "duplicate": one menu with two items that match "^Revert".
cat >"$WORK/menus.sh" <<BASH
source "$REPO_ROOT/scripts/lib/ui-render-fallback.sh"
BASH
cat >>"$WORK/menus.sh" <<'BASH'
menu() {
    local item
    item=$(_render_choose "$1" 0 "${@:2}") || item=none
    echo "picked:$item"
}
case "$1" in
    redraw)
        menu "Manage updates:" "Update a service" "Revert a service" "Back"
        TMOUT=2 menu "Revert which service?" "Revert a service" "Back"
        menu "Manage updates:" "Back" "Update a service" "Revert a service"
        ;;
    duplicate)
        menu "Manage updates:" "Update a service" "Revert a service" "Revert all" "Back"
        ;;
esac
BASH

run_pty() { # <program> <steps-json> -> rc; transcript in $WORK/plain.log
    printf '%s\n' "$2" >"$WORK/steps.json"
    python3 "$PTY" --command "bash $WORK/menus.sh $1" --steps "$WORK/steps.json" \
        --cwd "$WORK" --raw-log "$WORK/raw.log" --plain-log "$WORK/plain.log" \
        --step-timeout 5 --exit-timeout 5 2>"$WORK/stderr.log"
}

picks() { grep -o 'picked:[A-Za-z ]*' "$WORK/plain.log" | tr '\n' '|'; }

# --- Choose by label across a redrawn menu, skipping another prompt ---
# Given a program that shows "Manage updates:" twice with different numbering.
# And between them a menu with another prompt that also offers "Revert a service".
steps='[{"choose": {"prompt": "Manage updates:", "item": "^Revert"}},
        {"choose": {"prompt": "Manage updates:", "item": "^Revert"}}]'

# When the driver chooses "Revert" from two "Manage updates:" menus.
run_pty redraw "$steps"
rc=$?

# Then the run succeeds.
assert_eq 0 "$rc" "choose: both Manage updates menus answered"
# And each Manage updates menu got its Revert item, and the other menu got no answer.
assert_eq "picked:Revert a service|picked:none|picked:Revert a service|" "$(picks)" \
    "choose: the label wins over the position, and a menu with another prompt is not answered"

# --- A label the menu does not offer fails the run ---
# Given the redraw program.
steps='[{"choose": {"prompt": "Manage updates:", "item": "^Remove"}}]'

# When the driver asks for a label that no menu offers.
run_pty redraw "$steps"
rc=$?

# Then the run fails.
if ((rc != 0)); then
    pass "choose: a missing label fails the run"
else
    fail "choose: a missing label fails the run" "rc=0"
fi
# And the error names the missing label and the offered items.
assert_contains "$(cat "$WORK/stderr.log")" "does not offer '^Remove'" \
    "choose: the failure names the missing label"

# --- A label that matches more than one item fails the run ---
# Given a menu with two items that start with "Revert".
steps='[{"choose": {"prompt": "Manage updates:", "item": "^Revert"}}]'

# When the driver chooses "^Revert" from it.
run_pty duplicate "$steps"
rc=$?

# Then the run fails.
if ((rc != 0)); then
    pass "choose: an ambiguous label fails the run"
else
    fail "choose: an ambiguous label fails the run" "rc=0"
fi
# And the error names both matching items.
assert_contains "$(cat "$WORK/stderr.log")" "offers '^Revert' more than once: ['Revert a service', 'Revert all']" \
    "choose: the failure names every matching item"

summary

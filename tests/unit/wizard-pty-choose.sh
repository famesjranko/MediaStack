#!/usr/bin/env bash
# =============================================================================
# Unit test — label-based menu selection in tests/lib/wizard_pty.py
# =============================================================================
# The install-e2e scenario drives the real ./mediastack menus, whose item
# numbers change with install state. Its "choose" steps pick an item by label
# from the next menu after the previous one. These cases prove the driver
# picks by label when the numbering moves in a redrawn menu, and fails when
# the label is not offered.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-pty-choose"
scenario_begin "$CURRENT_SCENARIO"

PTY="$REPO_ROOT/tests/lib/wizard_pty.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A two-menu program in the fallback ui_choose format. The second menu lists
# the same labels in another order, as the launcher does after an action.
cat >"$WORK/menus.sh" <<'BASH'
menu() {
    local prompt="$1" choice
    shift
    echo "  $prompt"
    local i=1 item
    for item in "$@"; do
        printf '  %s) %s\n' "$i" "$item"
        i=$((i + 1))
    done
    read -rp "  Choice 1-$#: " choice
    echo "picked:${@:choice:1}"
}
menu "Manage updates:" "Update a service" "Revert a service" "Back"
menu "Manage updates:" "Back" "Update a service" "Revert a service"
BASH

run_pty() { # <steps-json> -> rc; transcript in $WORK/plain.log
    printf '%s\n' "$1" >"$WORK/steps.json"
    python3 "$PTY" --command "bash $WORK/menus.sh" --steps "$WORK/steps.json" \
        --cwd "$WORK" --raw-log "$WORK/raw.log" --plain-log "$WORK/plain.log" \
        --step-timeout 5 --exit-timeout 5 2>"$WORK/stderr.log"
}

# --- Choose by label across a redrawn menu ---
# Given a program that shows the same menu twice with different numbering.
steps='[{"choose": {"prompt": "Manage updates:", "item": "^Revert"}},
        {"choose": {"prompt": "Manage updates:", "item": "^Revert"}}]'

# When the driver chooses "Revert" from each menu.
run_pty "$steps"
rc=$?

# Then the run succeeds.
assert_eq 0 "$rc" "choose: both menus answered"
# And the first menu got item 2 while the redrawn menu got item 3.
picks="$(grep -o 'picked:[A-Za-z ]*' "$WORK/plain.log" | tr '\n' '|')"
assert_eq "picked:Revert a service|picked:Revert a service|" "$picks" \
    "choose: the label wins over the position in each redrawn menu"

# --- A label the menu does not offer fails the run ---
# Given the same program.
steps='[{"choose": {"prompt": "Manage updates:", "item": "^Remove"}}]'

# When the driver asks for a label that neither menu offers.
run_pty "$steps"
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

summary

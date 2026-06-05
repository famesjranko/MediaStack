#!/usr/bin/env bash
# tests/unit/ui-password-validated.sh
#
# Unit coverage for the masked-and-validated password primitive (issue #6):
# ui_password_validated -> _ui_password_validated_impl. Exercises the DEMO/UI_DEMO
# short-circuit and the validator-driven re-prompt loop. The masking itself
# (read -rsp, no keystroke echo) lives in _ui_password_impl and is proven
# end-to-end by the DinD wizard-ui PTY scenarios; here we test the loop logic.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-password-validated"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/lib/validators.sh"

set +e

# Capture validator warnings; silence everything else ui_log emits.
WARN_FILE=$(mktemp)
ui_log() { [[ "${1:-}" == "warn" ]] && printf '%s\n' "${2:-}" >> "$WARN_FILE"; return 0; }

# Scripted password entries. ui_password (the public wrapper the primitive calls)
# returns the next queued value per call; the count survives the $(...) subshell via
# a file so the re-prompt count is observable from the parent.
PW_COUNT_FILE=$(mktemp)
PW_SEQUENCE=()
ui_password() {
    local n
    n=$(cat "$PW_COUNT_FILE" 2>/dev/null || printf '0')
    printf '%s\n' "$((n + 1))" > "$PW_COUNT_FILE"
    printf '%s\n' "${PW_SEQUENCE[$n]:-}"
}

# 1) DEMO=1 short-circuit returns the default and never prompts.
printf '0\n' > "$PW_COUNT_FILE"; PW_SEQUENCE=("should-not-be-read")
out=$(DEMO=1 ui_password_validated "Admin password" "DemoDefault12" validate_admin_password)
assert_eq "DemoDefault12" "$out" "ui_password_validated: DEMO=1 returns the default"
assert_eq "0" "$(cat "$PW_COUNT_FILE")" "ui_password_validated: DEMO=1 does not prompt"

# 2) UI_DEMO=1 short-circuit honours the optional demo_default (4th) arg over $2.
printf '0\n' > "$PW_COUNT_FILE"
out=$(UI_DEMO=1 ui_password_validated "Admin password" "Default123456" validate_admin_password "DemoArg123456")
assert_eq "DemoArg123456" "$out" "ui_password_validated: UI_DEMO=1 returns the demo_default arg"
assert_eq "0" "$(cat "$PW_COUNT_FILE")" "ui_password_validated: UI_DEMO=1 does not prompt"

# 3) Valid on first entry: one prompt, returns the value.
printf '0\n' > "$PW_COUNT_FILE"; PW_SEQUENCE=("ValidPass123")
out=$(ui_password_validated "Admin password" "" validate_admin_password)
assert_eq "ValidPass123" "$out" "ui_password_validated: returns a valid first entry"
assert_eq "1" "$(cat "$PW_COUNT_FILE")" "ui_password_validated: valid first entry prompts once"

# 4) Invalid (too short) then valid: re-prompts exactly once, returns the valid value.
printf '0\n' > "$PW_COUNT_FILE"; PW_SEQUENCE=("short" "ValidPass123")
out=$(ui_password_validated "Admin password" "" validate_admin_password)
assert_eq "ValidPass123" "$out" "ui_password_validated: re-prompts past a too-short entry"
assert_eq "2" "$(cat "$PW_COUNT_FILE")" "ui_password_validated: one invalid entry triggers exactly one re-prompt"

# 5) Single-quote entry is rejected by the validator (which warns), then accepts valid.
printf '0\n' > "$PW_COUNT_FILE"; PW_SEQUENCE=("has'quote1234" "ValidPass123"); : > "$WARN_FILE"
out=$(ui_password_validated "Admin password" "" validate_admin_password)
assert_eq "ValidPass123" "$out" "ui_password_validated: single-quote entry rejected, then accepts valid"
assert_contains "$(cat "$WARN_FILE")" "single quote" "AUDIT: ui_password_validated surfaces the single-quote rejection"

rm -f "$WARN_FILE" "$PW_COUNT_FILE"
scenario_end "$CURRENT_SCENARIO"
summary

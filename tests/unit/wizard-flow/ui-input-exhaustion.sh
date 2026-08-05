#!/usr/bin/env bash
# tests/unit/wizard-flow/ui-input-exhaustion.sh
#
# ui_choose / ui_input_validated / ui_password_validated non-TTY EOF-exhaustion
# guards: piped EOF must SIGTERM the process group (not hang, not a generic
# 143), and the exhaustion latch must be a real two-consecutive-rejections
# detector, not a blunt off-TTY kill or a sticky one-shot.

# =========================================================================
# Test 0: ui_choose supports non-first visible defaults
# =========================================================================
choice=$(printf '\n' | UI_DEMO=0 UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Pick one:" "Compact" "Balanced" "Large")
assert_eq "Balanced" "$choice" "ui_choose: blank input uses visible default"

choice=$(printf '9\n' | UI_DEMO=0 UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Pick one:" "Compact" "Balanced" "Large")
assert_eq "Balanced" "$choice" "ui_choose: invalid input uses visible default"

# =========================================================================
# Test 0b: ui_choose on a piped EOF (no default) is diagnosable.
# =========================================================================
# A non-interactive driver whose input runs dry hits ui_choose's EOF branch:
# it SIGTERMs the process group to stop the looping parent. A parent that
# installs the documented non-interactive TERM trap must exit with the distinct
# UI_EXIT_INPUT_EXHAUSTED (3) — not a generic SIGTERM (143) — and must NOT hang.
# This mirrors mediastack:main / setup.sh:main without depending on either.
eof_rc=$(
    timeout 10 env -u UI_DEMO -u DEMO bash -c '
  _src=source
  "$_src" "'"$REPO_ROOT"'/scripts/lib/ui.sh"
  trap "exit ${UI_EXIT_INPUT_EXHAUSTED}" TERM
  choice=$(ui_choose "Pick one:" "A" "B" "C" </dev/null)
  echo "REACHED_PAST_CHOOSE=$choice"     # must NOT print — group-kill took us
' </dev/null >/dev/null 2>&1
    echo "$?"
)
assert_eq "3" "$eof_rc" "ui_choose: piped EOF maps to distinct exit code (input exhausted, not 143)"
if [[ "$eof_rc" == "124" ]]; then
    fail "ui_choose: piped EOF must not hang (timeout fired)"
fi

# =========================================================================
# Test 0c: ui_input_validated / ui_password_validated on a piped EOF.
# =========================================================================
# The validated-input siblings of Test 0b. When the offered default fails its
# validator and stdin is exhausted (non-TTY), the re-prompt loop must NOT spin
# forever: it detects the exhausted stream (the default rejected twice) and
# SIGTERMs the process group, exactly like ui_choose. A parent with the documented
# TERM trap exits UI_EXIT_INPUT_EXHAUSTED (3) — never 124 (hang) or 143 (generic
# kill). Real validators that reject empty (validate_admin_email,
# validate_ddns_password) drive the genuine trigger end to end. (timeout runs
# the probe in its own process group, so the group-kill cannot reach this runner.)
for _v93 in \
    "ui_input_validated|validate_admin_email" \
    "ui_password_validated|validate_ddns_password"; do
    _fn93="${_v93%%|*}"
    _val93="${_v93##*|}"
    rc93=$(
        timeout 10 env -u UI_DEMO -u DEMO bash -c '
      _src=source
      "$_src" "'"$REPO_ROOT"'/scripts/lib/ui.sh"
      "$_src" "'"$REPO_ROOT"'/scripts/lib/validators.sh"
      trap "exit ${UI_EXIT_INPUT_EXHAUSTED}" TERM
      out=$('"$_fn93"' "Required field" "" '"$_val93"' </dev/null)
      echo "REACHED_PAST_PROMPT=$out"     # must NOT print — group-kill took us
    ' </dev/null >/dev/null 2>&1
        echo "$?"
    )
    assert_eq "3" "$rc93" "$_fn93: non-TTY input exhaustion maps to exit 3 (not looping/143)"
    if [[ "$rc93" == "124" ]]; then
        fail "$_fn93: non-TTY input exhaustion must not hang (timeout fired)"
    fi
done
unset _v93 _fn93 _val93 rc93

# Counterpart to Test 0c: the exhaustion guard is a real EOF detector, NOT a blunt
# off-TTY kill. A non-TTY driver that sends a default-equal (blank) line and THEN a
# valid value must recover and return the valid value — the two-strike latch must
# not fire while usable input is still queued. This locks out a regression to a
# one-strike latch or a bare `[[ -t 0 ]]` guard (both would kill on the blank line).
got93=$(timeout 10 env -u UI_DEMO -u DEMO bash -c '
  _src=source
  "$_src" "'"$REPO_ROOT"'/scripts/lib/ui.sh"
  "$_src" "'"$REPO_ROOT"'/scripts/lib/validators.sh"
  trap "exit ${UI_EXIT_INPUT_EXHAUSTED}" TERM
  printf "\na@b.co\n" | ui_input_validated "Email" "" validate_admin_email
' 2>/dev/null)
assert_eq "a@b.co" "$got93" "ui_input_validated: non-TTY blank-then-valid returns the valid value (latch does not fire early)"
unset got93

# Second counterpart: the latch must be CONSECUTIVE, not sticky. A non-TTY driver
# that interleaves a default-equal (blank) line, a DISTINCT invalid line, another
# blank, and then a valid value must still return the valid value — a distinct line
# resets the streak. A sticky latch (armed once, never reset) would kill on the
# SECOND, non-adjacent blank and never reach the valid line. This pins the exhaustion
# detector to "default rejected twice in a row" rather than "default ever rejected".
got93b=$(timeout 10 env -u UI_DEMO -u DEMO bash -c '
  _src=source
  "$_src" "'"$REPO_ROOT"'/scripts/lib/ui.sh"
  "$_src" "'"$REPO_ROOT"'/scripts/lib/validators.sh"
  trap "exit ${UI_EXIT_INPUT_EXHAUSTED}" TERM
  printf "\nnotanemail\n\na@b.co\n" | ui_input_validated "Email" "" validate_admin_email
' 2>/dev/null)
assert_eq "a@b.co" "$got93b" "ui_input_validated: non-TTY interleaved default/distinct/default/valid recovers (latch is consecutive, not sticky)"
unset got93b

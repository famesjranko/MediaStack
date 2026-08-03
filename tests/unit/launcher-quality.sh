#!/usr/bin/env bash
# tests/unit/launcher-quality.sh
#
# Launcher coverage for the day-2 "Change quality profile (resolution & size)"
# action: re-pick resolution x size post-install, rewrite ONLY the quality
# sections of config.yml, then re-push to Sonarr/Radarr renaming the profile in
# place (no orphan). Verifies:
#   1. submenu_features renders the new option and routes it to the handler.
#   2. Apply wiring: the chosen (res, size) reach `wizard_apply.py --quality-only`
#      (config.yml's quality_profile is recomposed), and configure.sh is invoked
#      with QP_RENAME_FROM=<old profile name> — the signal that prevents orphaning.
#   3. "No change" (re-picking the current cell) short-circuits before any apply.
#   4. Guards: Docker unreachable / Sonarr|Radarr not running -> warn, no apply.
#   5a. Non-TTY no-change bail (UI_DEMO): with the current cell pre-selected, the
#      REAL picker returns it, so new == current and the handler bails before any
#      apply (no hang, no silent re-push).
#   5b. Non-TTY confirm bail (UI_DEMO): when the live name maps to NO cell, the
#      picker falls back to its default (which differs), so the REAL ui_confirm is
#      reached and DECLINES — still no apply.
#   6. Honest failure: when configure.sh records a rename failure via
#      QP_RENAME_STATUS, the handler reports "did NOT apply" — NOT a false success
#      (configure.sh keeps its never-abort exit-0 contract).
#   7. Unreadable current profile name -> bail before the picker (no sentinel
#      QP_RENAME_FROM that would refuse/duplicate downstream).
#   8. mktemp failure -> under-claim ("couldn't verify") instead of a false
#      success, since the per-app status file couldn't be created.
#
# The apply path runs the REAL wizard_apply.py against a SANDBOX config.yml copy
# (symlinked product code), with configure.sh stubbed to capture its env/args, so
# nothing real is mutated and the QP_RENAME_FROM wiring is observed directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-quality"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# 1. submenu_features renders the option and dispatches to the handler.
# ---------------------------------------------------------------------------
render_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  BAZARR_ENABLED=false; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
  submenu_features >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$render_out" "Change quality profile:" \
    "features: change-quality option is listed"

dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  ui_choose(){ echo "Change quality profile (resolution & size)"; }
  action_change_quality(){ echo DISPATCH_QUALITY; exit 0; }
  BAZARR_ENABLED=false; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
  submenu_features 2>&1
' 2>&1)
assert_contains "$dispatch_out" "DISPATCH_QUALITY" \
    "features: change-quality label routes to action_change_quality"

# ---------------------------------------------------------------------------
# 2. Apply wiring — sandbox SCRIPT_DIR with REAL wizard_apply.py (symlinked) on a
# config.yml COPY + a configure.sh stub that captures QP_RENAME_FROM and args.
# run_quality <pick-res> <pick-size> <seed-res> <seed-size>
#   -> "=== NAME ===" recomposed config name, "=== CAP ===" captured configure call.
# ---------------------------------------------------------------------------
run_quality() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" \
        PICK_RES="$1" PICK_SIZE="$2" SEED_RES="$3" SEED_SIZE="$4" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
    mkdir -p "$tmp/scripts/setup"
    ln -s "$REPO_ROOT/scripts/setup/wizard_apply.py" "$tmp/scripts/setup/wizard_apply.py"
    ln -s "$REPO_ROOT/scripts/setup/presets.yml" "$tmp/scripts/setup/presets.yml"
    cp "$REPO_ROOT/config/examples/config.yml" "$tmp/config.yml"
    # Seed the current cell so cfg_field reports a known "old" profile name.
    python3 "$tmp/scripts/setup/wizard_apply.py" --quality-only \
      --resolution "$SEED_RES" --size "$SEED_SIZE" --config "$tmp/config.yml" >/dev/null 2>&1
    cat > "$tmp/scripts/configure.sh" <<STUB
#!/usr/bin/env bash
echo "CONFIGURE QP_RENAME_FROM=[\${QP_RENAME_FROM:-<unset>}] ARGS=\$*" >> "$CAPTURE"
STUB
    chmod +x "$tmp/scripts/configure.sh"

    _docker_reachable(){ return 0; }
    _service_is_running(){ return 0; }
    # Deterministic pick via nameref, ignoring the menu entirely.
    quality_select_pick(){ local -n _r=$1; local -n _s=$2; _r="$PICK_RES"; _s="$PICK_SIZE"; return 0; }
    ui_confirm(){ return 0; }
    ui_log(){ :; }; pause_for_menu(){ :; }
    _show_action_result(){ echo "RESULT rc=$1 label=$2" >> "$CAPTURE"; }

    action_change_quality
    echo "=== NAME ==="
    CONFIG_FILE="$tmp/config.yml" cfg_field "quality_profile.name"
    echo "=== CAP ==="; cat "$CAPTURE"
    rm -rf "$tmp"
  ' 2>&1
}

# Change 1080p balanced -> 720p large: config recomposed + configure.sh gets the
# OLD name as QP_RENAME_FROM (the no-orphan signal) and the right --only set.
applied=$(run_quality 720p large 1080p balanced)
assert_contains "$applied" "720p Large" \
    "apply: config.yml quality_profile recomposed to the chosen cell"
assert_contains "$applied" "QP_RENAME_FROM=[1080p Balanced]" \
    "apply: configure.sh receives the OLD profile name as QP_RENAME_FROM (no orphan)"
assert_contains "$applied" "ARGS=--only sonarr,radarr" \
    "apply: re-push scoped to sonarr,radarr"
assert_contains "$applied" "RESULT rc=0" \
    "apply: success reported"

# 3. No change: re-pick the seeded cell -> short-circuit, no configure.sh call.
nochg=$(run_quality 1080p balanced 1080p balanced)
if grep -q "CONFIGURE" <<<"$nochg"; then
    fail "no-change: re-picking the current cell skips the re-push entirely"
else
    pass "no-change: re-picking the current cell skips the re-push entirely"
fi

# ---------------------------------------------------------------------------
# 4. Guards: Docker unreachable / an *arr not running -> warn, no apply.
# ---------------------------------------------------------------------------
run_guard() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" GUARD="$1" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
    eval "$GUARD"
    quality_select_pick(){ echo "PICKER_RAN" >> "$CAPTURE"; local -n _r=$1; local -n _s=$2; _r=720p; _s=large; }
    ui_log(){ :; }; pause_for_menu(){ :; }
    _show_action_result(){ :; }
    action_change_quality
    cat "$CAPTURE"; rm -rf "$tmp"
  ' 2>&1
}
guard_docker=$(run_guard '_docker_reachable(){ return 1; }; _service_is_running(){ return 0; }')
if grep -q "PICKER_RAN" <<<"$guard_docker"; then
    fail "guard: Docker unreachable bails before the picker"
else
    pass "guard: Docker unreachable bails before the picker"
fi
guard_arr=$(run_guard '_docker_reachable(){ return 0; }; _service_is_running(){ [[ "$1" == sonarr ]] && return 0 || return 1; }')
if grep -q "PICKER_RAN" <<<"$guard_arr"; then
    fail "guard: Radarr not running bails before the picker"
else
    pass "guard: Radarr not running bails before the picker"
fi

# ---------------------------------------------------------------------------
# 5a. Non-TTY no-change bail (UI_DEMO): REAL picker + REAL ui_confirm, closed
# stdin. The launcher pre-selects the CURRENT cell, so the picker returns it and
# new == current -> the handler bails at the no-change short-circuit (before the
# confirm), never calling configure.sh. The test completing at all is the
# no-hang proof.
# ---------------------------------------------------------------------------
demo_out=$(UI_DEMO=1 MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
  mkdir -p "$tmp/scripts/setup"
  ln -s "$REPO_ROOT/scripts/setup/wizard_apply.py" "$tmp/scripts/setup/wizard_apply.py"
  ln -s "$REPO_ROOT/scripts/setup/presets.yml" "$tmp/scripts/setup/presets.yml"
  cp "$REPO_ROOT/config/examples/config.yml" "$tmp/config.yml"
  # Seed a known cell; the launcher pre-selects it, so the picker returns the
  # same cell and the no-change bail fires.
  python3 "$tmp/scripts/setup/wizard_apply.py" --quality-only \
    --resolution 720p --size compact --config "$tmp/config.yml" >/dev/null 2>&1
  cat > "$tmp/scripts/configure.sh" <<"STUB"
#!/usr/bin/env bash
echo "CONFIGURE_CALLED" >> "$CAPTURE"
STUB
  chmod +x "$tmp/scripts/configure.sh"
  _docker_reachable(){ return 0; }
  _service_is_running(){ return 0; }
  pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1" >> "$CAPTURE"; }
  action_change_quality </dev/null >/dev/null 2>&1
  echo "RETURNED"; cat "$CAPTURE"; rm -rf "$tmp"
' 2>&1)
assert_contains "$demo_out" "RETURNED" \
    "non-TTY no-change: handler terminates deterministically (no hang)"
if grep -q "CONFIGURE_CALLED" <<<"$demo_out"; then
    fail "non-TTY no-change: current cell pre-selected -> no re-push"
else
    pass "non-TTY no-change: current cell pre-selected -> no re-push"
fi

# ---------------------------------------------------------------------------
# 5b. Non-TTY confirm bail (UI_DEMO): when the live name maps to NO cell, the
# picker cannot pre-select it and falls back to its own default (1080p balanced),
# which differs from the current name -> the REAL ui_confirm IS reached and,
# under UI_DEMO with default "no", DECLINES. Still no apply, no hang. This
# exercises the confirm bail that 5a's no-change bail never reaches. Only
# cfg_field is stubbed (to simulate a legacy/hand-edited stored name); the picker
# and ui_confirm are the real product code.
# ---------------------------------------------------------------------------
demo_confirm=$(UI_DEMO=1 MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
  mkdir -p "$tmp/scripts/setup"
  ln -s "$REPO_ROOT/scripts/setup/wizard_apply.py" "$tmp/scripts/setup/wizard_apply.py"
  ln -s "$REPO_ROOT/scripts/setup/presets.yml" "$tmp/scripts/setup/presets.yml"
  cp "$REPO_ROOT/config/examples/config.yml" "$tmp/config.yml"
  cfg_field(){ echo "Legacy Custom"; }   # maps to no (res,size) cell
  cat > "$tmp/scripts/configure.sh" <<"STUB"
#!/usr/bin/env bash
echo "CONFIGURE_CALLED" >> "$CAPTURE"
STUB
  chmod +x "$tmp/scripts/configure.sh"
  _docker_reachable(){ return 0; }
  _service_is_running(){ return 0; }
  pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1" >> "$CAPTURE"; }
  action_change_quality </dev/null >/dev/null 2>&1
  echo "RETURNED"; cat "$CAPTURE"; rm -rf "$tmp"
' 2>&1)
assert_contains "$demo_confirm" "RETURNED" \
    "non-TTY confirm: handler terminates deterministically (no hang)"
if grep -q "CONFIGURE_CALLED" <<<"$demo_confirm"; then
    fail "non-TTY confirm: default-no ui_confirm declines -> no re-push"
else
    pass "non-TTY confirm: default-no ui_confirm declines -> no re-push"
fi

# ---------------------------------------------------------------------------
# 6. Honest failure: configure.sh records a rename failure via QP_RENAME_STATUS
# (mimicking configure_quality_profile's refuse/fail path). The handler must
# report "did NOT apply" — NOT "completed successfully" — even though
# configure.sh exits 0 (its deliberate never-abort contract).
# ---------------------------------------------------------------------------
fail_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"
  mkdir -p "$tmp/scripts/setup"
  ln -s "$REPO_ROOT/scripts/setup/wizard_apply.py" "$tmp/scripts/setup/wizard_apply.py"
  ln -s "$REPO_ROOT/scripts/setup/presets.yml" "$tmp/scripts/setup/presets.yml"
  cp "$REPO_ROOT/config/examples/config.yml" "$tmp/config.yml"
  python3 "$tmp/scripts/setup/wizard_apply.py" --quality-only \
    --resolution 1080p --size balanced --config "$tmp/config.yml" >/dev/null 2>&1
  # The stub exits 0 (never-abort) but records radarr as un-renamed, exactly as
  # configure_quality_profile would via _qp_record_rename_failure.
  cat > "$tmp/scripts/configure.sh" <<"STUB"
#!/usr/bin/env bash
printf "radarr\n" >> "$QP_RENAME_STATUS"
exit 0
STUB
  chmod +x "$tmp/scripts/configure.sh"
  _docker_reachable(){ return 0; }
  _service_is_running(){ return 0; }
  quality_select_pick(){ local -n _r=$1; local -n _s=$2; _r="720p"; _s="large"; return 0; }
  ui_confirm(){ return 0; }
  pause_for_menu(){ :; }
  action_change_quality 2>&1
  rm -rf "$tmp"
' 2>&1)
assert_contains "$fail_out" "did NOT apply to: radarr" \
    "honest-failure: recorded rename failure is surfaced to the user"
if grep -q "completed successfully" <<<"$fail_out"; then
    fail "honest-failure: a failed rename is NOT reported as success"
else
    pass "honest-failure: a failed rename is NOT reported as success"
fi

# ---------------------------------------------------------------------------
# 7. Unreadable current profile name -> bail before the picker (never feed a
# sentinel as QP_RENAME_FROM, which would refuse/duplicate downstream).
# ---------------------------------------------------------------------------
noname_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
  _docker_reachable(){ return 0; }
  _service_is_running(){ return 0; }
  cfg_field(){ echo ""; }   # config.yml has no readable quality_profile.name
  quality_select_pick(){ echo "PICKER_RAN" >> "$CAPTURE"; local -n _r=$1; local -n _s=$2; _r=720p; _s=large; }
  ui_log(){ :; }; pause_for_menu(){ :; }
  _show_action_result(){ :; }
  action_change_quality
  cat "$CAPTURE"; rm -rf "$tmp"
' 2>&1)
if grep -q "PICKER_RAN" <<<"$noname_out"; then
    fail "guard: unreadable current profile name bails before the picker"
else
    pass "guard: unreadable current profile name bails before the picker"
fi

# ---------------------------------------------------------------------------
# 8. mktemp failure: the status file can't be created, so the re-push outcome
# can't be captured. The handler must UNDER-claim ("couldn't verify") rather
# than print a false "completed successfully". mktemp is stubbed to fail AFTER
# the sandbox dir is created, so only the in-handler status-file mktemp fails.
# ---------------------------------------------------------------------------
mktemp_fail=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"
  mkdir -p "$tmp/scripts/setup"
  ln -s "$REPO_ROOT/scripts/setup/wizard_apply.py" "$tmp/scripts/setup/wizard_apply.py"
  ln -s "$REPO_ROOT/scripts/setup/presets.yml" "$tmp/scripts/setup/presets.yml"
  cp "$REPO_ROOT/config/examples/config.yml" "$tmp/config.yml"
  python3 "$tmp/scripts/setup/wizard_apply.py" --quality-only \
    --resolution 1080p --size balanced --config "$tmp/config.yml" >/dev/null 2>&1
  cat > "$tmp/scripts/configure.sh" <<"STUB"
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$tmp/scripts/configure.sh"
  _docker_reachable(){ return 0; }
  _service_is_running(){ return 0; }
  quality_select_pick(){ local -n _r=$1; local -n _s=$2; _r="720p"; _s="large"; return 0; }
  ui_confirm(){ return 0; }
  pause_for_menu(){ :; }
  mktemp(){ return 1; }   # only the handler status-file mktemp fails now
  action_change_quality 2>&1
  rm -rf "$tmp"
' 2>&1)
assert_contains "$mktemp_fail" "verify the result" \
    "mktemp-failure: handler under-claims (couldn't verify) instead of false success"
if grep -q "completed successfully" <<<"$mktemp_fail"; then
    fail "mktemp-failure: no false 'completed successfully'"
else
    pass "mktemp-failure: no false 'completed successfully'"
fi

scenario_end "$CURRENT_SCENARIO"
summary

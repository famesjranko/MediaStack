#!/usr/bin/env bash
# tests/unit/launcher-bandwidth.sh
#
# Launcher coverage for the day-2 "Adjust bandwidth limits (qBittorrent)"
# action: a guided knob to change qBittorrent download/upload speed limits (MB/s)
# post-install, without re-running the wizard or hand-editing config. Verifies:
#   1. submenu_features renders the new option and routes it to the handler.
#   2. Apply-FIRST / persist-on-SUCCESS: qbt_set_speed_limits is called with the
#      new MB/s values, and .env is rewritten ONLY when the live apply succeeds.
#   3. On apply failure, .env is left untouched (no .env<->daemon drift).
#   4. "No change" short-circuits before any apply.
#   5. Guards: Docker unreachable / qBittorrent not running -> warn, no apply.
#   6. Non-TTY determinism: the REAL ui_input_validated against a closed stdin
#      returns the numeric default (no re-prompt loop), so the handler terminates
#      and takes the deterministic "No change" path with NO API call.
#
# The launcher is sourced (its BASH_SOURCE guard skips main()); handlers run
# against a sandbox SCRIPT_DIR with stubbed externals so real commands/.env writes
# are captured. Mirrors tests/unit/launcher-features.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-bandwidth"
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
assert_contains "$render_out" "Adjust bandwidth:" \
    "features: bandwidth option is listed"

dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  ui_choose(){ echo "Adjust bandwidth limits (qBittorrent)"; }
  action_adjust_bandwidth(){ echo DISPATCH_BANDWIDTH; exit 0; }
  BAZARR_ENABLED=false; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
  submenu_features 2>&1
' 2>&1)
assert_contains "$dispatch_out" "DISPATCH_BANDWIDTH" \
    "features: bandwidth label routes to action_adjust_bandwidth"

# ---------------------------------------------------------------------------
# 2-4. Handler behaviour in a sandbox — capture qbt_set_speed_limits args + .env.
# run_band <new_dl> <new_ul> <qbt_rc> <init-env>  -> "=== ENV ===" .env then
# "=== CAP ===" captured calls. ui_input_validated/ui_confirm stubbed; the REAL
# _set_env_var/_reload_env run so .env writes are genuine.
# ---------------------------------------------------------------------------
run_band() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" \
        NEW_DL="$1" NEW_UL="$2" QBT_RC="$3" INIT="$4" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
    printf "%s\n" "$INIT" > "$tmp/.env"
    _docker_reachable(){ return 0; }
    _service_is_running(){ return 0; }
    ui_input_validated(){ case "$1" in *Download*) echo "$NEW_DL";; *Upload*) echo "$NEW_UL";; *) echo "";; esac; }
    ui_confirm(){ return 0; }
    # Pre-defined stub: the handler will find it via `type` and skip sourcing
    # the qBittorrent module. Captures args + returns the requested rc.
    qbt_set_speed_limits(){ echo "QBT_SET $*" >> "$CAPTURE"; return "${QBT_RC:-0}"; }
    ui_log(){ :; }; launcher_pause_for_menu(){ :; }
    _show_action_result(){ echo "RESULT rc=$1 label=$2" >> "$CAPTURE"; }
    _reload_env                       # load INIT into shell vars
    action_adjust_bandwidth
    echo "=== ENV ==="; cat "$tmp/.env"
    echo "=== CAP ==="; cat "$CAPTURE"
    rm -rf "$tmp"
  ' 2>&1
}

# 2. Success: apply with new values, then persist (single-quoted) on rc 0.
ok=$(run_band "5" "2" "0" $'QBT_DL_LIMIT=0\nQBT_UL_LIMIT=0')
assert_contains "$ok" "QBT_SET 5 2" "apply: qbt_set_speed_limits called with new DL/UL MB/s"
assert_contains "$ok" "QBT_DL_LIMIT='5'" "persist: QBT_DL_LIMIT written on success (single-quoted)"
assert_contains "$ok" "QBT_UL_LIMIT='2'" "persist: QBT_UL_LIMIT written on success (single-quoted)"
assert_contains "$ok" "RESULT rc=0" "apply: success reported"

# 3. Failure: apply returns 1 -> .env left UNTOUCHED (no drift ahead of daemon).
fail=$(run_band "5" "2" "1" $'QBT_DL_LIMIT=0\nQBT_UL_LIMIT=0')
assert_contains "$fail" "QBT_SET 5 2" "fail: apply still attempted"
assert_contains "$fail" "RESULT rc=1" "fail: failure reported"
if grep -q "QBT_DL_LIMIT='5'\|QBT_UL_LIMIT='2'" <<<"$fail"; then
    fail "fail: .env NOT rewritten when the live apply fails (apply-first, persist-on-success)"
else
    pass "fail: .env NOT rewritten when the live apply fails (apply-first, persist-on-success)"
fi
assert_contains "$fail" "QBT_DL_LIMIT=0" "fail: .env keeps the old value"

# 4. No change: new == current for both -> short-circuit, no apply, no persist.
nochg=$(run_band "0" "0" "0" $'QBT_DL_LIMIT=0\nQBT_UL_LIMIT=0')
if grep -q "QBT_SET" <<<"$nochg"; then
    fail "no-change: equal values skip the apply entirely"
else
    pass "no-change: equal values skip the apply entirely"
fi

# ---------------------------------------------------------------------------
# 5. Guards: Docker unreachable / qBittorrent not running -> warn, no apply.
# ---------------------------------------------------------------------------
run_guard() {
    # $1 = body that defines _docker_reachable / _service_is_running
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" GUARD="$1" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
    printf "QBT_DL_LIMIT=0\nQBT_UL_LIMIT=0\n" > "$tmp/.env"
    eval "$GUARD"
    qbt_set_speed_limits(){ echo "QBT_SET $*" >> "$CAPTURE"; }
    ui_input_validated(){ echo "9"; }   # would change if reached
    ui_confirm(){ return 0; }
    launcher_pause_for_menu(){ :; }
    WARN=""; ui_log(){ [[ "$1" == "warn" ]] && WARN="$WARN $*"; echo "$*"; }
    _reload_env
    action_adjust_bandwidth
    cat "$CAPTURE"
    rm -rf "$tmp"
  ' 2>&1
}
g_docker=$(run_guard '_docker_reachable(){ return 1; }; _service_is_running(){ return 0; }')
assert_contains "$g_docker" "Docker isn't reachable" "guard: Docker unreachable warns"
if grep -q "QBT_SET" <<<"$g_docker"; then fail "guard: Docker unreachable -> no apply"; else pass "guard: Docker unreachable -> no apply"; fi

g_qbt=$(run_guard '_docker_reachable(){ return 0; }; _service_is_running(){ return 1; }')
assert_contains "$g_qbt" "qBittorrent isn't running" "guard: qBittorrent down warns"
if grep -q "QBT_SET" <<<"$g_qbt"; then fail "guard: qBittorrent down -> no apply"; else pass "guard: qBittorrent down -> no apply"; fi

# ---------------------------------------------------------------------------
# 6. Non-TTY determinism: REAL ui_input_validated against closed stdin. The
# numeric default (current value) passes validate_mb_per_sec, so EOF returns it
# with NO re-prompt loop -> handler TERMINATES (timeout rc 0, never 124) and
# takes the "No change" path with NO API call.
# ---------------------------------------------------------------------------
# run_real_input <init-env> -> drives action_adjust_bandwidth with the REAL
# ui_input_validated against closed stdin, under a timeout. Prints TIMEOUT_RC + cap.
run_real_input() {
    local out trc
    # shellcheck disable=SC2016
    out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" INIT="$1" timeout 20 bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
      printf "%s\n" "$INIT" > "$tmp/.env"
      _docker_reachable(){ return 0; }
      _service_is_running(){ return 0; }
      qbt_set_speed_limits(){ echo "QBT_SET $*" >> "$CAPTURE"; }
      ui_confirm(){ return 0; }
      ui_log(){ :; }; launcher_pause_for_menu(){ :; }; _show_action_result(){ :; }
      # ui_input_validated is the REAL primitive — its read sees EOF from </dev/null.
      _reload_env
      action_adjust_bandwidth </dev/null
      cat "$CAPTURE"
      rm -rf "$tmp"
    ' 2>&1)
    trc=$?
    printf "TIMEOUT_RC=%s\n%s\n" "$trc" "$out"
}

# 6a. Well-formed .env: numeric default -> EOF returns it, no change, no API call.
real_out=$(run_real_input $'QBT_DL_LIMIT=3\nQBT_UL_LIMIT=1')
assert_contains "$real_out" "TIMEOUT_RC=0" \
    "non-TTY: real ui_input_validated on closed stdin terminates (no re-prompt hang)"
if grep -q "QBT_SET" <<<"$real_out"; then
    fail "non-TTY: EOF -> default (unchanged) = No change, no API call"
else
    pass "non-TTY: EOF -> default (unchanged) = No change, no API call"
fi

# 6b. HOSTILE .env: a hand-edited non-numeric value must NOT become a failing
# prompt default (that would loop forever on EOF). The action sanitizes it to 0,
# so the EOF default validates and the handler still terminates deterministically.
hostile_out=$(run_real_input $'QBT_DL_LIMIT=10mb\nQBT_UL_LIMIT=5 ')
assert_contains "$hostile_out" "TIMEOUT_RC=0" \
    "non-TTY: non-numeric .env default is sanitized -> terminates (no re-prompt hang)"
if grep -q "QBT_SET" <<<"$hostile_out"; then
    fail "non-TTY: sanitized garbage default = No change, no API call"
else
    pass "non-TTY: sanitized garbage default = No change, no API call"
fi

scenario_end "$CURRENT_SCENARIO"
summary

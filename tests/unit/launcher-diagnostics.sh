#!/usr/bin/env bash
# tests/unit/launcher-diagnostics.sh
#
# Covers the day-2 Diagnostics submenu speed-test option: it renders, dispatches
# to diag_speedtest, and diag_speedtest reports the measured Mbps on success /
# warns on failure. The launcher is sourced (BASH_SOURCE guard skips main()).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-diagnostics"
scenario_begin "$CURRENT_SCENARIO"

# --- 1. Diagnostics submenu offers "Run speed test" ------------------------
render_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  _cached_public_ip(){ echo ""; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  submenu_diagnostics >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$render_out" "Run speed test" "diagnostics: speed test option shown"

# --- 2. It dispatches to diag_speedtest ------------------------------------
route_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  _cached_public_ip(){ echo ""; }
  ui_choose(){ echo "Run speed test"; }
  diag_speedtest(){ echo DISPATCH_SPEEDTEST; exit 0; }
  submenu_diagnostics 2>&1
' 2>&1)
assert_contains "$route_out" "DISPATCH_SPEEDTEST" "diagnostics: speed test routes to diag_speedtest"

# --- 3. diag_speedtest reports the measured speed on success ---------------
ok_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  net_run_speedtest(){ _NET_DL_MBPS=101; _NET_UL_MBPS=37; return 0; }
  ui_spin_fg(){ shift; "$@"; }        # strip the label, run the command
  ui_log(){ shift; echo "$*"; }
  diag_speedtest
' 2>&1)
assert_contains "$ok_out" "Download: 101 Mbps | Upload: 37 Mbps" "diagnostics: reports measured Mbps on success"

# --- 4. Graceful warning when the measurement fails ------------------------
fail_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  net_run_speedtest(){ return 1; }
  ui_spin_fg(){ shift; "$@"; }
  ui_log(){ shift; echo "$*"; }
  diag_speedtest
' 2>&1)
assert_contains "$fail_out" "Speed test unavailable" "diagnostics: warns gracefully when the test fails"

# --- 4. Status counts an exited container ----------------------------------
# Given compose lists two containers with -a but only one running
# When the running summary is computed
# Then it reports 1/2, not 1/1
count_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  profiles_build_args(){ :; }
  docker(){
    # Real compose omits exited containers unless -a is passed.
    local all=0 running=0 a
    for a in "$@"; do [[ "$a" == "-a" ]] && all=1; [[ "$a" == "status=running" ]] && running=1; done
    if ((running)) || ! ((all)); then printf "jellyfin-ok\n"; else printf "jellyfin-ok\njellyfin\n"; fi
  }
  _compose_running_summary
' 2>&1)
assert_eq "1/2" "$count_out" "diagnostics: running summary counts an exited container in the total"

scenario_end "$CURRENT_SCENARIO"
summary

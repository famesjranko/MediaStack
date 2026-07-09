#!/usr/bin/env bash
# tests/unit/launcher-ddns.sh
#
# Hermetic launcher coverage for the day-2 "Update DDNS provider / credentials" support code
# (#238) that the PTY scenario (tests/scenarios/wizard-ui-ddns.sh) STUBS and so
# never exercises for real:
#   1. _ddns_configured   — the row/guard predicate (provider key AND config.json).
#   2. _ddns_status       — the banner/system-box classification (off/stopped/
#                           unresolved/stale/ok) from cached DDNS-record vs WAN IP.
#   3. _ddns_restart_and_check — the REAL restart + `.State.Status` up-check poll,
#                           incl. the `restart: unless-stopped` crash-loop-flap case
#                           the ADR justifies but the PTY scenario stubs out.
#   4. submenu_features gating — the "Update DDNS provider" row appears only when
#                           remote is ready AND ddns is configured.
#
# The launcher is sourced (its BASH_SOURCE guard skips main()); externals (docker,
# sleep) are stubbed so the checks run instantly and deterministically.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-ddns"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# 1. _ddns_configured — true ONLY when DDNS_PROVIDER is set AND config.json exists.
# ---------------------------------------------------------------------------
run_configured() {
  # $1 = DDNS_PROVIDER value, $2 = "yes"/"no" seed config.json
  MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DPROV="$1" SEED="$2" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"
    DDNS_PROVIDER="$DPROV"
    if [[ "$SEED" == "yes" ]]; then mkdir -p "$tmp/config/ddns-updater"; echo "{}" > "$tmp/config/ddns-updater/config.json"; fi
    if _ddns_configured; then echo "CONFIGURED"; else echo "NOT"; fi
    rm -rf "$tmp"
  ' 2>&1
}
assert_contains "$(run_configured dynu yes)" "CONFIGURED" "_ddns_configured: provider + config.json -> true"
assert_contains "$(run_configured dynu no)"  "NOT"        "_ddns_configured: provider but no config.json -> false"
assert_contains "$(run_configured '' yes)"   "NOT"        "_ddns_configured: config.json but no provider -> false"

# ---------------------------------------------------------------------------
# 2. _ddns_status — classification from stubbed configured/running/cached-IP.
# ---------------------------------------------------------------------------
run_status() {
  # $1 configured(0/1) $2 running(0/1) $3 cached-ddns-ip $4 wan-ip
  MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" C="$1" R="$2" DIP="$3" WAN="$4" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    _ddns_configured(){ return "$C"; }
    _service_is_running(){ return "$R"; }
    _resolve_ddns_ip(){ printf "%s" "$DIP"; }
    _ddns_status "$WAN"; echo
  ' 2>&1
}
assert_contains "$(run_status 1 0 '' '')"                 "off"          "_ddns_status: not configured -> off"
assert_contains "$(run_status 0 1 '' '')"                 "stopped"      "_ddns_status: configured but not running -> stopped"
assert_contains "$(run_status 0 0 '' 1.2.3.4)"            "unresolved"   "_ddns_status: running, no A-record -> unresolved"
assert_contains "$(run_status 0 0 1.2.3.4 1.2.3.4)"       "ok:1.2.3.4"   "_ddns_status: record == WAN -> ok:<ip>"
assert_contains "$(run_status 0 0 1.2.3.4 5.6.7.8)"       "stale:1.2.3.4" "_ddns_status: record != WAN -> stale:<ip>"

# ---------------------------------------------------------------------------
# 3. _ddns_restart_and_check — REAL function, stubbed docker + sleep.
#    DOCKER_RESTART_RC controls `docker restart`; STATUSES is a space-list the
#    inspect stub pops in order (file-backed so it survives the $() subshell).
# ---------------------------------------------------------------------------
run_restart_check() {
  # $1 = docker-restart rc, $2 = space-list of .State.Status samples
  MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" RC="$1" STATUSES="$2" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    idx=$(mktemp); echo 0 > "$idx"; export IDX="$idx"
    read -r -a _S <<< "$STATUSES"
    sleep(){ :; }
    docker(){
      case "$1" in
        restart) return "$RC" ;;
        inspect)
          local n; n=$(cat "$IDX"); echo $((n+1)) > "$IDX"
          local last=$(( ${#_S[@]} - 1 ))
          (( n > last )) && n=$last
          printf "%s" "${_S[$n]}" ;;
        *) return 0 ;;
      esac
    }
    _ddns_restart_and_check; echo "RC=$?"
    rm -f "$idx"
  ' 2>&1
}
assert_contains "$(run_restart_check 0 'running running running')" "RC=0" "_ddns_restart_and_check: restart ok + steadily running -> 0"
assert_contains "$(run_restart_check 1 'running running running')" "RC=1" "_ddns_restart_and_check: docker restart fails -> 1"
assert_contains "$(run_restart_check 0 'running exited restarting')" "RC=1" "_ddns_restart_and_check: crash-loop flap (running then exited) -> 1"
assert_contains "$(run_restart_check 0 'exited exited exited')"     "RC=1" "_ddns_restart_and_check: never comes up -> 1"

# ---------------------------------------------------------------------------
# 4. submenu_features gating — the DDNS row appears only when remote is ready
#    (recovery_menu_remote_available FALSE) AND ddns is configured.
# ---------------------------------------------------------------------------
run_row() {
  # $1 = _ddns_configured rc (0 = configured)
  MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DC="$1" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    LABELS=$(mktemp)
    render_banner(){ :; }
    ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
    recovery_menu_remote_available(){ return 1; }   # remote READY
    recovery_menu_transcoding_available(){ return 1; }
    storage_is_nas(){ return 1; }
    _ddns_configured(){ return "$DC"; }
    DDNS_PROVIDER=dynu
    BAZARR_ENABLED=false; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
    submenu_features >/dev/null 2>&1
    tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
  ' 2>&1
}
assert_contains "$(run_row 0)" "Update DDNS provider" "features: DDNS row shown when remote ready + configured"
row_off="$(run_row 1)"
if grep -q "Update DDNS provider" <<<"$row_off"; then
  fail "features: DDNS row hidden when not configured"
else
  pass "features: DDNS row hidden when not configured"
fi

# ---------------------------------------------------------------------------
# 5. render_banner DDNS line — emitted (with the confirmed IP) when the status is
#    ok/stale/unresolved; SKIPPED when off/stopped. Heavy deps stubbed; colour off.
# ---------------------------------------------------------------------------
run_banner() {
  # $1 = _ddns_status echo value
  MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DST="$1" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    is_installed(){ return 0; }
    _docker_reachable(){ return 0; }
    _compose_running_summary(){ echo "19/20"; }
    _detect_lan_ip(){ echo "192.168.1.2"; }
    _detect_gateway(){ echo "192.168.1.1"; }
    _cached_public_ip(){ _MS_PUBLIC_IP="1.2.3.4"; }   # match production: set the global, do not echo
    _ddns_status(){ printf "%s" "$DST"; }
    ui_box(){ shift; printf "%s\n" "$@"; }
    DOMAIN="mybox.example.com"; GREEN=""; NC=""
    render_banner
  ' 2>&1
}
banner_ok="$(run_banner ok:1.2.3.4)"
assert_contains "$banner_ok" "DDNS:"   "banner: DDNS line rendered when configured+running"
assert_contains "$banner_ok" "1.2.3.4" "banner: DDNS line shows the confirmed IP"
banner_stale="$(run_banner stale:9.9.9.9)"
assert_contains "$banner_stale" "9.9.9.9"     "banner: mismatch shows the stale confirmed IP"
assert_contains "$banner_stale" "propagating" "banner: mismatch flags propagating"
banner_off="$(run_banner off)"
if grep -q "DDNS:" <<<"$banner_off"; then
  fail "banner: no DDNS line when off/stopped"
else
  pass "banner: no DDNS line when off/stopped"
fi

# ---------------------------------------------------------------------------
# 6. "Refresh status" main-menu row: present, and its dispatch invalidates the
#    session IP caches so the next banner render re-detects. (menu_post is single
#    pass — the loop lives in main() — so the flags can be read after it returns.)
# ---------------------------------------------------------------------------
menu_labels=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  is_installed(){ return 0; }
  storage_is_nas(){ return 1; }
  _warn_gpu_runtime_fallback(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  menu_post >/dev/null 2>&1
  cat "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$menu_labels" "Refresh status" "menu_post: Refresh status row present"

refresh_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  is_installed(){ return 0; }
  storage_is_nas(){ return 1; }
  _warn_gpu_runtime_fallback(){ :; }
  ui_choose(){ echo "Refresh status (re-check public IP & DDNS)"; }
  _MS_PUBLIC_IP_CHECKED=1
  menu_post >/dev/null 2>&1
  echo "PUB=$_MS_PUBLIC_IP_CHECKED"
' 2>&1)
assert_contains "$refresh_out" "PUB=0" "menu_post: Refresh status invalidates the public-IP cache"

# ---------------------------------------------------------------------------
# 7. render_banner cross-render probe budget (the #245 scope bug). Calling
#    render_banner TWICE in the SAME shell (what main()'s loop does) must:
#      - probe the public IP ONCE  — _cached_public_ip is primed in parent scope,
#        so the warm _MS_PUBLIC_IP_CHECKED flag survives the second render;
#      - resolve the DDNS record TWICE — it is intentionally live per render, so
#        propagation self-heals without a manual "Refresh status".
#    File-backed counters survive the $() subshells the getters run inside.
#    This exercises the REAL render path, not a getter-in-parent-scope shortcut —
#    the earlier scope bug (flag lost in $()) would show IP=2 here.
# ---------------------------------------------------------------------------
probe_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  export IPF; IPF=$(mktemp); export DIGF; DIGF=$(mktemp); echo 0 > "$IPF"; echo 0 > "$DIGF"
  net_detect_public_ip(){ echo $(( $(cat "$IPF") + 1 )) > "$IPF"; _NET_PUBLIC_IP="1.2.3.4"; return 0; }
  _resolve_ddns_ip(){ echo $(( $(cat "$DIGF") + 1 )) > "$DIGF"; printf "1.2.3.4"; }
  is_installed(){ return 0; }
  _docker_reachable(){ return 0; }
  _ddns_configured(){ return 0; }
  _service_is_running(){ return 0; }
  _compose_running_summary(){ echo "19/20"; }
  _detect_lan_ip(){ echo "192.168.1.2"; }
  _detect_gateway(){ echo "192.168.1.1"; }
  ui_box(){ :; }
  DOMAIN="mybox.example.com"; GREEN=""; YELLOW=""; NC=""
  render_banner; render_banner
  echo "IP=$(cat "$IPF") DIG=$(cat "$DIGF")"
  rm -f "$IPF" "$DIGF"
' 2>&1)
assert_contains "$probe_out" "IP=1"  "render_banner: public IP probed ONCE across two renders (cache persists in parent scope)"
assert_contains "$probe_out" "DIG=2" "render_banner: DDNS resolved live EACH render (self-heals propagation)"

scenario_end "$CURRENT_SCENARIO"
summary

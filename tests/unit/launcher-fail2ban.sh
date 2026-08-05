#!/usr/bin/env bash
# tests/unit/launcher-fail2ban.sh
#
# Covers the day-2 "Manage fail2ban" menu (Banned IPs + Whitelist + Jail stats &
# history). The launcher is sourced (BASH_SOURCE guard skips main()), which also
# applies its own `set -uo pipefail`, so these run under the same nounset regime as
# production. `docker` is stubbed as a bash function that echoes canned
# `fail2ban-client` output; `ui_choose` is stubbed to drive picks (a disk-backed
# queue feeds multi-pick sequences, since each $() subshell loses in-memory state).
# The Whitelist tests seed a temp jail file (the only config-mutating area) and
# exercise the four write-safety rules plus the add/remove/dedup/blank-cancel paths.
#
# Run directly: ./tests/unit/launcher-fail2ban.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-fail2ban"
scenario_begin "$CURRENT_SCENARIO"

# Canned `docker` stub: two jails (jellyfin, npm); 203.0.113.5 is banned in BOTH
# (drives the hub one-row-per-IP collapse + the distinct-count aggregates),
# 198.51.100.9 in jellyfin only. No backticks in the tree-prefix (double-quoted
# printf would run them); the parsers key off the "<label>:" text, not the glyphs.
read -r -d '' DOCKER_STUB <<'STUB' || true
docker() {
  case "$*" in
    "info"*) return 0 ;;
    "ps "*)  printf "fail2ban\n" ;;
    "exec fail2ban fail2ban-client status")
        printf "Status\n|- Jail list:\tjellyfin, npm\n" ;;
    "exec fail2ban fail2ban-client status jellyfin")
        printf "Status for jellyfin\n|- Currently banned:\t2\n|- Total banned:\t5\n|- Banned IP list:\t203.0.113.5 198.51.100.9\n" ;;
    "exec fail2ban fail2ban-client status npm")
        printf "Status for npm\n|- Currently banned:\t1\n|- Total banned:\t3\n|- Banned IP list:\t203.0.113.5\n" ;;
    *) return 0 ;;
  esac
}
STUB
export DOCKER_STUB

# --- 1a. launcher_menu_post renders the "Manage fail2ban" item ----------------------
render_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  _warn_gpu_runtime_fallback(){ :; }
  storage_is_nas(){ return 1; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  launcher_menu_post >/dev/null 2>&1
  cat "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$render_out" "Manage fail2ban" "launcher_menu_post: Manage fail2ban item shown"

# --- 1b. selecting it dispatches to submenu_fail2ban ------------------------
route_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  _warn_gpu_runtime_fallback(){ :; }
  storage_is_nas(){ return 1; }
  ui_choose(){ echo "Manage fail2ban (banned IPs, whitelist, stats)"; }
  submenu_fail2ban(){ echo DISPATCH_F2B; exit 0; }
  launcher_menu_post 2>&1
' 2>&1)
assert_contains "$route_out" "DISPATCH_F2B" "launcher_menu_post: Manage fail2ban routes to submenu_fail2ban"

# --- 2. docker-down entry guard --------------------------------------------
down_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  _docker_reachable(){ return 1; }
  ui_log(){ shift; echo "$*"; }
  launcher_pause_for_menu(){ :; }
  submenu_fail2ban
' 2>&1)
assert_contains "$down_out" "Docker isn't reachable" "submenu_fail2ban: docker-down guard message"

# --- 3. LAN-only (fail2ban not running) entry guard ------------------------
lan_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  _docker_reachable(){ return 0; }
  _health_f2b_running(){ return 1; }
  ui_log(){ shift; echo "$*"; }
  launcher_pause_for_menu(){ :; }
  submenu_fail2ban
' 2>&1)
assert_contains "$lan_out" "LAN-only installs" "submenu_fail2ban: LAN-only guard message"

# --- 4. guards pass -> the three new top-level labels render ----------------
labels_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  _docker_reachable(){ return 0; }
  _health_f2b_running(){ return 0; }
  clear(){ :; }
  docker(){ return 1; }              # banner stats degrade to none/? - labels still render
  ui_box(){ :; }; ui_kv(){ :; }
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  submenu_fail2ban >/dev/null 2>&1
  cat "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$labels_out" "Banned IPs" "submenu_fail2ban: Banned IPs label shown"
assert_contains "$labels_out" "Whitelist (always-allow IPs)" "submenu_fail2ban: Whitelist label shown"
assert_contains "$labels_out" "Jail stats & history" "submenu_fail2ban: Jail stats & history label shown"

# --- 5. _f2b_banned_pairs emits one <jail>\t<ip> per banned IP -------------
pairs_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  _f2b_banned_pairs
' 2>&1)
piped=$(tr "\t" "|" <<<"$pairs_out")
assert_contains "$piped" "jellyfin|203.0.113.5" "_f2b_banned_pairs: jellyfin/203.0.113.5 pair"
assert_contains "$piped" "jellyfin|198.51.100.9" "_f2b_banned_pairs: jellyfin/198.51.100.9 pair"
assert_contains "$piped" "npm|203.0.113.5" "_f2b_banned_pairs: npm/203.0.113.5 pair"

empty_pairs=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\t\n" ;; *) return 0 ;; esac; }
  _f2b_banned_pairs
' 2>&1)
assert_eq "" "$empty_pairs" "_f2b_banned_pairs: no lines when no jails/bans"

# --- 6. main-screen banner: live stats (distinct count + per-jail tally, custom
# whitelist count). Stub ui_box/ui_kv so the composed kv strings surface as text. -
BANROOT=$(mktemp -d)
mkdir -p "$BANROOT/config/fail2ban/jail.d"
printf '%s\n' "[DEFAULT]" "ignoreip = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 203.0.113.7" "" "[jellyfin]" "enabled = true" >"$BANROOT/config/fail2ban/jail.d/mediastack.conf"
banner_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" BANROOT="$BANROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  SCRIPT_DIR="$BANROOT"
  _docker_reachable(){ return 0; }
  _health_f2b_running(){ return 0; }
  clear(){ :; }
  ui_box(){ shift; printf "%s\n" "$@"; }
  ui_kv(){ printf "%s=%s" "$1" "$2"; }
  ui_choose(){ echo "Back"; }
  submenu_fail2ban
' 2>&1)
assert_contains "$banner_out" "Banned now=2 IPs  (jellyfin 2, npm 1)" "submenu_fail2ban banner: distinct count + per-jail tally"
assert_contains "$banner_out" "Whitelist=4 defaults + 1 custom" "submenu_fail2ban banner: user-added whitelist count"
rm -rf "$BANROOT"

# --- 6b. banner "none" when no jail holds a ban -----------------------------
none_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in
    "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\tjellyfin, npm\n" ;;
    "exec fail2ban fail2ban-client status "*) printf "Status\n|- Currently banned:\t0\n|- Total banned:\t0\n|- Banned IP list:\t\n" ;;
    *) return 0 ;; esac; }
  _docker_reachable(){ return 0; }
  _health_f2b_running(){ return 0; }
  clear(){ :; }
  ui_box(){ shift; printf "%s\n" "$@"; }
  ui_kv(){ printf "%s=%s" "$1" "$2"; }
  ui_choose(){ echo "Back"; }
  submenu_fail2ban
' 2>&1)
assert_contains "$none_out" "Banned now=none" "submenu_fail2ban banner: 'none' when nothing is banned"

# --- 7. f2b_do_unban verdicts (the shared Unban action, unchanged) ----------
unban_ok=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ return 0; }
  ui_log(){ shift; echo "$*"; }
  f2b_do_unban 203.0.113.5
' 2>&1)
assert_contains "$unban_ok" "Unban 203.0.113.5 completed successfully" "f2b_do_unban: rc0 -> completed"

unban_nb=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ echo "203.0.113.5 is not banned"; return 1; }
  ui_log(){ shift; echo "$*"; }
  f2b_do_unban 203.0.113.5
' 2>&1)
assert_contains "$unban_nb" "wasn't banned in any jail" "f2b_do_unban: 'not banned' stderr -> info, not warn"

# Live-verified 1.1.0 shape: unban always exits 0 and prints the cleared-jail
# count; "0" means the IP wasn't banned anywhere (rc/text never signal it).
unban_zero=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ echo "0"; return 0; }
  ui_log(){ shift; echo "$*"; }
  f2b_do_unban 203.0.113.5
' 2>&1)
assert_contains "$unban_zero" "wasn't banned in any jail" "f2b_do_unban: count-0 output -> info, not false success"

unban_count=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ echo "2"; return 0; }
  ui_log(){ shift; echo "$*"; }
  f2b_do_unban 203.0.113.5
' 2>&1)
assert_contains "$unban_count" "Unban 203.0.113.5 completed successfully" "f2b_do_unban: count>0 output -> completed"

# --- 7b. Banned-IPs hub: one row per distinct IP, jails joined; pick routes the
# bare IP to f2b_ip_actions. Disk-backed queue drives the two successive picks
# (each ui_choose runs in its own $() subshell; the file survives, in-memory won't).
ITEMS=$(mktemp)
QUEUE=$(mktemp)
printf '%s\n' "203.0.113.5  (jellyfin, npm)" "Back" >"$QUEUE"
hub_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" ITEMS="$ITEMS" QUEUE="$QUEUE" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }
  launcher_pause_for_menu(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" >> "$ITEMS"; local l; l=$(head -1 "$QUEUE"); sed -i "1d" "$QUEUE"; printf "%s\n" "$l"; }
  f2b_ip_actions(){ echo "IP_ACTIONS:$1"; }
  f2b_banned_menu
' 2>&1)
items=$(cat "$ITEMS")
rm -f "$ITEMS" "$QUEUE"
assert_contains "$items" "203.0.113.5  (jellyfin, npm)" "f2b_banned_menu: 203.0.113.5 collapsed to one row, jails joined"
assert_contains "$items" "198.51.100.9  (jellyfin)" "f2b_banned_menu: single-jail IP shown once"
assert_contains "$hub_out" "IP_ACTIONS:203.0.113.5" "f2b_banned_menu: picking a row routes the bare IP to context actions"

# --- 7c. hub empty state: info message, only Back --------------------------
hubempty_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\t\n" ;; *) return 0 ;; esac; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }
  ui_log(){ echo "$1: ${*:2}"; }
  ui_choose(){ echo "Back"; }
  f2b_banned_menu
' 2>&1)
assert_contains "$hubempty_out" "No IPs are currently banned." "f2b_banned_menu: empty-state message shown"

# --- 7d. hub paging at 15: page 1 (15 rows + Show more), page 2 (remaining +
# Back to first page), then DRIVE "Back to first page" - it must redraw page 1,
# NOT be swallowed by a bare "Back"* glob (which would exit the hub early). Three
# renders total prove the reset was honoured. jellyfin holds 17 IPs (.101-.117),
# which sort lexically in order (equal-length strings). --------------------------
PAGE_IPS=$(for i in $(seq 101 117); do printf '203.0.113.%s ' "$i"; done)
PITEMS=$(mktemp)
PQUEUE=$(mktemp)
printf '%s\n' "Show more (2 remaining)" "Back to first page" "Back" >"$PQUEUE"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" PAGE_IPS="$PAGE_IPS" PITEMS="$PITEMS" PQUEUE="$PQUEUE" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in
    "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\tjellyfin\n" ;;
    "exec fail2ban fail2ban-client status jellyfin") printf "Status\n|- Currently banned:\t17\n|- Total banned:\t17\n|- Banned IP list:\t%s\n" "$PAGE_IPS" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }; launcher_pause_for_menu(){ :; }
  f2b_ip_actions(){ :; }
  ui_choose(){ shift; printf "===CALL===\n" >> "$PITEMS"; printf "%s\n" "$@" >> "$PITEMS"; local l; l=$(head -1 "$PQUEUE"); sed -i "1d" "$PQUEUE"; printf "%s\n" "$l"; }
  f2b_banned_menu
' >/dev/null 2>&1
pitems=$(cat "$PITEMS")
rm -f "$PITEMS" "$PQUEUE"
ncalls=$(grep -c "===CALL===" <<<"$pitems")
first_block=$(awk '/===CALL===/{c++} c==1 && !/===CALL===/{print}' <<<"$pitems")
first_rows=$(grep -c "203.0.113." <<<"$first_block")
assert_eq "15" "$first_rows" "f2b_banned_menu paging: exactly 15 IP rows on the first page"
assert_contains "$first_block" "203.0.113.101  (jellyfin)" "f2b_banned_menu paging: first page starts at .101"
assert_contains "$first_block" "Show more (2 remaining)" "f2b_banned_menu paging: Show more shows the remaining count"
assert_contains "$pitems" "203.0.113.116  (jellyfin)" "f2b_banned_menu paging: page 2 shows .116"
assert_contains "$pitems" "203.0.113.117  (jellyfin)" "f2b_banned_menu paging: page 2 shows .117"
assert_contains "$pitems" "Back to first page" "f2b_banned_menu paging: 'Back to first page' offered on page 2"
assert_eq "3" "$ncalls" "f2b_banned_menu paging: 'Back to first page' redraws page 1 (not swallowed), then Back exits"

# --- 7d2. hub bulk unban: "Unban all (N IPs)" only when >1 IP is banned; the
# confirm gates it (yes -> the all-jails `unban --all` fires + success result;
# no -> nothing runs). With a single IP the item must NOT render - the per-IP
# context actions already cover that case. ------------------------------------
UITEMS=$(mktemp)
UQUEUE=$(mktemp)
UCALLS=$(mktemp)
printf '%s\n' "Unban all (2 IPs)" "Back" >"$UQUEUE"
bulk_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" UITEMS="$UITEMS" UQUEUE="$UQUEUE" UCALLS="$UCALLS" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ echo "$*" >> "$UCALLS"; case "$*" in
    "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\tjellyfin\n" ;;
    "exec fail2ban fail2ban-client status jellyfin") printf "Status\n|- Currently banned:\t2\n|- Total banned:\t2\n|- Banned IP list:\t203.0.113.5 198.51.100.9\n" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }; launcher_pause_for_menu(){ :; }
  ui_confirm(){ echo "CONFIRM:$1"; return 0; }
  _show_action_result(){ shift; echo "RESULT:$*"; }
  ui_choose(){ shift; printf "%s\n" "$@" >> "$UITEMS"; local l; l=$(head -1 "$UQUEUE"); sed -i "1d" "$UQUEUE"; printf "%s\n" "$l"; }
  f2b_banned_menu
' 2>&1)
uitems=$(cat "$UITEMS")
ucalls=$(cat "$UCALLS")
rm -f "$UITEMS" "$UQUEUE" "$UCALLS"
assert_contains "$uitems" "Unban all (2 IPs)" "f2b_banned_menu bulk: 'Unban all (N IPs)' offered with >1 IP"
assert_contains "$bulk_out" "CONFIRM:Unban all 2 IPs" "f2b_banned_menu bulk: confirm names the count"
assert_contains "$ucalls" "exec fail2ban fail2ban-client unban --all" "f2b_banned_menu bulk: confirm-yes fires unban --all"
assert_contains "$bulk_out" "RESULT:Unban all (2 IPs)" "f2b_banned_menu bulk: success routes to the action result"

# Confirm-no: no unban call, explicit cancel message.
UQUEUE=$(mktemp)
UCALLS=$(mktemp)
printf '%s\n' "Unban all (2 IPs)" "Back" >"$UQUEUE"
bulkno_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" UQUEUE="$UQUEUE" UCALLS="$UCALLS" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ echo "$*" >> "$UCALLS"; case "$*" in
    "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\tjellyfin\n" ;;
    "exec fail2ban fail2ban-client status jellyfin") printf "Status\n|- Currently banned:\t2\n|- Total banned:\t2\n|- Banned IP list:\t203.0.113.5 198.51.100.9\n" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }; launcher_pause_for_menu(){ :; }
  ui_confirm(){ return 1; }
  ui_choose(){ shift; local l; l=$(head -1 "$UQUEUE"); sed -i "1d" "$UQUEUE"; printf "%s\n" "$l"; }
  f2b_banned_menu
' 2>&1)
ucalls=$(cat "$UCALLS")
rm -f "$UQUEUE" "$UCALLS"
assert_contains "$bulkno_out" "Cancelled - nothing changed." "f2b_banned_menu bulk: confirm-no cancels"
assert_eq "0" "$(grep -c 'unban --all' <<<"$ucalls")" "f2b_banned_menu bulk: confirm-no fires nothing"

# Single IP: the bulk item must not render.
UITEMS=$(mktemp)
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" UITEMS="$UITEMS" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in
    "exec fail2ban fail2ban-client status") printf "Status\n|- Jail list:\tjellyfin\n" ;;
    "exec fail2ban fail2ban-client status jellyfin") printf "Status\n|- Currently banned:\t1\n|- Total banned:\t1\n|- Banned IP list:\t203.0.113.5\n" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }; launcher_pause_for_menu(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" >> "$UITEMS"; echo "Back"; }
  f2b_banned_menu
' >/dev/null 2>&1
uitems=$(cat "$UITEMS")
rm -f "$UITEMS"
assert_eq "0" "$(grep -c 'Unban all' <<<"$uitems")" "f2b_banned_menu bulk: item hidden with a single banned IP"

# --- 7e. context actions route DISTINCTLY - a naive \"Unban\"* glob would send
# both labels to plain f2b_do_unban and drop the whitelist step. -----------------
ctx_unban=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ shift; printf "%s\n" "$@"; }
  ui_kv(){ printf "%s=%s" "$1" "$2"; }
  ui_confirm(){ echo "SECOND_CONFIRM"; return 0; }
  f2b_do_unban(){ echo "DO_UNBAN:$1"; }
  f2b_whitelist_apply(){ echo "WL_APPLY:$1:$2:$3"; }
  ui_choose(){ echo "Unban (restores all access)"; }
  f2b_ip_actions 203.0.113.5
' 2>&1)
assert_contains "$ctx_unban" "IP=203.0.113.5" "f2b_ip_actions: IP kv shown"
assert_contains "$ctx_unban" "Banned by=jellyfin, npm" "f2b_ip_actions: Banned by joins the jail list"
assert_contains "$ctx_unban" "DO_UNBAN:203.0.113.5" "f2b_ip_actions: plain Unban routes the bare IP to f2b_do_unban"
if grep -q "WL_APPLY" <<<"$ctx_unban"; then
    fail "f2b_ip_actions: plain Unban does NOT whitelist" "$ctx_unban"
else
    pass "f2b_ip_actions: plain Unban does NOT whitelist"
fi

ctx_wl=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  SCRIPT_DIR="/opt/ms"
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ :; }; ui_kv(){ :; }
  ui_confirm(){ echo "SECOND_CONFIRM"; return 0; }
  f2b_do_unban(){ echo "DO_UNBAN:$1"; }
  f2b_whitelist_apply(){ echo "WL_APPLY:$1:$2:$3"; }
  ui_choose(){ echo "Unban + always allow (won'"'"'t be banned again)"; }
  f2b_ip_actions 203.0.113.5
' 2>&1)
assert_contains "$ctx_wl" "WL_APPLY:add:203.0.113.5:/opt/ms/config/fail2ban/jail.d/mediastack.conf" "f2b_ip_actions: always-allow routes to whitelist_apply add <ip> <jail_file>"
if grep -q "DO_UNBAN" <<<"$ctx_wl"; then
    fail "f2b_ip_actions: always-allow does NOT call plain unban (distinct routing)" "$ctx_wl"
else
    pass "f2b_ip_actions: always-allow does NOT call plain unban (distinct routing)"
fi
if grep -q "SECOND_CONFIRM" <<<"$ctx_wl"; then
    fail "f2b_ip_actions: no second ui_confirm (whitelist_apply owns its own)" "$ctx_wl"
else
    pass "f2b_ip_actions: no second ui_confirm before whitelist_apply"
fi

# --- 7f. jail detail: all four translated kv rows + pickable IPs -> context ---
JDQ=$(mktemp)
printf '%s\n' "203.0.113.5" "Back" >"$JDQ"
jd_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" JDQ="$JDQ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in
    "exec fail2ban fail2ban-client status jellyfin")
      printf "Status for jellyfin\n|- Currently failed:\t1\n|- Total failed:\t34\n|- File list:\t/var/log/jellyfin/log_.log\n|- Currently banned:\t2\n|- Total banned:\t5\n|- Banned IP list:\t203.0.113.5 198.51.100.9\n" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ shift; printf "%s\n" "$@"; }
  ui_kv(){ printf "%s=%s" "$1" "$2"; }
  ui_log(){ echo "$1: ${*:2}"; }
  f2b_ip_actions(){ echo "IP_ACTIONS:$1"; }
  ui_choose(){ shift; local l; l=$(head -1 "$JDQ"); sed -i "1d" "$JDQ"; printf "%s\n" "$l"; }
  f2b_jail_detail jellyfin
' 2>&1)
assert_contains "$jd_out" "Banned now=2" "f2b_jail_detail: Banned now = Currently banned"
assert_contains "$jd_out" "Banned total=5" "f2b_jail_detail: Banned total = Total banned"
assert_contains "$jd_out" "Failed logins=1 recent (34 total)" "f2b_jail_detail: Failed logins composite (Currently/Total failed)"
assert_contains "$jd_out" "Watching=/var/log/jellyfin/log_.log" "f2b_jail_detail: Watching = raw File list (no friendly-name table)"
assert_contains "$jd_out" "IP_ACTIONS:203.0.113.5" "f2b_jail_detail: picking a banned IP routes to context actions"

# --- 7g. jail detail empty state + unreadable-status warn ------------------
jde_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ case "$*" in
    "exec fail2ban fail2ban-client status seerr")
      printf "Status for seerr\n|- Currently failed:\t0\n|- Total failed:\t3\n|- File list:\t/var/log/seerr/*.log\n|- Currently banned:\t0\n|- Total banned:\t1\n|- Banned IP list:\t\n" ;;
    *) return 0 ;; esac; }
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ :; }; ui_kv(){ :; }
  ui_log(){ echo "$1: ${*:2}"; }
  ui_choose(){ echo "Back"; }
  f2b_jail_detail seerr
' 2>&1)
assert_contains "$jde_out" "No IPs banned by this jail right now." "f2b_jail_detail: empty-state message"

jdr_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ return 1; }
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }
  ui_log(){ echo "$1: ${*:2}"; }
  launcher_pause_for_menu(){ :; }
  f2b_jail_detail jellyfin
' 2>&1)
assert_contains "$jdr_out" "Couldn't read status for jellyfin." "f2b_jail_detail: unreadable status warns"

# --- 7h. jail stats & history: banner aggregates + per-jail info + routing ----
stats_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ shift; printf "%s\n" "$@"; }
  ui_kv(){ printf "%s=%s" "$1" "$2"; }
  ui_log(){ echo "$1: ${*:2}"; }
  ui_choose(){ echo "Back"; }
  f2b_stats_menu
' 2>&1)
assert_contains "$stats_out" "Jails=jellyfin, npm" "f2b_stats_menu: jail list comma-joined"
assert_contains "$stats_out" "Banned now=2" "f2b_stats_menu: distinct-IP count (203.0.113.5 counted once across jails)"
assert_contains "$stats_out" "Bans all-time=8" "f2b_stats_menu: sum of per-jail Total banned (5+3)"
assert_contains "$stats_out" "info: jellyfin: 2 banned now (5 total)" "f2b_stats_menu: jellyfin per-jail info line"
assert_contains "$stats_out" "info: npm: 1 banned now (3 total)" "f2b_stats_menu: npm per-jail info line"
if grep -q "^warn:" <<<"$stats_out"; then
    fail "f2b_stats_menu: ban lines use info, not warn" "found a warn line: $stats_out"
else
    pass "f2b_stats_menu: ban lines use info, not warn (a ban is the healthy state)"
fi
assert_contains "$stats_out" "fail2ban protection (regex + jails)" "f2b_stats_menu: points at the Health & security regex probe"

STQ=$(mktemp)
printf '%s\n' "jellyfin" "Back" >"$STQ"
stroute=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" STQ="$STQ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  f2b_jail_detail(){ echo "JAIL_DETAIL:$1"; }
  f2b_show_recent(){ echo "SHOW_RECENT"; }
  ui_choose(){ shift; local l; l=$(head -1 "$STQ"); sed -i "1d" "$STQ"; printf "%s\n" "$l"; }
  f2b_stats_menu
' 2>&1)
rm -f "$STQ"
assert_contains "$stroute" "JAIL_DETAIL:jellyfin" "f2b_stats_menu: picking a jail routes to f2b_jail_detail"

STR=$(mktemp)
printf '%s\n' "Recent ban history" "Back" >"$STR"
strec=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" STR="$STR" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  clear(){ :; }; launcher_pause_for_menu(){ :; }
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  f2b_jail_detail(){ echo "JAIL_DETAIL:$1"; }
  f2b_show_recent(){ echo "SHOW_RECENT"; }
  ui_choose(){ shift; local l; l=$(head -1 "$STR"); sed -i "1d" "$STR"; printf "%s\n" "$l"; }
  f2b_stats_menu
' 2>&1)
rm -f "$STR"
assert_contains "$strec" "SHOW_RECENT" "f2b_stats_menu: 'Recent ban history' routes to f2b_show_recent"

# --- 7i. recent ban history: ONE box drawn on the empty path too (hoisted) ---
rec_empty=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  docker(){ return 0; }            # docker logs -> nothing -> empty path
  clear(){ :; }
  ui_box(){ echo "BOX_DRAWN:$1"; }
  ui_kv(){ :; }
  ui_log(){ echo "$1: ${*:2}"; }
  f2b_show_recent
' 2>&1)
assert_contains "$rec_empty" "BOX_DRAWN:MediaStack - Recent ban history" "f2b_show_recent: box drawn even when no events"
assert_contains "$rec_empty" "No recent ban activity" "f2b_show_recent: empty-state message preserved"

scenario_end "$CURRENT_SCENARIO"
summary
scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/launcher-fail2ban-whitelist.sh
#
# Whitelist, regression, and screen-rhythm coverage for the launcher fail2ban seam.
# This companion exists because extraction changed the source load and the original
# suite exceeded the shell line cap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-fail2ban-whitelist"
scenario_begin "$CURRENT_SCENARIO"

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

# --- 7j. screen rhythm: each sub-view emits exactly ONE box per render (the
# clear -> one ui_box -> content -> ui_choose house rhythm). ui_choose returns Back
# so each loop draws exactly once. ---------------------------------------------
for view in "f2b_banned_menu" "f2b_ip_actions 203.0.113.5" "f2b_stats_menu"; do
    rhythm=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" VIEW="$view" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    eval "$DOCKER_STUB"
    clear(){ :; }; ui_kv(){ :; }; ui_log(){ :; }; launcher_pause_for_menu(){ :; }
    N=0
    ui_box(){ N=$((N+1)); }
    ui_choose(){ echo "Back"; }
    $VIEW
    echo "BOXES:$N"
  ' 2>&1)
    assert_contains "$rhythm" "BOXES:1" "screen rhythm: '$view' renders exactly one box"
done

# --- 7k. gum height clamp: --height = min(item count, max(3, rows-4)) ---------
GA=$(mktemp)
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" GA="$GA" bash -c '
  source "$REPO_ROOT/scripts/lib/ui-render-gum.sh"
  gum(){ printf "%s\n" "$*" >> "$GA"; echo "x"; }
  tput(){ echo 24; }               # rows=24 -> max(3, 20)=20
  big=(); for i in $(seq 1 40); do big+=("item$i"); done
  _render_choose "p" 0 "${big[@]}" >/dev/null
  _render_choose "p" 0 a b c d e   >/dev/null
' 2>&1
ga=$(cat "$GA")
rm -f "$GA"
assert_contains "$ga" "--height=20" "gum clamp: 40-item list clamped to the terminal (rows-4=20)"
assert_contains "$ga" "--height=5" "gum clamp: short 5-item list keeps its item count"

# --- 8. f2b_whitelist_menu: the four defaults render LOCKED (no Remove) ------
# Seed a temp SCRIPT_DIR/config/... jail file (the whitelist read path needs a
# real file). SCRIPT_DIR is overridden after sourcing so the menu reads the seed.
DEFAULT_IGN="ignoreip = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
seed_jail() { printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN" "bantime = 30m" "" "[jellyfin]" "enabled = true" "" "[npm]" "enabled = true" >"$1"; }

WLROOT=$(mktemp -d)
mkdir -p "$WLROOT/config/fail2ban/jail.d"
seed_jail "$WLROOT/config/fail2ban/jail.d/mediastack.conf"
menu8=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" WLROOT="$WLROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  SCRIPT_DIR="$WLROOT"
  clear(){ :; }; ui_box(){ :; }; ui_kv(){ :; }; launcher_pause_for_menu(){ :; }
  ui_log(){ echo "$1: ${*:2}"; }
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  f2b_whitelist_menu
  echo "---OPTS---"; cat "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$menu8" "127.0.0.0/8  (default - locked)" "f2b_whitelist_menu: 127/8 locked"
assert_contains "$menu8" "10.0.0.0/8  (default - locked)" "f2b_whitelist_menu: 10/8 locked"
assert_contains "$menu8" "172.16.0.0/12  (default - locked)" "f2b_whitelist_menu: 172.16/12 locked"
assert_contains "$menu8" "192.168.0.0/16  (default - locked)" "f2b_whitelist_menu: 192.168/16 locked"
opts8=${menu8#*---OPTS---}
if grep -q "Remove" <<<"$opts8"; then
    fail "f2b_whitelist_menu: no Remove offered for locked defaults" "found: $opts8"
else
    pass "f2b_whitelist_menu: no Remove offered for locked defaults"
fi
assert_contains "$opts8" "Add an IP" "f2b_whitelist_menu: Add an IP offered"

# --- 9a. add via banned-IP quick-pick: appended, jails preserved ------------
JAILP=$(mktemp)
seed_jail "$JAILP"
add_qp=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILP="$JAILP" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  ui_choose(){ echo "203.0.113.5"; }
  f2b_whitelist_add "$JAILP"
' 2>&1)
assert_contains "$add_qp" "completed successfully" "f2b_whitelist_add quick-pick: reports success"
assert_contains "$(grep "^ignoreip" "$JAILP")" "$DEFAULT_IGN 203.0.113.5" "f2b_whitelist_add quick-pick: IP appended after defaults"
assert_contains "$(cat "$JAILP")" "[jellyfin]" "f2b_whitelist_add: [jellyfin] jail preserved (whole-file write)"
assert_contains "$(cat "$JAILP")" "[npm]" "f2b_whitelist_add: [npm] jail preserved (whole-file write)"

# --- 9b. manual path, blank Enter -> clean cancel, file untouched -----------
JAILB=$(mktemp)
seed_jail "$JAILB"
before_b=$(cat "$JAILB")
blank_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILB="$JAILB" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  ui_choose(){ echo "Type an IP address"; }
  ui_input(){ echo ""; }
  f2b_whitelist_add "$JAILB"
' 2>&1)
assert_contains "$blank_out" "Cancelled" "f2b_whitelist_add manual blank: clean cancel message"
assert_eq "$before_b" "$(cat "$JAILB")" "f2b_whitelist_add manual blank: file untouched"

# --- 9c. manual path, valid typed IP -> written; invalid -> no write --------
JAILM=$(mktemp)
seed_jail "$JAILM"
man_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILM="$JAILM" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  ui_choose(){ echo "Type an IP address"; }
  ui_input(){ echo "203.0.113.99"; }
  f2b_whitelist_add "$JAILM"
' 2>&1)
assert_contains "$man_out" "completed successfully" "f2b_whitelist_add manual: valid typed IP reports success"
assert_contains "$(grep "^ignoreip" "$JAILM")" "203.0.113.99" "f2b_whitelist_add manual: valid typed IP written"

JAILI=$(mktemp)
seed_jail "$JAILI"
before_i=$(cat "$JAILI")
inv_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILI="$JAILI" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  ui_choose(){ echo "Type an IP address"; }
  ui_input(){ echo "999.1.1.1"; }
  f2b_whitelist_add "$JAILI"
' 2>&1)
assert_contains "$inv_out" "not a valid IP address" "f2b_whitelist_add manual: invalid IP warns"
assert_eq "$before_i" "$(cat "$JAILI")" "f2b_whitelist_add manual: invalid IP rejected, file untouched"

# --- 9d. re-add the same IP -> "already whitelisted", no duplicate token -----
dup_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILP="$JAILP" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  ui_choose(){ echo "203.0.113.5"; }
  f2b_whitelist_add "$JAILP"
' 2>&1)
assert_contains "$dup_out" "already whitelisted" "f2b_whitelist_add: re-add reports already whitelisted"
dup_count=$(grep "^ignoreip" "$JAILP" | grep -o "203.0.113.5" | wc -l | tr -d ' ')
assert_eq "1" "$dup_count" "f2b_whitelist_add: no duplicate token on re-add"

# --- 9e. remove a user-added token -> gone, defaults intact -----------------
rm_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DOCKER_STUB="$DOCKER_STUB" JAILP="$JAILP" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  eval "$DOCKER_STUB"
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  f2b_whitelist_remove 203.0.113.5 "$JAILP"
' 2>&1)
assert_contains "$rm_out" "completed successfully" "f2b_whitelist_remove: reports success"
rm_line=$(grep "^ignoreip" "$JAILP")
if grep -q "203.0.113.5" <<<"$rm_line"; then
    fail "f2b_whitelist_remove: user token removed" "still present: $rm_line"
else
    pass "f2b_whitelist_remove: user token removed"
fi
assert_contains "$rm_line" "$DEFAULT_IGN" "f2b_whitelist_remove: locked defaults intact"

# --- 9f. rule 1: empty read must NOT truncate/write (guard fires) ------------
EMPTYF=$(mktemp)
: >"$EMPTYF"
r1_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" EMPTYF="$EMPTYF" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  docker(){ return 0; }
  sudo(){ return 1; }
  f2b_whitelist_apply add 203.0.113.5 "$EMPTYF"
' 2>&1)
assert_contains "$r1_out" "Couldn't read" "f2b_whitelist_apply rule 1: empty read warns"
assert_eq "0" "$(wc -c <"$EMPTYF" | tr -d ' ')" "f2b_whitelist_apply rule 1: empty file NOT written (still 0 bytes)"

# --- 9g. rule 3: no ignoreip line -> warn, file untouched, no false success --
NOIGN=$(mktemp)
printf '%s\n' "[DEFAULT]" "bantime = 30m" "" "[jellyfin]" "enabled = true" >"$NOIGN"
before_n=$(cat "$NOIGN")
r3_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" NOIGN="$NOIGN" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  docker(){ return 0; }
  f2b_whitelist_apply add 203.0.113.5 "$NOIGN"
' 2>&1)
assert_contains "$r3_out" "No ignoreip line" "f2b_whitelist_apply rule 3: missing-line warns"
assert_eq "$before_n" "$(cat "$NOIGN")" "f2b_whitelist_apply rule 3: file untouched"
if grep -q "completed successfully" <<<"$r3_out"; then
    fail "f2b_whitelist_apply rule 3: no false success" "reported success: $r3_out"
else
    pass "f2b_whitelist_apply rule 3: no false success"
fi

# --- 9h. reload failure -> accurate warn (not false success); file still written
RLF=$(mktemp)
seed_jail "$RLF"
rlf_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" RLF="$RLF" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  docker(){ case "$*" in *reload*) return 1 ;; *) return 0 ;; esac; }
  f2b_whitelist_apply add 203.0.113.7 "$RLF"
' 2>&1)
assert_contains "$rlf_out" "didn't reload" "f2b_whitelist_apply reload-fail: accurate warn"
if grep -q "completed successfully" <<<"$rlf_out"; then
    fail "f2b_whitelist_apply reload-fail: no false success" "reported success: $rlf_out"
else
    pass "f2b_whitelist_apply reload-fail: no false success"
fi
assert_contains "$(grep "^ignoreip" "$RLF")" "203.0.113.7" "f2b_whitelist_apply reload-fail: write still landed"

# --- 9i. unban-on-add fires on ADD but NOT on remove ------------------------
UBLOG=$(mktemp)
UBJAIL=$(mktemp)
printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN 203.0.113.8" "" "[jellyfin]" "enabled = true" >"$UBJAIL"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" UBLOG="$UBLOG" UBJAIL="$UBJAIL" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }
  docker(){ case "$*" in *unban*) echo "$*" >> "$UBLOG" ;; esac; return 0; }
  f2b_whitelist_apply add 203.0.113.9 "$UBJAIL"
' >/dev/null 2>&1
assert_contains "$(cat "$UBLOG")" "unban 203.0.113.9" "f2b_whitelist_apply: add path calls best-effort unban"
: >"$UBLOG"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" UBLOG="$UBLOG" UBJAIL="$UBJAIL" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }
  docker(){ case "$*" in *unban*) echo "$*" >> "$UBLOG" ;; esac; return 0; }
  f2b_whitelist_apply remove 203.0.113.8 "$UBJAIL"
' >/dev/null 2>&1
assert_eq "" "$(cat "$UBLOG")" "f2b_whitelist_apply: remove path does NOT call unban"

# --- 9i2. dedup add path (IP already in the list) STILL fires the best-effort
# unban. f2b_ip_actions' "Unban + always allow" relies on add unbanning; a
# pre-existing whitelist token can still be live-banned (ignoreip is enforced only
# at ban time, or a prior best-effort unban failed), so the short-circuit must not
# drop the unban - and it must not write a duplicate token either. ----------------
DUPLOG=$(mktemp)
DUPJAIL=$(mktemp)
printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN 203.0.113.50" "" "[jellyfin]" "enabled = true" >"$DUPJAIL"
dup_ub=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DUPLOG="$DUPLOG" DUPJAIL="$DUPJAIL" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  docker(){ case "$*" in *unban*) echo "$*" >> "$DUPLOG" ;; esac; return 0; }
  f2b_whitelist_apply add 203.0.113.50 "$DUPJAIL"
' 2>&1)
assert_contains "$(cat "$DUPLOG")" "unban 203.0.113.50" "f2b_whitelist_apply: dedup add path still fires best-effort unban"
assert_contains "$dup_ub" "already whitelisted" "f2b_whitelist_apply: dedup add path reports already whitelisted"
dupn=$(grep "^ignoreip" "$DUPJAIL" | grep -o "203.0.113.50" | wc -l | tr -d ' ')
assert_eq "1" "$dupn" "f2b_whitelist_apply: dedup add path writes no duplicate token"
rm -f "$DUPLOG" "$DUPJAIL"

# --- 9i3. defensive empty-$ip guard: an empty IP must warn, touch nothing, and
# never call unban (grep -Fqw "" would false-match the whole line otherwise). ------
EMPLOG=$(mktemp)
EMPJAIL=$(mktemp)
printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN" "" "[jellyfin]" "enabled = true" >"$EMPJAIL"
emp_before=$(cat "$EMPJAIL")
emp_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" EMPLOG="$EMPLOG" EMPJAIL="$EMPJAIL" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }
  docker(){ case "$*" in *unban*) echo "$*" >> "$EMPLOG" ;; esac; return 0; }
  f2b_whitelist_apply add "" "$EMPJAIL"
' 2>&1)
assert_contains "$emp_out" "No IP given" "f2b_whitelist_apply: empty \$ip warns and stops"
assert_eq "" "$(cat "$EMPLOG")" "f2b_whitelist_apply: empty \$ip never calls unban"
assert_eq "$emp_before" "$(cat "$EMPJAIL")" "f2b_whitelist_apply: empty \$ip leaves the jail file untouched"
rm -f "$EMPLOG" "$EMPJAIL"

# --- 9j. HIGH regression: an inline '# comment' on the ignoreip line must NOT ---
# truncate the file. The old sed used '#' as its delimiter, so a '#' in the data
# emptied the rebuild and truncated mediastack.conf to 1 byte while reporting
# success. The awk/ENVIRON rebuild passes the line verbatim; the inline comment may
# legitimately be dropped, so assert jails intact + new IP present (not comment survival).
HASHJ=$(mktemp)
printf '%s\n' "[DEFAULT]" "ignoreip = 127.0.0.0/8 10.0.0.0/8  # home office" "" "[jellyfin]" "enabled = true" "" "[npm]" "enabled = true" "" "[seerr]" "enabled = true" >"$HASHJ"
hash_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" HASHJ="$HASHJ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply add 8.8.8.8 "$HASHJ"
' 2>&1)
assert_contains "$hash_out" "completed successfully" "regression #-comment: add still reports success"
assert_contains "$(grep "^ignoreip" "$HASHJ")" "8.8.8.8" "regression #-comment: new IP present on ignoreip line"
assert_eq "4" "$(grep -c "^\[" "$HASHJ" | tr -d ' ')" "regression #-comment: all four jail sections survive (no truncation)"

# --- 9k. regression: an existing '&' token is preserved verbatim (sed replacement
# side expanded '&' to the whole match). ------------------------------------------
AMPJ=$(mktemp)
printf '%s\n' "[DEFAULT]" "ignoreip = 127.0.0.0/8 a&b" "" "[jellyfin]" "enabled = true" >"$AMPJ"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" AMPJ="$AMPJ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply add 8.8.8.8 "$AMPJ"
' >/dev/null 2>&1
assert_contains "$(grep "^ignoreip" "$AMPJ")" "a&b 8.8.8.8" "regression &: existing '&' token preserved verbatim after add"

# --- 9l. regression: two ignoreip lines (global + a hand-added per-jail override)
# -> only the FIRST is rewritten; the second is byte-identical (grep -m1 read
# consistency). The old global sed clobbered both. -------------------------------
DUPJ=$(mktemp)
printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN" "" "[jellyfin]" "ignoreip = 5.5.5.5" "enabled = true" >"$DUPJ"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" DUPJ="$DUPJ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply add 8.8.8.8 "$DUPJ"
' >/dev/null 2>&1
assert_contains "$(grep -m1 "^ignoreip" "$DUPJ")" "$DEFAULT_IGN 8.8.8.8" "regression 2x-ignoreip: first line rewritten with new IP"
assert_eq "ignoreip = 5.5.5.5" "$(grep "^ignoreip" "$DUPJ" | sed -n 2p)" "regression 2x-ignoreip: per-jail override line byte-identical"

# --- 9m. regression: a '10.*' glob token survives an unrelated add un-expanded.
# The old `echo $new_list` was unquoted -> pathname expansion turned the token into
# matching CWD filenames. A matching file is created in the run CWD to make it bite.
GLOBDIR=$(mktemp -d)
: >"$GLOBDIR/10.match"
GLOBJ="$GLOBDIR/jail.conf"
printf '%s\n' "[DEFAULT]" "ignoreip = 127.0.0.0/8 10.*" "" "[jellyfin]" "enabled = true" >"$GLOBJ"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" GLOBJ="$GLOBJ" GLOBDIR="$GLOBDIR" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null   # sourcing cds to SCRIPT_DIR; enter the
  cd "$GLOBDIR"                                # decoy dir AFTER so the glob can bite
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply add 8.8.8.8 "$GLOBJ"
' >/dev/null 2>&1
glob_line=$(grep "^ignoreip" "$GLOBJ")
assert_contains "$glob_line" "10.* 8.8.8.8" "regression glob: '10.*' token survives verbatim after add"
if grep -q "10.match" <<<"$glob_line"; then
    fail "regression glob: token not expanded to filenames" "expanded: $glob_line"
else
    pass "regression glob: token not expanded to filenames"
fi
rm -rf "$GLOBDIR"

# --- 9m2. regression: a '10.*' glob token survives an unrelated REMOVE un-expanded.
# The remove path split `$new_list` with an unquoted `printf '%s\n' $new_list` BEFORE
# the collapse, so pathname expansion turned the token into matching CWD filenames
# while removing a different token. A matching file in the run CWD makes it bite. ----
GLOBDIR2=$(mktemp -d)
: >"$GLOBDIR2/10.match"
GLOBJ2="$GLOBDIR2/jail.conf"
printf '%s\n' "[DEFAULT]" "ignoreip = 127.0.0.0/8 10.* 203.0.113.5" "" "[jellyfin]" "enabled = true" >"$GLOBJ2"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" GLOBJ2="$GLOBJ2" GLOBDIR2="$GLOBDIR2" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null   # sourcing cds to SCRIPT_DIR; enter the
  cd "$GLOBDIR2"                               # decoy dir AFTER so the glob can bite
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply remove 203.0.113.5 "$GLOBJ2"
' >/dev/null 2>&1
glob_line2=$(grep "^ignoreip" "$GLOBJ2")
assert_contains "$glob_line2" "10.*" "regression glob-remove: '10.*' token survives verbatim after remove"
if grep -q "203.0.113.5" <<<"$glob_line2"; then
    fail "regression glob-remove: target token removed" "still present: $glob_line2"
else
    pass "regression glob-remove: target token removed"
fi
if grep -q "10.match" <<<"$glob_line2"; then
    fail "regression glob-remove: token not expanded to filenames" "expanded: $glob_line2"
else
    pass "regression glob-remove: token not expanded to filenames"
fi
rm -rf "$GLOBDIR2"

# --- 9n. regression: a successful REMOVE returns rc 0 (the old success branch ended
# on `[[ $op == add ]] && ...`, falsey on remove, so the function rc lied). --------
REMJ=$(mktemp)
printf '%s\n' "[DEFAULT]" "$DEFAULT_IGN 203.0.113.5" "" "[jellyfin]" "enabled = true" >"$REMJ"
MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" REMJ="$REMJ" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ :; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  f2b_whitelist_apply remove 203.0.113.5 "$REMJ"
' >/dev/null 2>&1
assert_eq "0" "$?" "regression remove-rc: successful remove returns rc 0"

# --- 9o. rule 4: a rebuild that comes out empty must NOT write (guard fires). The
# awk rebuild can't emit empty, so drive the invariant directly: stub awk to emit
# nothing, then assert the guard warns and leaves the file byte-for-byte intact. ---
R4J=$(mktemp)
seed_jail "$R4J"
before_r4=$(cat "$R4J")
r4_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" R4J="$R4J" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box(){ :; }; ui_kv(){ :; }; ui_log(){ echo "$1: ${*:2}"; }
  ui_confirm(){ return 0; }; docker(){ return 0; }
  awk(){ printf ""; }
  f2b_whitelist_apply add 203.0.113.5 "$R4J"
' 2>&1)
assert_contains "$r4_out" "came out empty" "f2b_whitelist_apply rule 4: empty transform warns"
assert_eq "$before_r4" "$(cat "$R4J")" "f2b_whitelist_apply rule 4: file untouched on empty transform"
if grep -q "completed successfully" <<<"$r4_out"; then
    fail "f2b_whitelist_apply rule 4: no false success" "reported success: $r4_out"
else
    pass "f2b_whitelist_apply rule 4: no false success"
fi

rm -rf "$WLROOT" "$JAILP" "$JAILB" "$JAILM" "$JAILI" "$EMPTYF" "$NOIGN" "$RLF" "$UBLOG" "$UBJAIL" \
    "$HASHJ" "$AMPJ" "$DUPJ" "$REMJ" "$R4J"

scenario_end "$CURRENT_SCENARIO"
summary

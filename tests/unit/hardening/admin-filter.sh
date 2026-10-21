# Owns: admin-port filter behaviour tests (rule source, the single systemd path, fail-closed apply script, legacy migration).
# Sources: tests/unit/hardening.sh setup (sourced from hardening/firewall.sh) and scripts/setup/hardening/admin-filter.sh.
#
# Fake root under a temp dir: `sudo` runs file commands for real there and routes
# systemctl/ufw to recorders. iptables is a stateful fake binary on PATH, so the
# real generated apply script runs end to end against it. One integration case
# runs the same script against the real iptables in a throwaway user+net
# namespace when the host allows it. Removal is covered in uninstall-admin-filter.sh.

# Everything this file overrides is saved here and put back at the end, because
# the hardening suite sources its children into one shell.
AF_SAVED_PATH="$PATH"
AF_SAVED_VARS=$(declare -p MEDIASTACK_UFW_AFTER_INIT MEDIASTACK_STATE_FILE MEDIASTACK_UFW_AFTER_RULES MEDIASTACK_UFW_AFTER6_RULES \
    MEDIASTACK_ADMIN_FILTER_SCRIPT MEDIASTACK_ADMIN_FILTER_UNIT MEDIASTACK_ADMIN_FILTER_DROPIN | sed 's/^declare -- /declare -g /')
AF_SAVED_FUNCS=$(declare -f setup_ufw setup_ufw_ssh_rules _ms_ufw_allow _ufw_defaults)

AF_TMP=$(mktemp -d)
AF_BIN="$AF_TMP/bin"
mkdir -p "$AF_BIN"

# The fake keeps one rules file and one chains file per family. Its restore
# mimics real iptables-restore --noflush: a declared chain is created if absent
# and flushed if present, and an append to a missing chain fails.
cat >"$AF_BIN/fake-ipt" <<'FAKE'
#!/usr/bin/env bash
tool=$(basename "$0")
case "$tool" in iptables | iptables-restore) fam=4 ;; *) fam=6 ;; esac
R="$FAKE_STATE/v$fam.rules" C="$FAKE_STATE/v$fam.chains"
touch "$R" "$C"
echo "$tool $*" >>"$FAKE_STATE/ops.log"
drop() { grep -v "$1" "$2" >"$2.n"; mv "$2.n" "$2"; } # delete matching lines
args=()
for a in "$@"; do [[ "$a" == -w || "$a" == -n ]] || args+=("$a"); done
set -- "${args[@]}"
if [[ "$tool" == *-restore ]]; then
    [[ "${FAKE_FAIL_RESTORE:-0}" == 1 ]] && exit 1
    while read -r line; do
        case "$line" in
            :*)
                chain=${line%% *}
                chain=${chain#:}
                grep -qx "$chain" "$C" || echo "$chain" >>"$C"
                drop "^$chain|" "$R"
                ;;
            "-A "*)
                # shellcheck disable=SC2086
                set -- ${line#-A }
                chain=$1
                shift
                grep -qx "$chain" "$C" || exit 1
                [[ "${FAKE_RESTORE_SKIP_DROP:-0}" == 1 && "$*" == *DROP* ]] && continue
                echo "$chain|$*" >>"$R"
                ;;
        esac
    done
    exit 0
fi
op=$1
shift
case "$op" in
    --version) echo "$tool v1.8.11 ($([[ $fam == 4 ]] && echo "${FAKE_BACKEND_V4:-nf_tables}" || echo "${FAKE_BACKEND_V6:-nf_tables}"))" ;;
    -L) grep -qx "$1" "$C" ;;
    -N)
        grep -qx "$1" "$C" && exit 1
        echo "$1" >>"$C"
        ;;
    -S)
        grep -qx "$1" "$C" || exit 1
        echo "-N $1"
        sed -n "s/^$1|/-A $1 /p" "$R"
        ;;
    -C) grep -qxF "$1|${*:2}" "$R" ;;
    -D)
        line="$1|${*:2}"
        grep -qxF "$line" "$R" || exit 1
        awk -v l="$line" '$0 == l && !d { d = 1; next } { print }' "$R" >"$R.n" && mv "$R.n" "$R"
        ;;
    -I)
        [[ "${FAKE_NOOP_INSERT:-0}" == 1 ]] && exit 0
        chain=$1
        spec="${*:3}"
        awk -v c="$chain" -v n="$chain|$spec" '!d && index($0, c "|") == 1 { print n; d = 1 } { print } END { if (!d) print n }' "$R" >"$R.n" && mv "$R.n" "$R"
        ;;
    -A) echo "$1|${*:2}" >>"$R" ;;
    -F) drop "^$1|" "$R" ;;
    -X) drop "^$1\$" "$C" ;;
esac
FAKE
chmod +x "$AF_BIN/fake-ipt"
for t in iptables ip6tables iptables-restore ip6tables-restore; do ln -sf fake-ipt "$AF_BIN/$t"; done

AF_STATE="$AF_TMP/fake-state"
AF_LEDGER="$AF_TMP/ledger"
export FAKE_STATE="$AF_STATE"
# shellcheck disable=SC2123
PATH="$AF_BIN:$PATH"

# Fake root paths for every file the module writes.
MEDIASTACK_STATE_FILE="$AF_LEDGER"
MEDIASTACK_ADMIN_FILTER_SCRIPT="$AF_TMP/root/usr/local/sbin/mediastack-admin-filter"
MEDIASTACK_ADMIN_FILTER_UNIT="$AF_TMP/root/etc/systemd/system/mediastack-admin-filter.service"
MEDIASTACK_ADMIN_FILTER_DROPIN="$AF_TMP/root/etc/systemd/system/docker.service.d/mediastack-admin-filter.conf"
MEDIASTACK_UFW_AFTER_RULES="$AF_TMP/after.rules"
MEDIASTACK_UFW_AFTER_INIT="$AF_TMP/after.init"
MEDIASTACK_UFW_AFTER6_RULES="$AF_TMP/after6.rules"
MEDIASTACK_IF_INET6="$AF_TMP/if_inet6"
export MEDIASTACK_IF_INET6
: >"$MEDIASTACK_IF_INET6"

_af_ledger_get() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$AF_LEDGER"; }
_ms_state_get() { _af_ledger_get "$1" | grep . || return 1; }
_ms_state_set() {
    grep -v "^$1=" "$AF_LEDGER" >"$AF_LEDGER.n"
    echo "$1=$2" >>"$AF_LEDGER.n"
    mv "$AF_LEDGER.n" "$AF_LEDGER"
}

SYSTEMCTL_LOG="$AF_TMP/systemctl.log"
UFW_LOG="$AF_TMP/ufw.log"
AF_FAIL_RELOAD=0 # 1 = `systemctl daemon-reload` fails
_fake_systemctl() {
    echo "$*" >>"$SYSTEMCTL_LOG"
    [[ "$1" == daemon-reload && "$AF_FAIL_RELOAD" == 1 ]] && return 1
    case "$1" in
        start) touch "$AF_TMP/unit-active" ;;
        disable) rm -f "$AF_TMP/unit-active" ;;
        is-active) [[ -e "$AF_TMP/unit-active" ]] ;;
        is-failed) return 1 ;;
    esac
}
# A real `ufw reload` or `ufw enable` loads the *filter sections of after.rules
# and after6.rules with iptables-restore --noflush; `ufw disable` unloads only
# ufw's own chains. Model exactly that, so any block left in those files acts.
_fake_ufw_load() {
    awk '/^\*filter/ { p = 1 } p { print } /^COMMIT/ { p = 0 }' "$MEDIASTACK_UFW_AFTER_RULES" 2>/dev/null | iptables-restore --noflush || touch "$AF_TMP/ufw-load-failed"
    awk '/^\*filter/ { p = 1 } p { print } /^COMMIT/ { p = 0 }' "$MEDIASTACK_UFW_AFTER6_RULES" 2>/dev/null | ip6tables-restore --noflush || touch "$AF_TMP/ufw-load-failed"
}
_fake_ufw() {
    echo "$*" >>"$UFW_LOG"
    case "$*" in reload | "--force enable" | enable) _fake_ufw_load ;; esac
    return 0
}
systemctl() { :; } # only so `command -v systemctl` succeeds
ufw() { :; }       # likewise for `command -v ufw`
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        systemctl | ufw) "_fake_$1" "${@:2}" ;;
        tee)
            echo "tee ${*:2}" >>"$FAKE_STATE/ops.log"
            command "$@"
            ;;
        *) command "$@" ;;
    esac
}

af_reset() {
    rm -rf "$AF_STATE" "$AF_TMP/root" "$AF_TMP/unit-active" "$AF_TMP/ufw-load-failed" "$SYSTEMCTL_LOG" "$UFW_LOG" "$MEDIASTACK_UFW_AFTER_RULES" "$MEDIASTACK_UFW_AFTER6_RULES"
    mkdir -p "$AF_STATE"
    : >"$AF_LEDGER" && : >"$SYSTEMCTL_LOG" && : >"$UFW_LOG"
    : >"$MEDIASTACK_UFW_AFTER_RULES" && : >"$MEDIASTACK_UFW_AFTER6_RULES"
    unset FAKE_FAIL_RESTORE FAKE_RESTORE_SKIP_DROP FAKE_NOOP_INSERT FAKE_BACKEND_V4 FAKE_BACKEND_V6
    unset ADMIN_PORT_FILTER UFW_ENABLED HARDENING_ENABLED
}
# Docker's own state: DOCKER-USER ends in RETURN and FORWARD jumps to it.
af_docker_up() {
    local ipt
    for ipt in iptables ip6tables; do
        "$ipt" -N DOCKER-USER
        "$ipt" -A DOCKER-USER -j RETURN
    done
    iptables -A FORWARD -j DOCKER-USER
}
af_jumps() { "$1" -S DOCKER-USER | grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT$'; }
af_run() { # $1 mode -> AF_OUT, AF_RC
    AF_OUT=$(sh "$MEDIASTACK_ADMIN_FILTER_SCRIPT" "$1" 2>&1)
    AF_RC=$?
}
af_write_script() {
    mkdir -p "$(dirname "$MEDIASTACK_ADMIN_FILTER_SCRIPT")"
    _admin_filter_script >"$MEDIASTACK_ADMIN_FILTER_SCRIPT"
}

# ===========================================================================
# One source of truth: the unit script carries the rules, both families
# ===========================================================================

# Given the generated apply script
# When its rules are read
# Then both families carry their private scopes, the Tailscale ranges and the same DROP groups
af_reset
af_write_script
v4_rules=$(_admin_filter_payload v4)
v6_rules=$(_admin_filter_payload v6)
script_text=$(cat "$MEDIASTACK_ADMIN_FILTER_SCRIPT")
assert_contains "$script_text" "-A MEDIASTACK-DOCKER-RESTRICT -s 100.64.0.0/10 -j RETURN" "admin filter rules: script RETURNs Tailscale CGNAT"
assert_contains "$script_text" "-A MEDIASTACK-DOCKER-RESTRICT -s fd7a:115c:a1e0::/48 -j RETURN" "admin filter rules: script RETURNs the Tailscale ULA prefix"
for scope in ::1/128 fc00::/7 fe80::/10; do
    assert_contains "$v6_rules" "-A MEDIASTACK-DOCKER-RESTRICT -s $scope -j RETURN" "admin filter rules: v6 RETURNs $scope"
done
assert_contains "$v4_rules" "-p tcp -m multiport --dports 8989,7878,9117,8080,5055,9000,81,51821 -j DROP" "admin filter rules: first TCP admin-port group is DROPped"
assert_contains "$v4_rules" "-p tcp -m multiport --dports 8000,8090,3001,45876,8191,6767,8096,3000 -j DROP" "admin filter rules: second TCP admin-port group is DROPped"
assert_contains "$v4_rules" "-p udp -m multiport --dports 7359 -j DROP" "admin filter rules: Jellyfin discovery (UDP) is DROPped"
assert_eq "$(grep -- '-j DROP' <<<"$v4_rules")" "$(grep -- '-j DROP' <<<"$v6_rules")" "admin filter rules: v4 and v6 DROP the same ports"
while IFS= read -r drop; do
    assert_contains "$script_text" "$drop" "admin filter rules: the unit script DROPs what the payload DROPs"
done < <(grep -- '-j DROP' <<<"$v4_rules")

# ===========================================================================
# Orchestration: one install path, UFW on or off
# ===========================================================================

setup_ufw() { echo setup_ufw >>"$AF_CALLS"; }
AF_CALLS="$AF_TMP/calls"

# Given ADMIN_PORT_FILTER is unset, with UFW on and with UFW off
# When hardening runs
# Then the unit, the drop-in and the script are written and ledgered, the chain is live, and neither after file is written
for ufw_on in true false; do
    af_reset
    af_docker_up
    : >"$AF_CALLS"
    UFW_ENABLED=$ufw_on HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
    assert_eq "0" "$?" "admin filter UFW=$ufw_on: hardening succeeds"
    assert_eq "$ufw_on" "$([[ -s "$AF_CALLS" ]] && echo true || echo false)" "admin filter UFW=$ufw_on: UFW setup runs only when UFW is on"
    dropin=$(cat "$MEDIASTACK_ADMIN_FILTER_DROPIN" 2>/dev/null)
    unit=$(cat "$MEDIASTACK_ADMIN_FILTER_UNIT" 2>/dev/null)
    assert_contains "$dropin" "Requires=mediastack-admin-filter.service" "admin filter UFW=$ufw_on: drop-in Requires= the unit"
    assert_contains "$dropin" "After=mediastack-admin-filter.service" "admin filter UFW=$ufw_on: drop-in orders docker after the unit"
    assert_contains "$dropin" "ExecStartPost=$MEDIASTACK_ADMIN_FILTER_SCRIPT verify" "admin filter UFW=$ufw_on: drop-in re-verifies after Docker starts"
    assert_contains "$unit" "Before=docker.service" "admin filter UFW=$ufw_on: unit runs before docker.service"
    assert_contains "$unit" "ExecStart=$MEDIASTACK_ADMIN_FILTER_SCRIPT apply" "admin filter UFW=$ufw_on: unit applies the rules"
    if [[ ! -s "$MEDIASTACK_ADMIN_FILTER_UNIT" ]] || grep -Eq '^(Condition|Assert)' "$MEDIASTACK_ADMIN_FILTER_UNIT"; then
        fail "admin filter UFW=$ufw_on: unit has no Condition/Assert line that could skip it"
    else
        pass "admin filter UFW=$ufw_on: unit has no Condition/Assert line that could skip it"
    fi
    assert_file_contains "$MEDIASTACK_ADMIN_FILTER_SCRIPT" "MEDIASTACK-ADMIN-FILTER" "admin filter UFW=$ufw_on: apply script written"
    assert_eq "true" "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED)" "admin filter UFW=$ufw_on: ledger records the unit"
    assert_eq "true" "$(_ms_state_get ADMIN_FILTER_DROPIN_DIR_CREATED)" "admin filter UFW=$ufw_on: ledger records that setup made the drop-in directory"
    assert_eq "1" "$(af_jumps iptables)" "admin filter UFW=$ufw_on: the chain is live with one v4 jump"
    assert_eq "1" "$(af_jumps ip6tables)" "admin filter UFW=$ufw_on: the chain is live with one v6 jump"
    assert_eq "" "$(cat "$MEDIASTACK_UFW_AFTER_RULES" "$MEDIASTACK_UFW_AFTER6_RULES")" "admin filter UFW=$ufw_on: nothing is written to after.rules or after6.rules"
    assert_eq "" "$(cat "$UFW_LOG")" "admin filter UFW=$ufw_on: ufw is never reloaded for the filter"
    assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "restart" "admin filter UFW=$ufw_on: setup never restarts the unit (that would restart Docker)"
done

# Given the unit path is installed
# When setup runs again
# Then it skips, rewrites no file, reloads systemd, and the jump is not duplicated
: >"$SYSTEMCTL_LOG"
before=$(sha256sum "$MEDIASTACK_ADMIN_FILTER_UNIT" "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_SCRIPT")
UFW_ENABLED=true setup_admin_filter >/dev/null 2>&1
assert_eq "$before" "$(sha256sum "$MEDIASTACK_ADMIN_FILTER_UNIT" "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_SCRIPT")" "admin filter re-run: files are unchanged"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" "admin filter re-run: systemd is reloaded even though no file changed"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "enable" "admin filter re-run: an installed, active unit is skipped"
assert_eq "1" "$(af_jumps iptables)" "admin filter re-run: still exactly one jump"

# Given the first install failed at daemon-reload, so the files are on disk but systemd has not loaded them
# When setup runs again with the files unchanged
# Then it reloads before it reports the filter active, and never restarts the unit
af_reset
af_docker_up
AF_FAIL_RELOAD=1
setup_admin_filter >/dev/null 2>&1
assert_eq "1" "$?" "admin filter reload failure: the install fails"
AF_FAIL_RELOAD=0
: >"$SYSTEMCTL_LOG"
setup_admin_filter >/dev/null 2>&1
assert_eq "0" "$?" "admin filter reload retry: the re-run succeeds"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" "admin filter reload retry: the re-run reloads systemd"
assert_eq "yes" "$([[ -e "$AF_TMP/unit-active" ]] && echo yes || echo no)" "admin filter reload retry: the unit is started once the reload worked"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "restart" "admin filter reload retry: the unit is never restarted"

# Given the reload keeps failing on a re-run with unchanged files
# When setup runs again
# Then it fails and does not report the filter active
AF_FAIL_RELOAD=1
setup_admin_filter >/dev/null 2>&1
assert_eq "1" "$?" "admin filter reload failure on re-run: setup fails instead of skipping as installed"
AF_FAIL_RELOAD=0

# The repair of a flushed chain on the already-installed path shares this fake host.
source "$HARDENING_TEST_DIR/hardening/admin-filter-repair.sh"

# Given ADMIN_PORT_FILTER=false, with UFW on and off
# When hardening runs
# Then nothing is installed
for ufw_on in true false; do
    af_reset
    UFW_ENABLED=$ufw_on HARDENING_ENABLED=false ADMIN_PORT_FILTER=false setup_hardening >/dev/null 2>&1
    for f in UNIT DROPIN SCRIPT; do
        assert_file_absent "$(eval echo "\$MEDIASTACK_ADMIN_FILTER_$f")" "admin filter opt-out UFW=$ufw_on: no $f written"
    done
    assert_eq "" "$(cat "$MEDIASTACK_UFW_AFTER_RULES" "$MEDIASTACK_UFW_AFTER6_RULES")" "admin filter opt-out UFW=$ufw_on: after files untouched"
done

# ===========================================================================
# Migration: a host that still holds the chain in after.rules and after6.rules
# ===========================================================================

# What earlier versions appended: a blank line, then the marker-delimited block.
af_legacy_block() { # $1 = v4|v6
    printf '\n# MEDIASTACK-DOCKER-RULES - restrict Docker management ports to LAN\n*filter\n'
    [[ "$1" == v6 ]] && printf ':DOCKER-USER - [0:0]\n'
    printf ':MEDIASTACK-DOCKER-RESTRICT - [0:0]\n\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -s 10.0.0.0/8 -j RETURN\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 81,51821 -j DROP\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -j RETURN\n\nCOMMIT\n# END MEDIASTACK-DOCKER-RULES\n'
}
af_user_head() { printf '*filter\n:ufw-user-input - [0:0]\n-A ufw-user-input -p tcp --dport 22 -j ACCEPT\nCOMMIT\n'; }
af_user_tail() { printf '# user tail\n*nat\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n'; }
# Both files hold the user's text around one legacy block; $AF_TMP/user.rules is what they must become.
af_legacy_hosts() {
    af_reset
    af_docker_up
    {
        af_user_head
        af_legacy_block v4
        af_user_tail
    } >"$MEDIASTACK_UFW_AFTER_RULES"
    {
        af_user_head
        af_legacy_block v6
        af_user_tail
    } >"$MEDIASTACK_UFW_AFTER6_RULES"
    {
        af_user_head
        af_user_tail
    } >"$AF_TMP/user.rules"
    cp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/legacy-v4.rules"
    cp "$MEDIASTACK_UFW_AFTER6_RULES" "$AF_TMP/legacy-v6.rules"
}

# Given legacy blocks in both files, with the user's own text on both sides
# When hardening re-runs with UFW on
# Then the unit path is applied before the first write to either file, and afterwards only the blocks are gone
af_legacy_hosts
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
assert_eq "0" "$?" "admin filter migration: hardening succeeds"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/user.rules" 2>&1)" "admin filter migration: after.rules is the user's text, byte for byte"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER6_RULES" "$AF_TMP/user.rules" 2>&1)" "admin filter migration: after6.rules is the user's text, byte for byte"
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_DROPIN" "Requires=mediastack-admin-filter.service" "admin filter migration: the unit path is installed"
assert_eq "1" "$(af_jumps iptables)" "admin filter migration: one live v4 jump"
assert_eq "1" "$(af_jumps ip6tables)" "admin filter migration: one live v6 jump"
first_apply=$(grep -n '^iptables-restore' "$AF_STATE/ops.log" | head -1 | cut -d: -f1)
first_write=$(grep -n '^tee' "$AF_STATE/ops.log" | head -1 | cut -d: -f1)
if [[ -n "$first_apply" && -n "$first_write" && "$first_apply" -lt "$first_write" ]]; then
    pass "admin filter migration: the chain is applied before any after file is rewritten"
else
    fail "admin filter migration: the chain is applied before any after file is rewritten" "apply at ${first_apply:-none}, first write at ${first_write:-none}"
fi
assert_eq "" "$(cat "$UFW_LOG")" "admin filter migration: ufw is not reloaded"

# Given the same host after migration
# When hardening runs a third time
# Then the files stay as they are
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/user.rules" 2>&1)" "admin filter migration: a further re-run leaves after.rules alone"

# Given legacy blocks and an install that fails
# When hardening re-runs
# Then both blocks stay byte-identical and hardening returns non-zero
af_legacy_hosts
UFW_ENABLED=true HARDENING_ENABLED=false FAKE_FAIL_RESTORE=1 setup_hardening >/dev/null 2>&1
assert_eq "1" "$?" "admin filter migration: a failed install makes hardening fail"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/legacy-v4.rules" 2>&1)" "admin filter migration: a failed install leaves after.rules untouched"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER6_RULES" "$AF_TMP/legacy-v6.rules" 2>&1)" "admin filter migration: a failed install leaves after6.rules untouched"

# Given legacy blocks and a unit that is already installed and active but whose chain no longer verifies
# When hardening re-runs
# Then the blocks stay: the skip path alone is not proof that the unit path works
af_legacy_hosts
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
cp "$AF_TMP/legacy-v4.rules" "$MEDIASTACK_UFW_AFTER_RULES"
cp "$AF_TMP/legacy-v6.rules" "$MEDIASTACK_UFW_AFTER6_RULES"
UFW_ENABLED=true HARDENING_ENABLED=false FAKE_FAIL_RESTORE=1 setup_hardening >/dev/null 2>&1
assert_eq "1" "$?" "admin filter migration: an installed unit that cannot re-apply makes hardening fail"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/legacy-v4.rules" 2>&1)" "admin filter migration: the block stays when the chain does not verify"

# Given a begin marker with no end marker (not a block MediaStack wrote)
# When hardening re-runs
# Then the file is not touched and hardening returns non-zero
af_legacy_hosts
{
    af_user_head
    af_legacy_block v4 | grep -v '^# END MEDIASTACK-DOCKER-RULES'
    af_user_tail
} >"$MEDIASTACK_UFW_AFTER_RULES"
cp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/unterminated.rules"
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
assert_eq "1" "$?" "admin filter migration: an unterminated block fails hardening"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/unterminated.rules" 2>&1)" "admin filter migration: an unterminated block is never cut"

# Given legacy blocks and ADMIN_PORT_FILTER=false
# When hardening runs
# Then the files are left alone (the opt-out toggle removes them)
af_legacy_hosts
UFW_ENABLED=true HARDENING_ENABLED=false ADMIN_PORT_FILTER=false setup_hardening >/dev/null 2>&1
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/legacy-v4.rules" 2>&1)" "admin filter opt-out: setup does not edit the after files"

# Given a user comment that merely starts with the block marker, around a real legacy block
# When the block is stripped
# Then only the real block goes and every other byte stays
af_reset
note=$'# MEDIASTACK-DOCKER-RULES-NOTE keep me\nuser-rule\n# END MEDIASTACK-DOCKER-RULES\n'
{
    af_user_head
    printf '%s' "$note"
    af_legacy_block v4
    af_user_tail
} >"$MEDIASTACK_UFW_AFTER_RULES"
{
    af_user_head
    printf '%s' "$note"
    af_user_tail
} >"$AF_TMP/note-expected.rules"
_admin_filter_strip_file "$MEDIASTACK_UFW_AFTER_RULES" 2>/dev/null
assert_eq "0" "$?" "strip: a marker-prefixed user comment does not break the strip"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/note-expected.rules" 2>&1)" "strip: a marker-prefixed user comment is kept, the real block is gone"

# Given an after.rules with CRLF line endings that holds a legacy block
# When the block is stripped
# Then the file is untouched and the error names CRLF, not a missing end marker
af_reset
{
    af_user_head
    af_legacy_block v4
} | sed 's/$/\r/' >"$MEDIASTACK_UFW_AFTER_RULES"
cp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/crlf.rules"
out=$(
    log_error() { echo "ERR $*"; }
    _admin_filter_strip_file "$MEDIASTACK_UFW_AFTER_RULES" 2>&1
)
assert_eq "1" "$?" "strip: a CRLF file is refused"
assert_contains "$out" "CRLF" "strip: the refusal names CRLF line endings"
assert_not_contains "$out" "end marker" "strip: the refusal is not the misleading end-marker message"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$AF_TMP/crlf.rules" 2>&1)" "strip: a CRLF file is left untouched"

# ===========================================================================
# Regression: ufw reload / enable / disable never disturb the chain (defects 1-3)
# ===========================================================================

# Given Docker is up (its DOCKER-USER ends in RETURN) and hardening ran with UFW on
# When ufw is reloaded, enabled, disabled and reloaded again
# Then the MediaStack jump is still the first rule, there is one of it, and the chain is populated
af_reset
af_docker_up
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
for ufw_cmd in reload "--force enable" disable reload; do
    # shellcheck disable=SC2086
    _fake_ufw $ufw_cmd
done
assert_eq "1" "$(af_jumps iptables)" "ufw sequence: one v4 jump after reload/enable/disable"
assert_eq "1" "$(af_jumps ip6tables)" "ufw sequence: one v6 jump after reload/enable/disable"
assert_eq "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "$(iptables -S DOCKER-USER | sed -n 2p)" "ufw sequence: the v4 jump is still ahead of Docker's RETURN"
assert_eq "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "$(ip6tables -S DOCKER-USER | sed -n 2p)" "ufw sequence: the v6 jump is still ahead of Docker's RETURN"
assert_contains "$(iptables -S MEDIASTACK-DOCKER-RESTRICT)" "-p tcp -m multiport --dports 8989,7878,9117,8080,5055,9000,81,51821 -j DROP" "ufw sequence: the chain still holds its DROP rules"
assert_file_absent "$AF_TMP/ufw-load-failed" "ufw sequence: no ufw load of the after files failed"
af_run verify
assert_eq "0" "$AF_RC" "ufw sequence: the apply script still verifies ($AF_OUT)"

# Given ufw loads after.rules before Docker has created DOCKER-USER (defect 2)
# When hardening runs with UFW on, then ufw reloads
# Then no load fails and the chain exists once Docker's chain does
af_reset
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
_fake_ufw reload
assert_file_absent "$AF_TMP/ufw-load-failed" "ufw before Docker: loading the after files fails nothing"
assert_eq "1" "$(af_jumps iptables)" "ufw before Docker: still one jump"

# The apply script itself, and its run against real iptables.
source "$HARDENING_TEST_DIR/hardening/admin-filter-script.sh"

# Restore the suite-wide stubs for the tests that follow.
unset -f sudo ufw systemctl _fake_systemctl _fake_ufw _af_ledger_get _ufw_defaults
eval "$AF_SAVED_VARS"
eval "$AF_SAVED_FUNCS"
PATH="$AF_SAVED_PATH"
unset MEDIASTACK_IF_INET6 FAKE_STATE
_ms_state_set() { :; }
_ms_state_get() { echo false; }
rm -rf "$AF_TMP"

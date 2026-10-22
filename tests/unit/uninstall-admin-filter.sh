#!/usr/bin/env bash
# Uninstall and opt-out teardown of the admin-port filter (the systemd unit, the
# docker.service drop-in, the live chain and any legacy after.rules block). Fake root under a temp
# dir; systemctl, ufw and iptables are recorders. The filter's install and
# apply behaviour is covered in tests/unit/hardening/admin-filter.sh.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uninstall-admin-filter"
scenario_begin "$CURRENT_SCENARIO"
source "$REPO_ROOT/setup.sh"
set +e +u
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
MEDIASTACK_STATE_DIR="$TMP_DIR/state"
MEDIASTACK_STATE_FILE="$MEDIASTACK_STATE_DIR/install-state"
MEDIASTACK_UFW_AFTER_RULES="$TMP_DIR/after.rules"
MEDIASTACK_UFW_AFTER6_RULES="$TMP_DIR/after6.rules"
MEDIASTACK_UFW_AFTER_INIT="$TMP_DIR/after.init"
MEDIASTACK_ADMIN_FILTER_SCRIPT="$TMP_DIR/root/mediastack-admin-filter"
MEDIASTACK_ADMIN_FILTER_UNIT="$TMP_DIR/root/mediastack-admin-filter.service"
MEDIASTACK_ADMIN_FILTER_DROPIN="$TMP_DIR/root/docker.service.d/mediastack-admin-filter.conf"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
IPT_LOG="$TMP_DIR/iptables.log"
UFW_LOG="$TMP_DIR/ufw.log"
FAIL_RM=""   # a path whose removal fails
FAIL_IPT_D=0 # 1 = deleting the jump fails
STUCK_JUMP=0 # 1 = -D succeeds but the jump stays (a runaway loop would never end)
SYSTEMD_ACTIVE="$TMP_DIR/unit-active"
FAIL_RELOAD=0 # 1 = `systemctl daemon-reload` fails

# iptables fake with just the state the teardown asks about: is the chain there,
# is the jump there. -D removes the jump, -X removes the chain.
_ipt() {
    local fam="$1"
    shift
    echo "$fam $*" >>"$IPT_LOG"
    case "$1" in
        -C) [[ -e "$TMP_DIR/jump$fam" ]] ;;
        -D)
            ((FAIL_IPT_D == 1)) && return 1
            ((STUCK_JUMP == 1)) || rm -f "$TMP_DIR/jump$fam"
            ;;
        -L) [[ -e "$TMP_DIR/chain$fam" ]] ;;
        -X) rm -f "$TMP_DIR/chain$fam" ;;
        *) return 0 ;;
    esac
}
systemctl() { :; }
sudo() {
    [[ "$1" == "-n" ]] && shift
    case "$1" in
        systemctl)
            shift
            echo "$*" >>"$SYSTEMCTL_LOG"
            [[ "$1" == daemon-reload && "$FAIL_RELOAD" == 1 ]] && return 1
            [[ "$1" == disable ]] && rm -f "$SYSTEMD_ACTIVE"
            return 0
            ;;
        iptables)
            shift
            _ipt 4 "$@"
            ;;
        ip6tables)
            shift
            _ipt 6 "$@"
            ;;
        ufw)
            shift
            echo "$*" >>"$UFW_LOG"
            case "$*" in
                "status verbose") printf '%s\n' 'Status: inactive' ;;
                "status") echo 'Status: inactive' ;;
            esac
            return 0
            ;;
        rm)
            [[ -n "$FAIL_RM" && "$*" == *"$FAIL_RM"* ]] && return 1
            # Host paths outside the fake root are never touched.
            [[ "$*" == *"/etc/profile.d"* ]] && return 0
            command "$@"
            ;;
        test)
            [[ "$*" == *"/etc/systemd/system/mediastack-setup.service"* ]] && return 1
            command "$@"
            ;;
        *) command "$@" ;;
    esac
}

# Teardowns owned by other modules are not under test here.
nvidia_driver_gpu_uninstall() { return 0; }
remove_broken_docker_apt_source() { return 0; }
_uninstall_apt() { return 0; }
_uninstall_sysctl() { return 0; }
_uninstall_samba() { return 0; }
storage_uninstall_watchdog() { return 0; }
f2b_uninstall_reload_watcher() { return 0; }
_uninstall_ufw() { return 0; }

# The unit path as setup leaves it: files from the production generators, a
# live chain and jump in both families, the ledger recording it.
install_fixture() {
    rm -rf "$TMP_DIR/root" "$MEDIASTACK_STATE_DIR" "$TMP_DIR"/jump* "$TMP_DIR"/chain*
    mkdir -p "$TMP_DIR/root/docker.service.d" "$MEDIASTACK_STATE_DIR"
    _admin_filter_script >"$MEDIASTACK_ADMIN_FILTER_SCRIPT"
    _admin_filter_unit >"$MEDIASTACK_ADMIN_FILTER_UNIT"
    _admin_filter_dropin >"$MEDIASTACK_ADMIN_FILTER_DROPIN"
    touch "$TMP_DIR/jump4" "$TMP_DIR/jump6" "$TMP_DIR/chain4" "$TMP_DIR/chain6" "$SYSTEMD_ACTIVE"
    : >"$SYSTEMCTL_LOG" && : >"$IPT_LOG" && : >"$UFW_LOG"
    FAIL_RM="" FAIL_IPT_D=0 STUCK_JUMP=0 FAIL_RELOAD=0
    cat >"$MEDIASTACK_STATE_FILE" <<EOF
STATE_FORMAT=1
UFW_RULES_BEFORE_SHA256=$(printf '' | sha256sum | awk '{print $1}')
UFW_DEFAULT_INCOMING=deny
UFW_DEFAULT_OUTGOING=allow
UFW_DEFAULTS_APPLIED=false
UFW_ENABLED_BY_MEDIASTACK=false
UFW_RULE_COUNT=0
SYSCTL_FILE_CREATED=false
SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false
SAMBA_OWNERSHIP_RECORDED=false
SAMBA_CONFIGURED=false
ADMIN_FILTER_UNIT_INSTALLED=true
ADMIN_FILTER_DROPIN_DIR_CREATED=true
EOF
    chmod 0600 "$MEDIASTACK_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Uninstall removes the unit path through the ledger
# ---------------------------------------------------------------------------

# Given the unit path is installed and the ledger is valid
# When MediaStack's system artefacts are uninstalled
# Then the drop-in, unit, script and chain are gone and the ledger says so
install_fixture
uninstall_system_cleanup
assert_eq "0" "$?" "uninstall: system cleanup succeeds with the unit path installed"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_DROPIN" "uninstall: docker.service drop-in removed"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "uninstall: unit removed"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_SCRIPT" "uninstall: apply script removed"
assert_eq "no" "$([[ -e "$TMP_DIR/jump4" || -e "$TMP_DIR/jump6" ]] && echo yes || echo no)" "uninstall: the jump is gone in both families"
assert_eq "no" "$([[ -e "$TMP_DIR/chain4" || -e "$TMP_DIR/chain6" ]] && echo yes || echo no)" "uninstall: the chain is gone in both families"
assert_eq "false" "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED)" "uninstall: the ledger records the unit gone"
assert_eq "no" "$([[ -d "$TMP_DIR/root/docker.service.d" ]] && echo yes || echo no)" "uninstall: the drop-in directory setup created is removed, so Docker's unit is as before"
# The first reload must come before the unit is disabled: docker.service must
# stop requiring the unit before anything stops it.
reload_at=$(grep -n '^daemon-reload' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
disable_at=$(grep -n '^disable' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
if [[ -n "$reload_at" && -n "$disable_at" && "$reload_at" -lt "$disable_at" ]]; then
    pass "uninstall: systemd reloads without the drop-in before the unit is disabled (Docker keeps running and can start)"
else
    fail "uninstall: systemd reloads without the drop-in before the unit is disabled (Docker keeps running and can start)" "$(cat "$SYSTEMCTL_LOG")"
fi

# Given a ledger whose admin-filter flag is not a boolean
# When the ledger is validated
# Then it is rejected, so cleanup never acts on a corrupt record
install_fixture
sed -i 's/^ADMIN_FILTER_UNIT_INSTALLED=.*/ADMIN_FILTER_UNIT_INSTALLED=maybe/' "$MEDIASTACK_STATE_FILE"
validate_install_state
assert_eq "1" "$?" "ledger: a non-boolean ADMIN_FILTER_UNIT_INSTALLED is rejected"

# ---------------------------------------------------------------------------
# A removal failure is reported, not swallowed
# ---------------------------------------------------------------------------

# Given the unit file cannot be removed
# When MediaStack's system artefacts are uninstalled
# Then the cleanup fails and the ledger keeps the unit as installed for a retry
install_fixture
FAIL_RM="mediastack-admin-filter.service"
uninstall_system_cleanup
assert_eq "1" "$?" "uninstall failure: a unit that cannot be removed fails the cleanup"
assert_eq "true" "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED)" "uninstall failure: the ledger keeps the unit for retry"

# Given systemd cannot reload after the drop-in is removed
# When the opt-out runs, and then runs again once the reload works
# Then the first run neither stops nor disables the unit and fails with the ledger intact,
#   And the second run reloads first, then disables, and clears the ledger
install_fixture
FAIL_RELOAD=1
admin_filter_unit_remove
assert_eq "1" "$?" "reload failure: the removal fails"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "disable" "reload failure: the unit is not disabled while systemd still holds the drop-in"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "stop" "reload failure: the unit is not stopped"
assert_eq "true" "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED)" "reload failure: the ledger keeps the unit for retry"
assert_eq "yes" "$([[ -e "$MEDIASTACK_ADMIN_FILTER_UNIT" ]] && echo yes || echo no)" "reload failure: the unit file stays so the retry has work to do"
FAIL_RELOAD=0
: >"$SYSTEMCTL_LOG"
admin_filter_unit_remove
assert_eq "0" "$?" "reload retry: the second removal succeeds"
assert_eq "daemon-reload" "$(sed -n 1p "$SYSTEMCTL_LOG")" "reload retry: the first call reloads systemd"
assert_contains "$(sed -n 2p "$SYSTEMCTL_LOG")" "disable" "reload retry: the unit is disabled after the reload"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "reload retry: the unit file is removed"
assert_eq "false" "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED)" "reload retry: the ledger records the unit gone"

# Given the live jump cannot be deleted
# When MediaStack's system artefacts are uninstalled
# Then the cleanup fails
install_fixture
FAIL_IPT_D=1
uninstall_system_cleanup
assert_eq "1" "$?" "uninstall failure: a jump that cannot be deleted fails the cleanup"

# Given a jump that stays after every delete
# When the opt-out runs
# Then the teardown fails instead of looping forever
install_fixture
STUCK_JUMP=1
(admin_filter_disable) &
worker=$!
(sleep 15 && kill -9 "$worker" 2>/dev/null) &
watchdog=$!
wait "$worker"
stuck_rc=$?
kill "$watchdog" 2>/dev/null
assert_eq "1" "$stuck_rc" "uninstall failure: a jump that cannot be removed fails the teardown instead of hanging"

# ---------------------------------------------------------------------------
# Only MediaStack's own files are removed
# ---------------------------------------------------------------------------

# Given an administrator replaced the drop-in with their own file
# When MediaStack's system artefacts are uninstalled
# Then that file is left in place and the cleanup still removes the rest
install_fixture
printf '[Service]\nLimitNOFILE=1048576\n' >"$MEDIASTACK_ADMIN_FILTER_DROPIN"
uninstall_system_cleanup
assert_file_contains "$MEDIASTACK_ADMIN_FILTER_DROPIN" "LimitNOFILE=1048576" "uninstall: a drop-in without our marker is not deleted"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "uninstall: the marked unit is still removed"

# Given no ownership ledger
# When the best-effort cleanup runs
# Then the marked files and chain go and no ledger is created
install_fixture
rm -rf "$MEDIASTACK_STATE_DIR"
uninstall_best_effort_cleanup
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_DROPIN" "best-effort uninstall: marked drop-in removed without a ledger"
assert_eq "no" "$([[ -e "$TMP_DIR/chain4" ]] && echo yes || echo no)" "best-effort uninstall: chain removed without a ledger"
assert_eq "no" "$([[ -e "$MEDIASTACK_STATE_FILE" ]] && echo yes || echo no)" "best-effort uninstall: no ledger is created"

# ---------------------------------------------------------------------------
# Legacy after.rules blocks: removed by the opt-out and the uninstall, nothing else
# ---------------------------------------------------------------------------

# What earlier versions appended to after.rules (v4) and after6.rules (v6): a
# blank line, then the marker-delimited block.
legacy_block() { # $1 = v4|v6
    printf '\n# MEDIASTACK-DOCKER-RULES - restrict Docker management ports to LAN\n*filter\n'
    [[ "$1" == v6 ]] && printf ':DOCKER-USER - [0:0]\n'
    printf ':MEDIASTACK-DOCKER-RESTRICT - [0:0]\n\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -s 10.0.0.0/8 -j RETURN\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 81,51821 -j DROP\n'
    printf -- '-A MEDIASTACK-DOCKER-RESTRICT -j RETURN\n\nCOMMIT\n# END MEDIASTACK-DOCKER-RULES\n'
}
# The user's own rules around the block, as ufw ships them (ends in COMMIT).
user_head() { printf '*filter\n:ufw-user-input - [0:0]\n-A ufw-user-input -p tcp --dport 22 -j ACCEPT\nCOMMIT\n'; }
user_tail() { printf '# user tail\n*nat\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n'; }
# Both files carry the user's text before and after one legacy block. With
# "with-unit" the unit path stays installed too.
legacy_fixture() {
    install_fixture
    [[ "${1:-}" == with-unit ]] || rm -rf "$TMP_DIR/root"
    {
        user_head
        legacy_block v4
        user_tail
    } >"$MEDIASTACK_UFW_AFTER_RULES"
    {
        user_head
        legacy_block v6
        user_tail
    } >"$MEDIASTACK_UFW_AFTER6_RULES"
    {
        user_head
        user_tail
    } >"$TMP_DIR/expected.rules"
}

# Given the unit path is live
# When the filter is turned off
# Then everything goes, including the live chain, and the cleanup reports success
install_fixture
admin_filter_disable
assert_eq "0" "$?" "opt-out: removal succeeds"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "opt-out: unit removed"
assert_eq "no" "$([[ -e "$TMP_DIR/chain4" ]] && echo yes || echo no)" "opt-out: chain removed"

# Given legacy blocks in both files with the user's text on both sides, and a live chain
# When the filter is turned off
# Then only the blocks go (the rest is byte-identical), ufw is not reloaded, and the chain is gone
legacy_fixture
admin_filter_disable
assert_eq "0" "$?" "opt-out (legacy blocks): removal succeeds"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/expected.rules" 2>&1)" "opt-out (legacy blocks): after.rules is byte-identical to the user's text"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER6_RULES" "$TMP_DIR/expected.rules" 2>&1)" "opt-out (legacy blocks): after6.rules is byte-identical to the user's text"
assert_eq "" "$(cat "$UFW_LOG")" "opt-out (legacy blocks): ufw is not touched"
assert_eq "no" "$([[ -e "$TMP_DIR/chain4" || -e "$TMP_DIR/jump4" ]] && echo yes || echo no)" "opt-out (legacy blocks): the chain is gone"

# Given a legacy block whose end marker is missing
# When the filter is turned off
# Then the file is left byte-identical and the teardown fails, because stripping to end of file would take the user's rules
legacy_fixture
{
    user_head
    legacy_block v4 | grep -v '^# END MEDIASTACK-DOCKER-RULES'
    user_tail
} >"$MEDIASTACK_UFW_AFTER_RULES"
cp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/unterminated.rules"
admin_filter_disable
assert_eq "1" "$?" "opt-out (unterminated block): the teardown fails"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/unterminated.rules" 2>&1)" "opt-out (unterminated block): the file is left untouched"

# Given a legacy block with the unit path installed and the ledger valid
# When MediaStack's system artefacts are uninstalled
# Then the block goes with the unit and the chain
legacy_fixture with-unit
uninstall_system_cleanup
assert_eq "0" "$?" "uninstall (legacy blocks): system cleanup succeeds"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/expected.rules" 2>&1)" "uninstall (legacy blocks): after.rules is restored byte-for-byte"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER6_RULES" "$TMP_DIR/expected.rules" 2>&1)" "uninstall (legacy blocks): after6.rules is restored byte-for-byte"
assert_file_absent "$MEDIASTACK_ADMIN_FILTER_UNIT" "uninstall (legacy blocks): the unit goes too"

# Given legacy blocks and no ownership ledger
# When the best-effort cleanup runs
# Then the blocks still go, found by their markers
legacy_fixture
rm -rf "$MEDIASTACK_STATE_DIR"
uninstall_best_effort_cleanup
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/expected.rules" 2>&1)" "best-effort uninstall: legacy block removed without a ledger"

# ---------------------------------------------------------------------------
# A leftover UFW after.init dedup block: removed by the uninstall, nothing else
# ---------------------------------------------------------------------------

# The stock Canonical sample, and the block an earlier version injected after its start) line.
init_stock() { printf '%s\n' '#!/bin/sh' 'set -e' 'case "$1" in' 'start)' '    # typically required' '    ;;' '*)' '    echo "not supported"' '    ;;' 'esac'; }
init_block() { printf '%s\n' '# >>> MEDIASTACK-DOCKER-DEDUP' '    iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || break' '# <<< MEDIASTACK-DOCKER-DEDUP'; }
init_injected() { init_stock | sed -e '/^start)$/r '<(init_block); }

# Given the stock after.init with the block injected, and a ledger that records the exec-bit flip
# When MediaStack's system artefacts are uninstalled
# Then the file is the stock sample byte for byte, back at mode 640
install_fixture
init_injected >"$MEDIASTACK_UFW_AFTER_INIT"
chmod 750 "$MEDIASTACK_UFW_AFTER_INIT"
printf '%s\n' UFW_AFTER_INIT_CREATED=false UFW_AFTER_INIT_ACTIVATED=true >>"$MEDIASTACK_STATE_FILE"
uninstall_system_cleanup
assert_eq "0" "$?" "uninstall (after.init block): system cleanup succeeds"
assert_eq "" "$(init_stock | cmp - "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "uninstall (after.init block): the stock sample is restored byte for byte"
assert_eq "640" "$(stat -c %a "$MEDIASTACK_UFW_AFTER_INIT")" "uninstall (after.init block): the mode is restored"

# Given a file the old hook created, and a ledger that says so
# When MediaStack's system artefacts are uninstalled
# Then the file is removed
install_fixture
printf '%s\n' '#!/bin/sh' '# after.init — MediaStack-managed; trims duplicate DOCKER-USER jumps.' 'set -e' 'case "$1" in' 'start)' \
    '# >>> MEDIASTACK-DOCKER-DEDUP — keep exactly one DOCKER-USER→RESTRICT jump' \
    '    while [ "$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- '"'-j MEDIASTACK-DOCKER-RESTRICT'"')" -gt 1 ]; do' \
    '        iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || break' '    done' \
    '# <<< MEDIASTACK-DOCKER-DEDUP' '    ;;' 'esac' >"$MEDIASTACK_UFW_AFTER_INIT"
echo UFW_AFTER_INIT_CREATED=true >>"$MEDIASTACK_STATE_FILE"
uninstall_system_cleanup
assert_file_absent "$MEDIASTACK_UFW_AFTER_INIT" "uninstall (after.init block): a file MediaStack created is removed"

# Given the injected block and no ownership ledger
# When the best-effort cleanup runs
# Then the block still goes, found by its markers
install_fixture
init_injected >"$MEDIASTACK_UFW_AFTER_INIT"
rm -rf "$MEDIASTACK_STATE_DIR"
uninstall_best_effort_cleanup
assert_eq "" "$(init_stock | cmp - "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "best-effort uninstall: the after.init block is removed without a ledger"

# Given the real UFW teardown and a live unit-path chain with a legacy block still in after.rules
# When UFW is turned off
# Then the teardown leaves the chain, the jump and the after.rules text alone
unset -f _uninstall_ufw
source "$REPO_ROOT/scripts/setup/hardening/firewall.sh"
detect_ssh_server_ports() { echo 22; }
legacy_fixture
cp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/legacy-before.rules"
_uninstall_ufw
assert_eq "0" "$?" "UFW off: teardown succeeds"
assert_eq "yes" "$([[ -e "$TMP_DIR/chain4" && -e "$TMP_DIR/jump4" ]] && echo yes || echo no)" "UFW off: the live chain and jump stay"
assert_eq "" "$(cmp "$MEDIASTACK_UFW_AFTER_RULES" "$TMP_DIR/legacy-before.rules" 2>&1)" "UFW off: after.rules is not edited"
assert_not_contains "$(cat "$IPT_LOG")" "-D" "UFW off: no iptables delete is issued"

# Given the real UFW teardown and a leftover after.init dedup block
# When UFW is turned off
# Then the block is gone, because it would delete the unit's jump on the next UFW load
init_injected >"$MEDIASTACK_UFW_AFTER_INIT"
_uninstall_ufw
assert_eq "" "$(init_stock | cmp - "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "UFW off: a leftover after.init dedup block is removed"

scenario_end "$CURRENT_SCENARIO"
summary

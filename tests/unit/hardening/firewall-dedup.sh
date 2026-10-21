# Owns: tests that the retired DOCKER-USER dedup hook (/etc/ufw/after.init) is never installed and is migrated away.
# Sources: tests/unit/hardening.sh setup, scripts/setup/hardening/firewall.sh and admin-filter.sh.

# ===========================================================================
# An earlier version injected a block into /etc/ufw/after.init that ran
# `iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT` while it saw two
# jumps. -D removes the first match: the admin-filter unit's position-1 jump.
# ===========================================================================

DEDUP_TMP=$(mktemp -d)
DEDUP_SAVED_VARS=$(declare -p MEDIASTACK_UFW_AFTER_INIT MEDIASTACK_UFW_AFTER_RULES MEDIASTACK_UFW_AFTER6_RULES)
MEDIASTACK_UFW_AFTER_INIT="$DEDUP_TMP/after.init"
MEDIASTACK_UFW_AFTER_RULES="$DEDUP_TMP/after.rules"
MEDIASTACK_UFW_AFTER6_RULES="$DEDUP_TMP/after6.rules"

# The stock Canonical sample (mode 640, not executable), as the old hook found it.
dedup_stock() {
    cat <<'STOCK'
#!/bin/sh
set -e
case "$1" in
start)
    # typically required
    ;;
stop)
    # typically required
    ;;
*)
    echo "'$1' not supported"
    ;;
esac
STOCK
}
# The block as the old hook wrote it, spelled out here so the fixture does not
# depend on any production generator.
dedup_block() {
    cat <<'DEDUP'
# >>> MEDIASTACK-DOCKER-DEDUP — keep exactly one DOCKER-USER→RESTRICT jump
    while [ "$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT')" -gt 1 ]; do
        iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || break
    done
# <<< MEDIASTACK-DOCKER-DEDUP
DEDUP
}
# The stock sample with the block right after its start) line.
dedup_injected() { dedup_stock | awk '{ print } /^start\)$/ { while ((getline l < "'"$DEDUP_TMP"'/block") > 0) print l }'; }
dedup_block >"$DEDUP_TMP/block"
# The minimal file the old hook wrote when no after.init existed.
dedup_created() {
    printf '%s\n' '#!/bin/sh' '# after.init — MediaStack-managed; trims duplicate DOCKER-USER jumps.' 'set -e' 'case "$1" in' 'start)'
    dedup_block
    printf '%s\n' '    ;;' 'esac'
}

DEDUP_STATE_VALUES=""
_ms_state_get() {
    local pair
    for pair in $DEDUP_STATE_VALUES; do
        [[ "${pair%%=*}" == "$1" ]] && {
            echo "${pair#*=}"
            return 0
        }
    done
    return 1
}
_ms_state_set() { :; }
sudo() { command "$@"; }

# Given UFW is on and the host has no after.init
# When setup_ufw runs
# Then it writes no after.init
rm -f "$MEDIASTACK_UFW_AFTER_INIT"
ufw() { :; }
# File operations act on the fake paths; ufw is a stub and anything else is a no-op.
dedup_sudo() {
    case "${1:-}" in
        ufw) [[ "${2:-}" == status ]] && echo "Status: active" ;;
        test | grep | tee | chmod | cat | awk | sed | rm)
            command "$@"
            return
            ;;
    esac
    return 0
}
sudo() { dedup_sudo "$@"; }
setup_ufw >/dev/null 2>&1
assert_eq "no" "$([[ -e "$MEDIASTACK_UFW_AFTER_INIT" ]] && echo yes || echo no)" "setup_ufw: creates no after.init"

# Given UFW is on and the host has the stock after.init
# When setup_ufw runs
# Then the file is byte-identical and keeps its mode
dedup_stock >"$MEDIASTACK_UFW_AFTER_INIT"
chmod 640 "$MEDIASTACK_UFW_AFTER_INIT"
# File operations act on the fake paths; ufw is a stub and anything else is a no-op.
dedup_sudo() {
    case "${1:-}" in
        ufw) [[ "${2:-}" == status ]] && echo "Status: active" ;;
        test | grep | tee | chmod | cat | awk | sed | rm)
            command "$@"
            return
            ;;
    esac
    return 0
}
sudo() { dedup_sudo "$@"; }
setup_ufw >/dev/null 2>&1
assert_eq "" "$(dedup_stock | cmp - "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "setup_ufw: leaves the stock after.init byte-identical"
assert_eq "640" "$(stat -c %a "$MEDIASTACK_UFW_AFTER_INIT")" "setup_ufw: leaves the after.init mode alone"
unset -f ufw
sudo() { command "$@"; }

# Given an after.init that the old hook created, with the ledger saying so
# When the migration runs
# Then the file is removed
dedup_created >"$MEDIASTACK_UFW_AFTER_INIT"
chmod 750 "$MEDIASTACK_UFW_AFTER_INIT"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=true"
_admin_filter_migrate_legacy
assert_eq "no" "$([[ -e "$MEDIASTACK_UFW_AFTER_INIT" ]] && echo yes || echo no)" "after.init migration: a file MediaStack created is removed"

# Given an after.init that the old hook created, with no ledger entry
# When the migration runs
# Then the file is still removed, found by its header
dedup_created >"$MEDIASTACK_UFW_AFTER_INIT"
DEDUP_STATE_VALUES=""
_admin_filter_migrate_legacy
assert_eq "no" "$([[ -e "$MEDIASTACK_UFW_AFTER_INIT" ]] && echo yes || echo no)" "after.init migration: a created file is removed without a ledger"

# Given the stock sample with the block injected and the exec bit flipped by the old hook
# When the migration runs
# Then the file is byte-identical to the stock sample and back to mode 640
dedup_injected >"$MEDIASTACK_UFW_AFTER_INIT"
chmod 750 "$MEDIASTACK_UFW_AFTER_INIT"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=false UFW_AFTER_INIT_ACTIVATED=true"
_admin_filter_migrate_legacy
assert_eq "" "$(dedup_stock | cmp - "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: the stock sample is restored byte for byte"
assert_eq "640" "$(stat -c %a "$MEDIASTACK_UFW_AFTER_INIT")" "after.init migration: the mode the old hook changed is restored"

# Given the stock sample was already executable when the old hook ran
# When the migration runs
# Then the mode stays executable
dedup_injected >"$MEDIASTACK_UFW_AFTER_INIT"
chmod 750 "$MEDIASTACK_UFW_AFTER_INIT"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=false"
_admin_filter_migrate_legacy
assert_eq "750" "$(stat -c %a "$MEDIASTACK_UFW_AFTER_INIT")" "after.init migration: an admin's executable bit is kept"

# Given a custom after.init without our marker
# When the migration runs
# Then the file is untouched
printf '%s\n' '#!/bin/sh' "# admin's own hook" 'iptables -N MY-CHAIN 2>/dev/null || true' >"$MEDIASTACK_UFW_AFTER_INIT"
cp "$MEDIASTACK_UFW_AFTER_INIT" "$DEDUP_TMP/custom"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=true"
_admin_filter_migrate_legacy
assert_eq "" "$(cmp "$DEDUP_TMP/custom" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: a custom file without our marker is untouched"

# Given a begin marker with no end marker
# When the migration runs
# Then the file is untouched and the migration fails
{
    dedup_stock
    echo '# >>> MEDIASTACK-DOCKER-DEDUP'
    echo 'echo admin text after the marker'
} >"$MEDIASTACK_UFW_AFTER_INIT"
cp "$MEDIASTACK_UFW_AFTER_INIT" "$DEDUP_TMP/unterminated"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=false"
_admin_filter_migrate_legacy 2>/dev/null
assert_eq "1" "$?" "after.init migration: an unterminated block fails the migration"
assert_eq "" "$(cmp "$DEDUP_TMP/unterminated" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: an unterminated block is never cut"

# Given an end marker before an unterminated begin marker
# When the migration runs
# Then the file is untouched and the migration fails, because a range delete would reach end of file
{
    dedup_stock
    echo '# <<< MEDIASTACK-DOCKER-DEDUP'
    echo 'echo admin text'
    echo '# >>> MEDIASTACK-DOCKER-DEDUP'
    echo 'echo more admin text'
} >"$MEDIASTACK_UFW_AFTER_INIT"
cp "$MEDIASTACK_UFW_AFTER_INIT" "$DEDUP_TMP/misordered"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=false"
_admin_filter_migrate_legacy 2>/dev/null
assert_eq "1" "$?" "after.init migration: an end marker before an unterminated begin fails the migration"
assert_eq "" "$(cmp "$DEDUP_TMP/misordered" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: an end marker before an unterminated begin is never cut"

# Given the created-file header with an administrator's own hook added under it, plus the block
# When the migration runs
# Then the file stays, with the block gone and the administrator's hook intact
{
    dedup_created | sed -n 1,5p
    echo '    /usr/local/bin/my-own-hook'
    dedup_block
    printf '%s\n' '    ;;' 'esac'
} >"$MEDIASTACK_UFW_AFTER_INIT"
{
    dedup_created | sed -n 1,5p
    echo '    /usr/local/bin/my-own-hook'
    printf '%s\n' '    ;;' 'esac'
} >"$DEDUP_TMP/own-hook"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=true"
_admin_filter_migrate_legacy
assert_eq "" "$(cmp "$DEDUP_TMP/own-hook" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: a header alone does not get the whole file deleted"

# Given a user line that merely starts with the begin marker, then the real block, in a file with the header
# When the migration runs
# Then the user line stays and only the real block goes
{
    dedup_stock
    echo '# >>> MEDIASTACK-DOCKER-DEDUP-NOTE mine'
    echo 'echo mine'
    dedup_block
} >"$MEDIASTACK_UFW_AFTER_INIT"
{
    dedup_stock
    echo '# >>> MEDIASTACK-DOCKER-DEDUP-NOTE mine'
    echo 'echo mine'
} >"$DEDUP_TMP/note"
DEDUP_STATE_VALUES="UFW_AFTER_INIT_CREATED=false"
_admin_filter_migrate_legacy 2>/dev/null
assert_eq "" "$(cmp "$DEDUP_TMP/note" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: a marker-prefixed user line is not a block"

# Given an after.init with CRLF line endings that holds the block
# When the migration runs
# Then the file is untouched and the error names CRLF
dedup_injected | sed 's/$/\r/' >"$MEDIASTACK_UFW_AFTER_INIT"
cp "$MEDIASTACK_UFW_AFTER_INIT" "$DEDUP_TMP/crlf"
out=$(
    log_error() { echo "ERR $*"; }
    _admin_filter_migrate_legacy 2>&1
)
assert_eq "1" "$?" "after.init migration: a CRLF file fails the migration"
assert_contains "$out" "CRLF" "after.init migration: the refusal names CRLF line endings"
assert_eq "" "$(cmp "$DEDUP_TMP/crlf" "$MEDIASTACK_UFW_AFTER_INIT" 2>&1)" "after.init migration: a CRLF file is left untouched"

# Given ADMIN_PORT_FILTER is unset, empty, or exactly true
# When setup_admin_filter runs
# Then it installs and does not warn
# Given any other value than the exact string false (TRUE, yes, 1, "true ", off)
# When setup_admin_filter runs
# Then it still installs, fails closed, and the warning names the value
af_filter_probe() { # $1 = value; "-" means unset
    (
        setup_admin_filter_unit() { echo INSTALL; }
        _admin_filter_migrate_legacy() { :; }
        log_warn() { echo "WARN $*"; }
        log_skip() { echo "SKIP $*"; }
        if [[ "$1" == "-" ]]; then unset ADMIN_PORT_FILTER; else export ADMIN_PORT_FILTER="$1"; fi
        setup_admin_filter
    )
}
for v in - "" true TRUE yes 1 "true " off "'true'"; do
    out=$(af_filter_probe "$v")
    assert_contains "$out" "INSTALL" "admin filter value [$v]: installs"
    assert_not_contains "$out" "SKIP" "admin filter value [$v]: not treated as an opt-out"
    case "$v" in
        - | "" | true) assert_not_contains "$out" "WARN" "admin filter value [$v]: no warning" ;;
        *) assert_contains "$out" "ADMIN_PORT_FILTER='$v' is not recognised" "admin filter value [$v]: warning names the value" ;;
    esac
done
out=$(af_filter_probe false)
assert_not_contains "$out" "INSTALL" "admin filter value [false]: opts out"
assert_contains "$out" "SKIP" "admin filter value [false]: opt-out is logged"

unset -f sudo dedup_sudo dedup_stock dedup_block dedup_injected dedup_created
_ms_state_set() { :; }
_ms_state_get() { echo false; }
eval "$DEDUP_SAVED_VARS"
rm -rf "$DEDUP_TMP"
unset DEDUP_TMP DEDUP_SAVED_VARS DEDUP_STATE_VALUES

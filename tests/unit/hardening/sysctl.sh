# Owns: kernel sysctl hardening behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/sysctl.sh.
#
# A fake `sysctl` models the kernel in a directory of files: `-p FILE` applies
# one file, `--system` applies every file in the fake sysctl.d (as the real tool
# does), `-w` sets one key. Nothing here touches the host's sysctl, /etc or sudo.

SYSCTL_TMPDIR=$(mktemp -d)
SYSCTL_FAKE_BIN="$SYSCTL_TMPDIR/bin"
SYSCTL_KERNEL="$SYSCTL_TMPDIR/kernel"
SYSCTL_D="$SYSCTL_TMPDIR/sysctl.d"
SYSCTL_LOG="$SYSCTL_TMPDIR/messages"
mkdir -p "$SYSCTL_FAKE_BIN" "$SYSCTL_KERNEL" "$SYSCTL_D"

cat >"$SYSCTL_FAKE_BIN/sysctl" <<'FAKE'
#!/usr/bin/env bash
# FAKE_KERNEL, FAKE_SYSCTL_D: state; FAKE_SYSCTL_IGNORE: a key that never takes
# effect; FAKE_SYSCTL_P_SETS: "key=value" that every -p also (wrongly) sets;
# FAKE_SYSCTL_APPLY_LOG: file to record each -p invocation.
apply_file() {
    local key value
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ "$key" == "${FAKE_SYSCTL_IGNORE:-}" ]] && continue
        printf '%s\n' "$value" >"$FAKE_KERNEL/$key"
    done <"$1"
}
case "$1" in
    -n) cat "$FAKE_KERNEL/$2" 2>/dev/null || exit 1 ;;
    -w) printf '%s\n' "${2#*=}" >"$FAKE_KERNEL/${2%%=*}" ;;
    -p)
        [[ -z "${FAKE_SYSCTL_APPLY_LOG:-}" ]] || printf '%s\n' "$2" >>"$FAKE_SYSCTL_APPLY_LOG"
        apply_file "$2"
        if [[ -n "${FAKE_SYSCTL_P_SETS:-}" ]]; then
            printf '%s\n' "${FAKE_SYSCTL_P_SETS#*=}" >"$FAKE_KERNEL/${FAKE_SYSCTL_P_SETS%%=*}"
        fi
        ;;
    --system) for f in "$FAKE_SYSCTL_D"/*.conf; do apply_file "$f"; done ;;
    *) exit 2 ;;
esac
FAKE
printf '#!/bin/sh\nexit 0\n' >"$SYSCTL_FAKE_BIN/docker"
chmod +x "$SYSCTL_FAKE_BIN/sysctl" "$SYSCTL_FAKE_BIN/docker"

# Fresh GCE-like host: Docker enabled forwarding at runtime, while another
# sysctl.d file (read by --system) still says forwarding is off.
_sysctl_test_reset() {
    rm -rf "${SYSCTL_KERNEL:?}"/* "${SYSCTL_D:?}"/* "$SYSCTL_LOG" "$SYSCTL_TMPDIR/ledger"
    : >"$SYSCTL_LOG"
    local key
    while read -r key _; do
        printf '9\n' >"$SYSCTL_KERNEL/$key"
    done < <(_setup_sysctl_owned_pairs)
    printf '1\n' >"$SYSCTL_KERNEL/net.ipv4.ip_forward"
    printf '1\n' >"$SYSCTL_KERNEL/net.ipv6.conf.all.forwarding"
    printf 'net.ipv4.ip_forward = 0\n' >"$SYSCTL_D/60-gce-network-security.conf"
    export FAKE_SYSCTL_D="$SYSCTL_D" FAKE_KERNEL="$SYSCTL_KERNEL"
    unset FAKE_SYSCTL_IGNORE FAKE_SYSCTL_P_SETS
    MEDIASTACK_SYSCTL_CONF="$SYSCTL_D/90-mediastack-hardening.conf"
    MEDIASTACK_UFW_SYSCTL_CONF="$SYSCTL_TMPDIR/absent-ufw-sysctl.conf"
}
_sysctl_kernel_snapshot() {
    local f
    for f in "$SYSCTL_KERNEL"/*; do printf '%s=%s\n' "${f##*/}" "$(<"$f")"; done
}

_sysctl_saved_path="$PATH"
_sysctl_saved_state_get=$(declare -f _ms_state_get)
_sysctl_saved_state_set=$(declare -f _ms_state_set)
PATH="$SYSCTL_FAKE_BIN:$PATH"
sudo() {
    if [[ "${1:-}" == "tee" ]]; then
        shift
        tee "$@"
    else
        "$@"
    fi
}
log_ok() { printf 'OK %s\n' "$*" >>"$SYSCTL_LOG"; }
log_warn() { printf 'WARN %s\n' "$*" >>"$SYSCTL_LOG"; }
log_error() { printf 'ERROR %s\n' "$*" >>"$SYSCTL_LOG"; }
_ms_state_set() { printf '%s=%s\n' "$1" "$2" >>"$SYSCTL_TMPDIR/ledger"; }
_sysctl_state_set() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    if [[ -f "$SYSCTL_TMPDIR/ledger" ]]; then
        awk -F= -v key="$key" '$1 != key' "$SYSCTL_TMPDIR/ledger" >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$SYSCTL_TMPDIR/ledger"
}
_sysctl_state_get() {
    awk -F= -v key="$1" '$1 == key { print $2; found = 1 } END { exit !found }' "$SYSCTL_TMPDIR/ledger"
}

# Given a host whose other sysctl.d file sets ip_forward=0 over Docker's runtime 1,
# When MediaStack's kernel hardening is applied,
# Then ip_forward keeps its value, and the only keys that change are MediaStack's own.
_sysctl_test_reset
before=$(_sysctl_kernel_snapshot)
setup_sysctl_hardening
rc=$?
after=$(_sysctl_kernel_snapshot)
assert_eq "0" "$rc" "sysctl apply: succeeds on a host with a conflicting sysctl.d file"
assert_eq "1" "$(<"$SYSCTL_KERNEL/net.ipv4.ip_forward")" "sysctl apply: ip_forward keeps Docker's value"
assert_eq "1" "$(<"$SYSCTL_KERNEL/net.ipv6.conf.all.forwarding")" "sysctl apply: IPv6 forwarding keeps its value"
changed=$(diff <(echo "$before") <(echo "$after") | sed -n 's/^> \(.*\)=.*/\1/p' | sort | tr '\n' ' ')
owned=$(_setup_sysctl_owned_pairs | cut -d' ' -f1 | sort | tr '\n' ' ')
assert_eq "$owned" "$changed" "sysctl apply: exactly MediaStack's keys changed"
assert_contains "$(<"$SYSCTL_LOG")" "OK Kernel hardening applied" "sysctl apply: reports success"

# Given the fake kernel ignores one MediaStack key,
# When the hardening is applied,
# Then it fails loudly naming the key, and never prints the success line.
_sysctl_test_reset
export FAKE_SYSCTL_IGNORE=net.ipv4.conf.all.rp_filter
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl apply: a key that does not take effect fails"
assert_contains "$(<"$SYSCTL_LOG")" "ERROR sysctl net.ipv4.conf.all.rp_filter is '9'" "sysctl apply: names the key that did not take effect"
assert_not_contains "$(<"$SYSCTL_LOG")" "OK Kernel hardening applied" "sysctl apply: no success line after a failed key"

# Given Docker is installed and applying the file somehow turns ip_forward off,
# When the hardening is applied,
# Then it fails loudly because forwarding no longer matches its prior value.
_sysctl_test_reset
export FAKE_SYSCTL_P_SETS=net.ipv4.ip_forward=0
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl apply: a changed ip_forward fails"
assert_contains "$(<"$SYSCTL_LOG")" "ERROR sysctl net.ipv4.ip_forward changed from '1' to '0'" "sysctl apply: names the forwarding change"
assert_not_contains "$(<"$SYSCTL_LOG")" "OK Kernel hardening applied" "sysctl apply: no success line after a forwarding change"

# Given UFW's sysctl.conf (slash-style keys) sets log_martians to 0,
# When the hardening is applied,
# Then it still applies and warns that UFW owns that key.
_sysctl_test_reset
MEDIASTACK_UFW_SYSCTL_CONF="$SYSCTL_TMPDIR/ufw-sysctl.conf"
printf '%s\n' '#net/ipv4/conf/all/log_martians=1' 'net/ipv4/conf/all/log_martians=0' 'net/ipv4/tcp_syncookies=1' >"$MEDIASTACK_UFW_SYSCTL_CONF"
setup_sysctl_hardening
rc=$?
assert_eq "0" "$rc" "sysctl apply: a UFW override does not fail the apply"
assert_contains "$(<"$SYSCTL_LOG")" "WARN UFW owns net.ipv4.conf.all.log_martians" "sysctl apply: warns that UFW owns log_martians"
assert_not_contains "$(<"$SYSCTL_LOG")" "UFW owns net.ipv4.tcp_syncookies" "sysctl apply: no UFW warning for a key UFW agrees on"

# Given MediaStack's file is applied and UFW has since reset log_martians to 0,
# When the recorded teardown runs,
# Then it keeps UFW's value, says UFW owns the key, and restores the untouched keys.
_ms_state_get() {
    case "$1" in
        SYSCTL_FILE_CREATED) echo true ;;
        SYSCTL_FILE_SHA256) _ms_root_sha256 "$MEDIASTACK_SYSCTL_CONF" ;;
        SYSCTL_BEFORE_*) echo 0 ;;
    esac
}
printf '0\n' >"$SYSCTL_KERNEL/net.ipv4.conf.all.log_martians"
: >"$SYSCTL_LOG"
_uninstall_sysctl
rc=$?
assert_eq "0" "$rc" "sysctl uninstall: succeeds with a UFW-overridden key"
assert_contains "$(<"$SYSCTL_LOG")" "UFW owns this key" "sysctl uninstall: wording says UFW owns the key"
assert_eq "0" "$(<"$SYSCTL_KERNEL/net.ipv4.tcp_syncookies")" "sysctl uninstall: restores an owned key to its recorded value"
assert_eq "1" "$(<"$SYSCTL_KERNEL/net.ipv4.ip_forward")" "sysctl uninstall: leaves ip_forward alone"
[[ ! -e "$MEDIASTACK_SYSCTL_CONF" ]] && pass "sysctl uninstall: owned file removed" || fail "sysctl uninstall: owned file removed"
assert_contains "$(<"$SYSCTL_TMPDIR/ledger")" "SYSCTL_APPLY_PENDING=false" "sysctl uninstall: clears pending apply state"

# Given MediaStack's file is applied and a later sysctl.d file has since reset a key,
# When setup runs again,
# Then it warns about the drifted key and does not rewrite the kernel value.
_sysctl_test_reset
setup_sysctl_hardening
_ms_state_get() {
    case "$1" in
        SYSCTL_FILE_CREATED) echo true ;;
        SYSCTL_FILE_SHA256) _ms_root_sha256 "$MEDIASTACK_SYSCTL_CONF" ;;
    esac
}
printf '0\n' >"$SYSCTL_KERNEL/net.ipv4.conf.all.rp_filter"
: >"$SYSCTL_LOG"
setup_sysctl_hardening
assert_contains "$(<"$SYSCTL_LOG")" "WARN Live kernel values differ" "sysctl re-run: warns on a drifted key"
assert_eq "0" "$(<"$SYSCTL_KERNEL/net.ipv4.conf.all.rp_filter")" "sysctl re-run: does not reconcile the drift"
eval "$_sysctl_saved_state_get"

# Given the first apply wrote the file and ledger but the fake kernel rejected a key,
# When setup is re-run until the kernel accepts the file,
# Then every incomplete apply fails loudly, the successful retry clears its debt, and the next run skips.
_sysctl_test_reset
_ms_state_get() {
    _sysctl_state_get "$1"
}
_ms_state_set() { _sysctl_state_set "$@"; }
log_skip() { printf 'SKIP %s\n' "$*" >>"$SYSCTL_LOG"; }
export FAKE_SYSCTL_IGNORE=net.ipv4.conf.all.rp_filter
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl re-run: first incomplete apply fails"
assert_eq "true" "$(_ms_state_get SYSCTL_APPLY_PENDING)" "sysctl re-run: first failed apply records pending"
: >"$SYSCTL_LOG"
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl re-run: incomplete apply fails again"
assert_contains "$(<"$SYSCTL_LOG")" "ERROR Kernel hardening was NOT applied cleanly" "sysctl re-run: incomplete apply reports an error"
assert_not_contains "$(<"$SYSCTL_LOG")" "SKIP Sysctl hardening already applied" "sysctl re-run: incomplete apply never skips"
unset FAKE_SYSCTL_IGNORE
: >"$SYSCTL_LOG"
setup_sysctl_hardening
rc=$?
assert_eq "0" "$rc" "sysctl re-run: retry succeeds after the kernel accepts the file"
assert_contains "$(<"$SYSCTL_LOG")" "OK Kernel hardening applied" "sysctl re-run: successful retry reports apply"
assert_eq "false" "$(_ms_state_get SYSCTL_APPLY_PENDING)" "sysctl re-run: successful retry clears pending"
: >"$SYSCTL_LOG"
setup_sysctl_hardening
assert_contains "$(<"$SYSCTL_LOG")" "SKIP Sysctl hardening already applied" "sysctl re-run: clean apply skips on the next run"
eval "$_sysctl_saved_state_get"
log_skip() { :; }

# Given persistent state rejects the pending marker before the file is owned,
# When the initial apply fails and setup is run again after state accepts it,
# Then no unapplied owned file is classified as complete and the retry applies it.
_sysctl_test_reset
_ms_state_get() { _sysctl_state_get "$1"; }
_ms_state_set() {
    [[ "$1=$2" == "SYSCTL_APPLY_PENDING=true" ]] && return 1
    _sysctl_state_set "$@"
}
log_skip() { printf 'SKIP %s\n' "$*" >>"$SYSCTL_LOG"; }
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl pending state: failed marker fails the initial apply"
assert_file_absent "$MEDIASTACK_SYSCTL_CONF" "sysctl pending state: failed marker leaves no owned file"
assert_not_contains "$(<"$SYSCTL_TMPDIR/ledger")" "SYSCTL_FILE_CREATED=true" "sysctl pending state: failed marker records no file ownership"
_ms_state_set() { _sysctl_state_set "$@"; }
: >"$SYSCTL_LOG"
setup_sysctl_hardening
rc=$?
assert_eq "0" "$rc" "sysctl pending state: retry applies after the marker can persist"
assert_contains "$(<"$SYSCTL_LOG")" "OK Kernel hardening applied" "sysctl pending state: retry reports apply"
assert_not_contains "$(<"$SYSCTL_LOG")" "SKIP Sysctl hardening already applied" "sysctl pending state: retry never skips an unapplied file"
eval "$_sysctl_saved_state_get"
log_skip() { :; }

# Given an owned file has malformed pending state,
# When setup checks the recorded apply status,
# Then it fails before applying the file or reporting a completed install.
_sysctl_test_reset
_ms_state_get() { _sysctl_state_get "$1"; }
_ms_state_set() { _sysctl_state_set "$@"; }
log_skip() { printf 'SKIP %s\n' "$*" >>"$SYSCTL_LOG"; }
setup_sysctl_hardening
_ms_state_set SYSCTL_APPLY_PENDING malformed
export FAKE_SYSCTL_APPLY_LOG="$SYSCTL_TMPDIR/applies"
: >"$FAKE_SYSCTL_APPLY_LOG"
: >"$SYSCTL_LOG"
setup_sysctl_hardening
rc=$?
assert_eq "1" "$rc" "sysctl pending state: malformed marker fails setup"
assert_contains "$(<"$SYSCTL_LOG")" "ERROR Invalid SYSCTL_APPLY_PENDING state" "sysctl pending state: malformed marker reports an error"
assert_not_contains "$(<"$SYSCTL_LOG")" "SKIP Sysctl hardening already applied" "sysctl pending state: malformed marker never skips"
assert_eq "" "$(<"$FAKE_SYSCTL_APPLY_LOG")" "sysctl pending state: malformed marker does not apply sysctl"
unset FAKE_SYSCTL_APPLY_LOG
eval "$_sysctl_saved_state_get"
log_skip() { :; }

# Given the kernel hardening step fails,
# When setup_hardening runs with the firewall and admin filter off,
# Then it returns non-zero so a set -e caller stops, and prints no completion line.
_sysctl_test_reset
_sysctl_saved_unattended=$(declare -f setup_unattended_upgrades)
_sysctl_saved_setup=$(declare -f setup_sysctl_hardening)
setup_unattended_upgrades() { :; }
setup_sysctl_hardening() { return 1; }
UFW_ENABLED=false ADMIN_PORT_FILTER=false HARDENING_ENABLED=true setup_hardening >/dev/null 2>&1
assert_eq "1" "$?" "setup_hardening: a failed kernel hardening step fails setup"
: >"$SYSCTL_LOG"
UFW_ENABLED=false ADMIN_PORT_FILTER=false HARDENING_ENABLED=true setup_hardening >/dev/null 2>&1
assert_not_contains "$(<"$SYSCTL_LOG")" "OK OS hardening step complete" "setup_hardening: no completion line after a failed kernel step"
eval "$_sysctl_saved_unattended"
eval "$_sysctl_saved_setup"

PATH="$_sysctl_saved_path"
eval "$_sysctl_saved_state_get"
eval "$_sysctl_saved_state_set"
unset -f sudo log_ok log_warn log_error _sysctl_test_reset _sysctl_kernel_snapshot _sysctl_state_set _sysctl_state_get
log_ok() { :; }
log_warn() { :; }
log_error() { :; }
unset FAKE_SYSCTL_D FAKE_KERNEL FAKE_SYSCTL_IGNORE FAKE_SYSCTL_P_SETS
rm -rf "$SYSCTL_TMPDIR"

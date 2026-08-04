#!/usr/bin/env bash
# Selective host-cleanup tests. External host commands are recorded; file
# mutations run only inside a temporary directory.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uninstall-system-cleanup"
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
MEDIASTACK_APT_AUTO_CONF="$TMP_DIR/21mediastack-auto-upgrades"
MEDIASTACK_APT_POLICY_CONF="$TMP_DIR/51mediastack-unattended-upgrades"
MEDIASTACK_SYSCTL_CONF="$TMP_DIR/90-mediastack-hardening.conf"
MEDIASTACK_UFW_AFTER_RULES="$TMP_DIR/after.rules"
SAMBA_INCLUDE_FILE="$TMP_DIR/samba-include.conf"
SAMBA_MAIN_CONF="$TMP_DIR/smb.conf"

# Root-only ledger reads go through sudo and are never sourced.
mkdir -p "$MEDIASTACK_STATE_DIR"
cat >"$MEDIASTACK_STATE_FILE" <<EOF
STATE_FORMAT=1
UFW_RULES_BEFORE_SHA256=$(printf user-rule | sha256sum | awk '{print $1}')
UFW_DEFAULT_INCOMING=deny
UFW_DEFAULT_OUTGOING=allow
UFW_DEFAULTS_APPLIED=false
UFW_ENABLED_BY_MEDIASTACK=false
UFW_RULE_COUNT=0
SYSCTL_FILE_CREATED=false
SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false
SAMBA_OWNERSHIP_RECORDED=false
SAMBA_CONFIGURED=false
EOF
chmod 0600 "$MEDIASTACK_STATE_FILE"
SUDO_TRACE="$TMP_DIR/sudo-trace"
sudo() {
    printf '%s\n' "$1" >>"$SUDO_TRACE"
    command "$@"
}
assert_eq "1" "$(_ms_state_get STATE_FORMAT)" "ledger: root-owned state is read through sudo"
assert_contains "$(cat "$SUDO_TRACE")" "awk" "ledger: reader invokes sudo awk"
validate_install_state
assert_eq "0" "$?" "ledger: valid ownership state accepted"
unset -f sudo

# Tagged UFW rules are removed in descending order; user rules and later text survive.
UFW_CALLS=()
NUMBERED_MARKER="$TMP_DIR/numbered-read"
printf '%s\n' '# MEDIASTACK-DOCKER-RULES' '*filter' 'COMMIT' '# END MEDIASTACK-DOCKER-RULES' '# user tail' >"$MEDIASTACK_UFW_AFTER_RULES"
user_rules='ufw allow 9999/tcp'
user_hash=$(printf '%s\n' "$user_rules" | sha256sum | awk '{print $1}')
_ms_state_get() {
    case "$1" in
        UFW_DEFAULTS_APPLIED | UFW_ENABLED_BY_MEDIASTACK) echo true ;;
        UFW_DEFAULT_INCOMING) echo deny ;;
        UFW_DEFAULT_OUTGOING) echo allow ;;
        UFW_RULES_BEFORE_SHA256) echo "$user_hash" ;;
    esac
}
sudo() {
    if [[ "$1" == ufw ]]; then
        UFW_CALLS+=("${*:2}")
        case "${*:2}" in
            "status numbered")
                if [[ ! -e "$NUMBERED_MARKER" ]]; then
                    touch "$NUMBERED_MARKER"
                    printf '%s\n' '[ 1] 9999/tcp ALLOW Anywhere # user' '[ 2] 80/tcp ALLOW Anywhere # MediaStack:HTTP-ACME' '[ 4] 443/tcp ALLOW Anywhere # MediaStack:HTTPS'
                else
                    printf '%s\n' '[ 1] 9999/tcp ALLOW Anywhere # user'
                fi
                ;;
            "status verbose") printf '%s\n' 'Status: active' 'Default: deny (incoming), allow (outgoing), disabled (routed)' ;;
            "status") echo 'Status: active' ;;
            "show added") printf '%s\n' "$user_rules" ;;
        esac
        return 0
    fi
    if [[ "$1" == iptables ]]; then return 1; fi
    command "$@"
}
_uninstall_ufw
assert_eq "0" "$?" "UFW: selective cleanup succeeds"
assert_contains "${UFW_CALLS[*]}" "--force delete 4" "UFW: highest tagged rule deleted first"
case "${UFW_CALLS[*]}" in
    *"--force delete 4"*"--force delete 2"*) pass "UFW: tagged rules deleted in descending order" ;;
    *) fail "UFW: tagged rules deleted in descending order" "${UFW_CALLS[*]}" ;;
esac
assert_contains "$(cat "$MEDIASTACK_UFW_AFTER_RULES")" "# user tail" "UFW: content after owned block survives"
assert_contains "${UFW_CALLS[*]}" "--force disable" "UFW: firewall enabled by MediaStack is disabled when no drift remains"
unset -f sudo

# SSH lockout guard: when the user added their own rules (drift), UFW is left
# active with default-deny AFTER our SSH allows are removed. The guard must
# re-add an SSH allow (LAN ranges + active session) so a remote admin is not
# locked out. Here: MediaStack enabled UFW, user drift present -> not disabled.
UFW_CALLS=()
unset SSH_CONNECTION
: >"$MEDIASTACK_UFW_AFTER_RULES"
empty_hash=$(printf '' | sha256sum | awk '{print $1}')
_ms_state_get() {
    case "$1" in
        UFW_DEFAULTS_APPLIED | UFW_ENABLED_BY_MEDIASTACK) echo true ;;
        UFW_DEFAULT_INCOMING) echo deny ;;
        UFW_DEFAULT_OUTGOING) echo allow ;;
        UFW_RULES_BEFORE_SHA256) echo "$empty_hash" ;; # drift: live rules differ
        UFW_RULE_COUNT) echo 0 ;;
    esac
}
detect_ssh_server_ports() { echo 22; }
sudo() {
    if [[ "$1" == ufw ]]; then
        UFW_CALLS+=("${*:2}")
        case "${*:2}" in
            "status numbered") echo 'Status: active' ;; # no MediaStack-tagged rules
            "show added") echo 'ufw allow 9999/tcp' ;;  # untagged user rule = drift
            "status verbose") printf '%s\n' 'Status: active' 'Default: deny (incoming), allow (outgoing), disabled (routed)' ;;
            "status") echo 'Status: active' ;;
        esac
        return 0
    fi
    [[ "$1" == iptables ]] && return 1
    command "$@"
}
_uninstall_ufw
assert_eq "0" "$?" "UFW SSH guard: uninstall with user drift succeeds"
case "${UFW_CALLS[*]}" in
    *"--force disable"*) fail "UFW SSH guard: must NOT disable a firewall carrying user drift" "${UFW_CALLS[*]}" ;;
    *) pass "UFW SSH guard: leaves user-modified firewall active" ;;
esac
assert_contains "${UFW_CALLS[*]}" "allow from 10.0.0.0/8 to any port 22 proto tcp" \
    "UFW SSH guard: re-adds LAN SSH allow so removing our rules cannot lock out SSH"
unset -f sudo detect_ssh_server_ports

# SSH lockout guard, IPv6 session: a remote admin on an IPv6-only SSH connection
# must have their session source re-allowed too (the install path preserves it via
# ufw_valid_ip_literal). Same drift setup as above, but SSH_CONNECTION is IPv6.
UFW_CALLS=()
# shellcheck disable=SC2034  # read by _uninstall_ufw, sourced via hardening/firewall.sh
SSH_CONNECTION="2001:db8::1 55123 2001:db8::20 2222"
detect_ssh_server_ports() { echo 22; }
sudo() {
    if [[ "$1" == ufw ]]; then
        UFW_CALLS+=("${*:2}")
        case "${*:2}" in
            "status numbered") echo 'Status: active' ;;
            "show added") echo 'ufw allow 9999/tcp' ;;
            "status verbose") printf '%s\n' 'Status: active' 'Default: deny (incoming), allow (outgoing), disabled (routed)' ;;
            "status") echo 'Status: active' ;;
        esac
        return 0
    fi
    [[ "$1" == iptables ]] && return 1
    command "$@"
}
_uninstall_ufw
assert_eq "0" "$?" "UFW SSH guard (IPv6): uninstall with user drift succeeds"
assert_contains "${UFW_CALLS[*]}" "allow from 2001:db8::1 to any port 2222 proto tcp" \
    "UFW SSH guard (IPv6): re-adds the IPv6 session allow so an IPv6-only admin is not locked out"
unset -f sudo detect_ssh_server_ports
unset SSH_CONNECTION

# An inactive firewall has no numbered status; the recorded exact rule still removes ownership.
INACTIVE_DELETED="$TMP_DIR/inactive-deleted"
UFW_CALLS=()
_ms_state_get() {
    case "$1" in
        UFW_RULE_COUNT) echo 1 ;;
        UFW_RULE_1) echo 'allow 80/tcp comment MediaStack:HTTP-ACME' ;;
        UFW_DEFAULTS_APPLIED | UFW_ENABLED_BY_MEDIASTACK) echo false ;;
        UFW_RULES_BEFORE_SHA256) printf '' | sha256sum | awk '{print $1}' ;;
        UFW_DEFAULT_INCOMING) echo deny ;;
        UFW_DEFAULT_OUTGOING) echo allow ;;
    esac
}
sudo() {
    if [[ "$1" == ufw ]]; then
        UFW_CALLS+=("${*:2}")
        case "${*:2}" in
            "status numbered") echo 'Status: inactive' ;;
            "show added") [[ -e "$INACTIVE_DELETED" ]] || echo "ufw allow 80/tcp comment 'MediaStack:HTTP-ACME'" ;;
            "--force delete allow 80/tcp comment MediaStack:HTTP-ACME") touch "$INACTIVE_DELETED" ;;
            "status verbose") printf '%s\n' 'Status: inactive' 'Default: deny (incoming), allow (outgoing), disabled (routed)' ;;
        esac
        return 0
    fi
    [[ "$1" == iptables ]] && return 1
    command "$@"
}
_uninstall_ufw
assert_eq "0" "$?" "UFW: inactive firewall cleanup uses recorded exact rule"
assert_contains "${UFW_CALLS[*]}" "delete allow 80/tcp comment MediaStack:HTTP-ACME" "UFW: exact owned rule deleted without enabling firewall"
unset -f sudo

# Edited owned APT files fail closed and remain on disk.
printf 'managed\n' >"$MEDIASTACK_APT_AUTO_CONF"
printf 'managed\n' >"$MEDIASTACK_APT_POLICY_CONF"
auto_hash=$(sha256sum "$MEDIASTACK_APT_AUTO_CONF" | awk '{print $1}')
policy_hash=$(sha256sum "$MEDIASTACK_APT_POLICY_CONF" | awk '{print $1}')
_ms_state_get() { [[ "$1" == APT_AUTO_SHA256 ]] && echo "$auto_hash" || echo "$policy_hash"; }
sudo() { command "$@"; }
printf 'user edit\n' >>"$MEDIASTACK_APT_POLICY_CONF"
_uninstall_apt
assert_eq "1" "$?" "APT: edited owned drop-in makes cleanup incomplete"
[[ -f "$MEDIASTACK_APT_POLICY_CONF" ]] && pass "APT: edited drop-in preserved" || fail "APT: edited drop-in preserved"
unset -f sudo

# Live sysctl values are restored only while still at MediaStack's value.
printf 'managed sysctl\n' >"$MEDIASTACK_SYSCTL_CONF"
sysctl_hash=$(sha256sum "$MEDIASTACK_SYSCTL_CONF" | awk '{print $1}')
SYSCTL_WRITES=()
_ms_state_get() {
    case "$1" in
        SYSCTL_FILE_CREATED) echo true ;;
        SYSCTL_FILE_SHA256) echo "$sysctl_hash" ;;
        SYSCTL_BEFORE_*) echo 7 ;;
    esac
}
sysctl() {
    [[ "$1" == -n ]] || return 0
    case "$2" in
        *.accept_redirects | *.send_redirects) echo 0 ;;
        *) echo 1 ;;
    esac
}
sudo() {
    if [[ "$1" == sysctl ]]; then
        SYSCTL_WRITES+=("$*")
        return 0
    fi
    command "$@"
}
_uninstall_sysctl
assert_eq "0" "$?" "sysctl: unchanged managed file is removed"
assert_eq "10" "${#SYSCTL_WRITES[@]}" "sysctl: every unchanged live key is restored"
[[ ! -e "$MEDIASTACK_SYSCTL_CONF" ]] && pass "sysctl: owned file removed" || fail "sysctl: owned file removed"
unset -f sudo sysctl

# Ownership is recorded before the sysctl file/apply mutations, so a failed
# first install cannot leave an untracked file that uninstall later skips.
SYSCTL_TRACE="$TMP_DIR/sysctl-order"
rm -f "$MEDIASTACK_SYSCTL_CONF"
_ms_state_set() { printf 'state:%s\n' "$1" >>"$SYSCTL_TRACE"; }
_ms_state_get() { echo false; }
sysctl() { [[ "$1" == -n ]] && echo 0 || return 1; }
sudo() {
    printf 'sudo:%s\n' "$1" >>"$SYSCTL_TRACE"
    [[ "$1" == sysctl ]] && return 1
    command "$@"
}
setup_sysctl_hardening >/dev/null 2>&1
case "$(tr '\n' ' ' <"$SYSCTL_TRACE")" in
    *"state:SYSCTL_FILE_CREATED sudo:tee"*"state:SYSCTL_FILE_SHA256 sudo:sysctl"*)
        pass "sysctl: ownership is durable before file creation and apply"
        ;;
    *) fail "sysctl: ownership is durable before file creation and apply" "$(cat "$SYSCTL_TRACE")" ;;
esac
unset -f sudo sysctl _ms_state_set

# Samba removes only recorded ownership and never invokes autoremove/userdel.
printf 'managed samba\n' >"$SAMBA_INCLUDE_FILE"
printf '%s\n' '[global]' '# MEDIASTACK include - managed by setup.sh' "include = $SAMBA_INCLUDE_FILE" >"$SAMBA_MAIN_CONF"
samba_hash=$(sha256sum "$SAMBA_INCLUDE_FILE" | awk '{print $1}')
effective='effective config'
effective_hash=$(printf '%s\n' "$effective" | sha256sum | awk '{print $1}')
SAMBA_CALLS=()
id() { [[ "$1" == -nG ]] && echo media; }
smbd() { :; }
_ms_state_get() {
    case "$1" in
        SAMBA_CONFIGURED | SAMBA_OWNERSHIP_RECORDED | SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK | SAMBA_PASSDB_CREATED_BY_MEDIASTACK | SAMBA_GROUP_ADDED_BY_MEDIASTACK) echo true ;;
        SAMBA_SETUP_PENDING) echo false ;;
        SAMBA_INCLUDE_SHA256) echo "$samba_hash" ;;
        SAMBA_EFFECTIVE_SHA256) echo "$effective_hash" ;;
        SAMBA_USER) echo mediaadmin ;;
        SAMBA_PASSDB_PREEXISTED | SAMBA_GROUP_PREEXISTED) echo false ;;
        SAMBA_GROUP) echo media ;;
    esac
}
sudo() {
    case "$1" in
        testparm) printf '%s\n' "$effective" ;;
        pdbedit) return 0 ;;
        smbpasswd | gpasswd | apt-get | systemctl)
            SAMBA_CALLS+=("$*")
            return 0
            ;;
        *) command "$@" ;;
    esac
}
_uninstall_samba
assert_eq "0" "$?" "Samba: owned configuration cleanup succeeds"
assert_contains "${SAMBA_CALLS[*]}" "smbpasswd -x mediaadmin" "Samba: MediaStack-created passdb principal removed"
assert_contains "${SAMBA_CALLS[*]}" "gpasswd -d mediaadmin media" "Samba: MediaStack-added group membership removed"
assert_contains "${SAMBA_CALLS[*]}" "apt-get remove -y -qq samba" "Samba: explicitly owned package removed"
case "${SAMBA_CALLS[*]}" in
    *autoremove* | *userdel*) fail "Samba: no autoremove or Linux-account deletion" "${SAMBA_CALLS[*]}" ;;
    *) pass "Samba: no autoremove or Linux-account deletion" ;;
esac

# A failed first install may record intent before applying any mutation. It must
# fail closed rather than deleting state an administrator created afterwards.
rm -f "$SAMBA_INCLUDE_FILE"
SAMBA_CALLS=()
_ms_state_get() {
    case "$1" in
        SAMBA_OWNERSHIP_RECORDED | SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK | SAMBA_SETUP_PENDING) echo true ;;
        SAMBA_CONFIGURED | SAMBA_PASSDB_PREEXISTED | SAMBA_GROUP_PREEXISTED | SAMBA_PASSDB_CREATED_BY_MEDIASTACK | SAMBA_GROUP_ADDED_BY_MEDIASTACK) echo false ;;
        SAMBA_USER) echo mediaadmin ;;
        SAMBA_GROUP) echo media ;;
        SAMBA_SERVICE_WAS_ENABLED | SAMBA_SERVICE_WAS_ACTIVE) echo false ;;
    esac
}
_uninstall_samba
assert_eq "1" "$?" "Samba: partial install fails closed"
assert_eq "" "${SAMBA_CALLS[*]}" "Samba: partial install removes no ambiguous admin state"
unset -f id smbd

# Failed Docker teardown retains secrets and restores a previously active watchdog.
ORIGINAL_SCRIPT_DIR="$SCRIPT_DIR"
SCRIPT_DIR="$TMP_DIR/checkout"
mkdir -p "$SCRIPT_DIR"
touch "$SCRIPT_DIR/.env"
WATCHDOG_CALLS=()
ui_input() { echo DESTROY; }
storage_pause_watchdog_for_install() { return 0; }
docker() {
    [[ "$*" == *" down "* ]] && return 42
    return 0
}
sudo() {
    if [[ "$1" == systemctl ]]; then
        case "$2" in
            is-enabled | is-active) return 0 ;;
            *)
                WATCHDOG_CALLS+=("${*:2}")
                return 0
                ;;
        esac
    fi
    command "$@"
}
nuke_existing_install uninstall >/dev/null 2>&1
assert_eq "42" "$?" "transaction: Docker teardown failure is returned"
[[ -f "$SCRIPT_DIR/.env" ]] && pass "transaction: .env retained after teardown failure" || fail "transaction: .env retained after teardown failure"
assert_contains "${WATCHDOG_CALLS[*]}" "enable mediastack-storage-watchdog.service" "transaction: watchdog enable state restored"
assert_contains "${WATCHDOG_CALLS[*]}" "start mediastack-storage-watchdog.service" "transaction: watchdog active state restored"
SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR"

# --uninstall dispatch precedes a ready Stage 3 marker.
STAGE3_CALLS=0
ui_banner() { :; }
check_not_root() { :; }
check_debian() { :; }
prompt_sudo_cache() { :; }
validate_install_state() { return 1; }
stage3_marker_exists() {
    STAGE3_CALLS=$((STAGE3_CALLS + 1))
    return 0
}
record_launcher_outcome() { :; }
main --uninstall >/dev/null 2>&1
assert_eq "1" "$?" "routing: invalid-ledger uninstall fails closed"
assert_eq "0" "$STAGE3_CALLS" "routing: Stage 3 marker cannot intercept uninstall"

scenario_end "$CURRENT_SCENARIO"
summary

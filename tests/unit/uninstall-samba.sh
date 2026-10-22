#!/usr/bin/env bash
# Samba uninstall tests for the Linux account and package: ledger-owned accounts
# are deleted, anything else is kept. External host commands are stubbed.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uninstall-samba"
scenario_begin "$CURRENT_SCENARIO"
source "$REPO_ROOT/setup.sh"
set +e +u
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SAMBA_INCLUDE_FILE="$TMP_DIR/samba-include.conf"
SAMBA_MAIN_CONF="$TMP_DIR/smb.conf"
effective='effective config'
effective_hash=$(printf '%s\n' "$effective" | sha256sum | awk '{print $1}')

# Given a Linux account MediaStack created, with no processes or stray files
# When Samba is uninstalled
# Then the package is purged and the account is deleted
# And a pre-existing account or package is left alone
samba_fixture() { # <user-preexisted> <package-installed-by-mediastack>
    SAMBA_USER_PRE="$1" SAMBA_PKG_OURS="$2"
    printf 'managed samba\n' >"$SAMBA_INCLUDE_FILE"
    printf '%s\n' '[global]' "include = $SAMBA_INCLUDE_FILE" >"$SAMBA_MAIN_CONF"
    samba_hash=$(sha256sum "$SAMBA_INCLUDE_FILE" | awk '{print $1}')
    SAMBA_CALLS=()
    SAMBA_STATE=()
    unset SAMBA_GROUPS_PRE
    SAMBA_PURGED_STATE=false SAMBA_WINBIND_STATUS="un " SAMBA_TESTPARM_GONE=false
}
id() {
    [[ "$1" == -nG ]] || return 0
    echo media
}
smbd() { :; }
_ms_state_get() {
    case "$1" in
        SAMBA_OWNERSHIP_RECORDED) echo true ;;
        SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK) echo "$SAMBA_PKG_OURS" ;;
        SAMBA_USER_PREEXISTED) echo "$SAMBA_USER_PRE" ;;
        SAMBA_GROUPS_PREEXISTED) [[ -v SAMBA_GROUPS_PRE ]] && echo "$SAMBA_GROUPS_PRE" || return 1 ;;
        SAMBA_PURGED) echo "${SAMBA_PURGED_STATE:-false}" ;;
        SAMBA_SETUP_PENDING | SAMBA_PASSDB_PREEXISTED | SAMBA_PASSDB_CREATED_BY_MEDIASTACK | SAMBA_GROUP_ADDED_BY_MEDIASTACK | SAMBA_GROUP_PREEXISTED) echo false ;;
        SAMBA_INCLUDE_SHA256) echo "$samba_hash" ;;
        SAMBA_EFFECTIVE_SHA256) echo "$effective_hash" ;;
        SAMBA_CONFIG_ADOPTED) echo "${SAMBA_ADOPTED_STATE:-}" ;;
        SAMBA_USER) echo mediaadmin ;;
        SAMBA_SERVICE_WAS_ENABLED | SAMBA_SERVICE_WAS_ACTIVE) echo true ;;
    esac
}
getent() { # <database> <group>: every group exists, all empty
    [[ "$1" == group ]] || return 2
    echo "$2:x:100:"
}
dpkg-query() { echo "${SAMBA_WINBIND_STATUS:-un }"; }
_ms_state_set() { SAMBA_STATE+=("$1=$2"); }
sudo() {
    case "$1" in
        testparm)
            [[ "${SAMBA_TESTPARM_GONE:-}" == true ]] && return 1
            printf '%s\n' "$effective"
            ;;
        pgrep) return "${SAMBA_PGREP_RC:-1}" ;;
        find) printf '%s' "${SAMBA_STRAY:-}" ;;
        userdel | apt-get | env | systemctl | groupdel)
            SAMBA_CALLS+=("$*")
            return 0
            ;;
        *) command "$@" ;;
    esac
}
SAMBA_PGREP_RC=1 SAMBA_STRAY=""

samba_fixture false true
_uninstall_samba
assert_eq "0" "$?" "Samba account: owned uninstall succeeds"
assert_contains "${SAMBA_CALLS[*]}" "apt-get purge -y -qq samba" "Samba account: MediaStack-installed package is purged"
assert_contains "${SAMBA_CALLS[*]}" "userdel mediaadmin" "Samba account: ledger-owned Linux account is deleted"

samba_fixture true false
_uninstall_samba
assert_eq "0" "$?" "Samba account: pre-existing uninstall succeeds"
assert_not_contains "${SAMBA_CALLS[*]}" "userdel" "Samba account: pre-existing Linux account is kept"
assert_not_contains "${SAMBA_CALLS[*]}" "apt-get" "Samba account: pre-existing package is kept"

# Given a ledger-owned account that still runs a process
# When Samba is uninstalled
# Then the account is kept
samba_fixture false true
SAMBA_PGREP_RC=0
_uninstall_samba
assert_not_contains "${SAMBA_CALLS[*]}" "userdel" "Samba account: kept while it has running processes"

# Given a ledger-owned account that owns a file outside MediaStack paths
# When Samba is uninstalled
# Then the account is kept
samba_fixture false true
SAMBA_PGREP_RC=1 SAMBA_STRAY="/home/other/file"
_uninstall_samba
assert_not_contains "${SAMBA_CALLS[*]}" "userdel" "Samba account: kept while it owns files outside MediaStack paths"

# Given a Samba package MediaStack installed and a ledger saying both Samba groups were absent before
# When Samba is uninstalled
# Then both groups are removed
samba_fixture false true
SAMBA_GROUPS_PRE=""
_uninstall_samba
assert_contains "${SAMBA_CALLS[*]}" "groupdel sambashare" "Samba groups: a group MediaStack introduced is removed"
assert_contains "${SAMBA_CALLS[*]}" "groupdel winbindd_priv" "Samba groups: winbindd_priv is removed when winbind is absent"

# Given a ledger saying both groups existed before MediaStack
# When Samba is uninstalled
# Then neither group is removed
samba_fixture false true
SAMBA_GROUPS_PRE="sambashare winbindd_priv"
_uninstall_samba
assert_not_contains "${SAMBA_CALLS[*]}" "groupdel" "Samba groups: groups the host already had are kept"

# Given a ledger from before groups were recorded
# When Samba is uninstalled
# Then no group is removed
samba_fixture false true
_uninstall_samba
assert_not_contains "${SAMBA_CALLS[*]}" "groupdel" "Samba groups: a missing ledger key keeps the groups"

# Given winbind is still installed after the Samba purge and the ledger says winbindd_priv was absent
# When Samba is uninstalled
# Then winbindd_priv is kept for winbind and sambashare is removed
samba_fixture false true
SAMBA_GROUPS_PRE=""
SAMBA_WINBIND_STATUS="ii "
_uninstall_samba
assert_not_contains "${SAMBA_CALLS[*]}" "groupdel winbindd_priv" "Samba groups: winbindd_priv stays while winbind is installed"
assert_contains "${SAMBA_CALLS[*]}" "groupdel sambashare" "Samba groups: sambashare is still removed"

SAMBA_PGREP_RC=1 SAMBA_STRAY=""

# Given the purge succeeded
# When Samba is uninstalled
# Then the purge is recorded in the ledger
samba_fixture false true
_uninstall_samba
assert_contains "${SAMBA_STATE[*]}" "SAMBA_PURGED=true" "Samba purge: recorded in the ledger"

# Given a retry after a purge, where testparm is gone so the config hash differs
# When Samba is uninstalled
# Then the account is still removed, not reported as adopted
samba_fixture false true
SAMBA_PURGED_STATE=true SAMBA_TESTPARM_GONE=true
unset -f smbd
_uninstall_samba
assert_contains "${SAMBA_CALLS[*]}" "userdel mediaadmin" "Samba retry: purged package does not read as adopted"
assert_not_contains "${SAMBA_CALLS[*]}" "apt-get" "Samba retry: package is not purged twice"

# Given the ledger remembers that the user's config was adopted, though the live hash matches again
# When Samba is uninstalled
# Then the package, the account and the groups are kept
samba_fixture false true
SAMBA_ADOPTED_STATE=true SAMBA_GROUPS_PRE=""
smbd() { :; }
_uninstall_samba
assert_eq "0" "$?" "Samba adopted flag: uninstall succeeds"
assert_not_contains "${SAMBA_CALLS[*]}" "apt-get" "Samba adopted flag: package kept although the hash matches"
assert_not_contains "${SAMBA_CALLS[*]}" "userdel" "Samba adopted flag: account kept"
assert_not_contains "${SAMBA_CALLS[*]}" "groupdel" "Samba adopted flag: groups kept"
unset -f smbd
unset SAMBA_ADOPTED_STATE

unset -f id getent samba_fixture dpkg-query
unset SAMBA_GROUPS_PRE SAMBA_PURGED_STATE SAMBA_WINBIND_STATUS SAMBA_TESTPARM_GONE
SAMBA_PGREP_RC=1 SAMBA_STRAY=""

summary

# Owns: SMB OFF behavior tests (service stop, firewall rules, ledger).
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/samba.sh.

# ===========================================================================
# setup_samba — SMB OFF with the ledger recording a configured share
# Bug: OFF removed only the include file, leaving smbd listening and the
# MediaStack:SMB-LAN firewall rules open.
# ===========================================================================

OFF_SAVED_FUNCS=$(declare -f ufw_installed _ms_state_get _ms_state_set _ms_stream_sha256)
off_fixture() { # <package-installed-by-mediastack> [recorded-effective-hash]
    OFF_PKG_OURS="$1"
    OFF_EFFECTIVE="${2:-deadbeef}"
    OFF_UFW_INACTIVE=false
    OFF_UFW_FAIL=""
    OFF_CALLS=()
    OFF_STATE=()
    mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
    printf '[Media]\n   path = /data\n' >"$SAMBA_INCLUDE_FILE"
}
ufw_installed() { return 0; }
_ms_state_get() {
    case "$1" in
        SAMBA_CONFIGURED) echo true ;;
        SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK) echo "$OFF_PKG_OURS" ;;
        SAMBA_EFFECTIVE_SHA256) echo "$OFF_EFFECTIVE" ;;
        UFW_RULE_COUNT) echo 4 ;;
        UFW_RULE_1) echo "allow from 10.0.0.0/8 to any port 445 proto tcp comment MediaStack:SMB-LAN" ;;
        UFW_RULE_2) echo "allow 22/tcp comment MediaStack:SSH" ;;
        UFW_RULE_3) echo "allow from 172.16.0.0/12 to any port 445 proto tcp comment MediaStack:SMB-LAN" ;;
        UFW_RULE_4) echo "allow 80/tcp comment MediaStack:HTTP" ;;
        *) return 1 ;;
    esac
}
_ms_state_set() { OFF_STATE+=("$1=$2"); }
_ms_stream_sha256() {
    cat >/dev/null
    echo deadbeef
}
sudo() {
    case "$1" in
        ufw)
            if [[ "$2" == status && "$OFF_UFW_INACTIVE" == true ]]; then
                echo 'Status: inactive'
                return 0
            fi
            if [[ "$2" == status ]]; then
                printf '%s\n' \
                    'Status: active' '' \
                    '     To                         Action      From' \
                    '     --                         ------      ----' \
                    '[ 1] 22/tcp                     ALLOW IN    Anywhere                   # MediaStack:SSH' \
                    '[ 2] 445/tcp                    ALLOW IN    10.0.0.0/8                 # MediaStack:SMB-LAN' \
                    '[ 3] 445/tcp                    ALLOW IN    192.168.0.0/16             # MediaStack:SMB-LAN' \
                    '[ 4] 445/tcp                    ALLOW IN    192.168.9.9                # my own smb rule' \
                    '[10] 445/tcp                    ALLOW IN    172.16.0.0/12              # MediaStack:SMB-LAN-extra' \
                    '[11] 445/tcp                    ALLOW IN    172.16.0.0/12              # MediaStack:SMB-LAN'
                return 0
            fi
            OFF_CALLS+=("$*")
            [[ -z "$OFF_UFW_FAIL" || "$*" != *"$OFF_UFW_FAIL"* ]] || return 1
            ;;
        rm) command "$@" ;;
        testparm) echo cfg ;;
        *) OFF_CALLS+=("$*") ;;
    esac
    return 0
}
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="false"

# Given MediaStack installed Samba and configured the share
# When SMB is turned off
# Then smbd and nmbd are stopped and disabled
# And only the exact MediaStack:SMB-LAN firewall rules are deleted, highest number first
# And the ledger drops the SMB rules and keeps the others
off_fixture true
[[ -f "$SAMBA_INCLUDE_FILE" ]] || fail "SMB OFF fixture: include exists before the call" "fixture did not create $SAMBA_INCLUDE_FILE"
setup_samba
assert_eq "0" "$?" "SMB OFF (MediaStack Samba): succeeds"
assert_contains "${OFF_CALLS[*]}" "systemctl disable --now smbd" "SMB OFF (MediaStack Samba): smbd stopped and disabled"
assert_contains "${OFF_CALLS[*]}" "systemctl disable --now nmbd" "SMB OFF (MediaStack Samba): nmbd stopped and disabled"
assert_contains "${OFF_CALLS[*]}" "ufw --force delete 11 ufw --force delete 3 ufw --force delete 2 ufw reload" \
    "SMB OFF (MediaStack Samba): exact SMB rules deleted highest first"
assert_not_contains "${OFF_CALLS[*]}" "delete 10" "SMB OFF: a longer MediaStack tag is not matched"
assert_not_contains "${OFF_CALLS[*]}" "delete 4" "SMB OFF: a user's own port-445 rule is not matched"
assert_not_contains "${OFF_CALLS[*]}" "delete 1 " "SMB OFF: other MediaStack rules are kept"
assert_contains "${OFF_STATE[*]}" "UFW_RULE_2=allow 80/tcp comment MediaStack:HTTP" "SMB OFF: ledger compacted around kept rules"
assert_contains "${OFF_STATE[*]}" "UFW_RULE_COUNT=2" "SMB OFF: ledger rule count reduced"

# Given a Samba that was installed before MediaStack
# When SMB is turned off
# Then the daemons keep running (reloaded, never stopped or disabled)
# And MediaStack's include and firewall rules are still removed
off_fixture false
[[ -f "$SAMBA_INCLUDE_FILE" ]] || fail "SMB OFF fixture: include exists before the call" "fixture did not create $SAMBA_INCLUDE_FILE"
setup_samba
assert_eq "0" "$?" "SMB OFF (user Samba): succeeds"
assert_not_contains "${OFF_CALLS[*]}" "disable" "SMB OFF (user Samba): service is not disabled"
assert_not_contains "${OFF_CALLS[*]}" " stop" "SMB OFF (user Samba): service is not stopped"
assert_contains "${OFF_CALLS[*]}" "systemctl reload smbd" "SMB OFF (user Samba): service reloaded without the share"
assert_contains "${OFF_CALLS[*]}" "ufw --force delete 2" "SMB OFF (user Samba): MediaStack SMB rules still removed"
[[ ! -f "$SAMBA_INCLUDE_FILE" ]] \
    && pass "SMB OFF (user Samba): MediaStack share block removed" \
    || fail "SMB OFF (user Samba): MediaStack share block removed" "include still present"

# Given MediaStack installed Samba and the user has since added their own shares
# When SMB is turned off
# Then the daemons keep running (reloaded, never stopped or disabled)
# And MediaStack's include and firewall rules are still removed
# And the recorded config hash is left alone, so a repeated OFF stays safe
off_fixture true "$(printf '%064d' 0)"
[[ -f "$SAMBA_INCLUDE_FILE" ]] || fail "SMB OFF fixture: include exists before the call" "fixture did not create $SAMBA_INCLUDE_FILE"
setup_samba
assert_eq "0" "$?" "SMB OFF (adopted Samba): succeeds"
assert_not_contains "${OFF_CALLS[*]}" "disable" "SMB OFF (adopted Samba): user's shares keep serving"
assert_contains "${OFF_CALLS[*]}" "systemctl reload smbd" "SMB OFF (adopted Samba): service reloaded without MediaStack's share"
assert_contains "${OFF_CALLS[*]}" "ufw --force delete 2" "SMB OFF (adopted Samba): MediaStack SMB rules still removed"
assert_not_contains "${OFF_STATE[*]}" "SAMBA_EFFECTIVE_SHA256" "SMB OFF (adopted Samba): recorded hash stays adopted"
[[ ! -f "$SAMBA_INCLUDE_FILE" ]] \
    && pass "SMB OFF (adopted Samba): MediaStack share block removed" \
    || fail "SMB OFF (adopted Samba): MediaStack share block removed" "include still present"

# Given ufw is installed but inactive, so it lists no numbered rules
# When SMB is turned off
# Then each SMB rule is deleted by the spec recorded in the ledger
# And the ledger keeps the non-SMB rules
off_fixture true
OFF_UFW_INACTIVE=true
setup_samba
assert_eq "0" "$?" "SMB OFF (inactive ufw): succeeds"
assert_contains "${OFF_CALLS[*]}" "ufw --force delete allow from 10.0.0.0/8 to any port 445 proto tcp" \
    "SMB OFF (inactive ufw): first SMB rule deleted by spec"
assert_contains "${OFF_CALLS[*]}" "ufw --force delete allow from 172.16.0.0/12 to any port 445 proto tcp" \
    "SMB OFF (inactive ufw): second SMB rule deleted by spec"
assert_contains "${OFF_STATE[*]}" "UFW_RULE_COUNT=2" "SMB OFF (inactive ufw): ledger drops the deleted SMB rules"

# Given ufw is inactive and deleting one SMB rule fails
# When SMB is turned off
# Then the command fails
# And the ledger still lists the rule that could not be deleted
off_fixture true
OFF_UFW_INACTIVE=true
OFF_UFW_FAIL="from 10.0.0.0/8"
setup_samba
assert_eq "1" "$?" "SMB OFF (inactive ufw, failed delete): reports failure"
assert_contains "${OFF_STATE[*]}" "UFW_RULE_COUNT=3" "SMB OFF (inactive ufw, failed delete): undeleted rule stays in the ledger"
assert_contains "${OFF_STATE[*]}" "UFW_RULE_3=allow 80/tcp comment MediaStack:HTTP" \
    "SMB OFF (inactive ufw, failed delete): ledger compacts around the deleted rule only"
unset -f sudo off_fixture
unset OFF_UFW_INACTIVE OFF_UFW_FAIL OFF_EFFECTIVE
eval "$OFF_SAVED_FUNCS"

# ===========================================================================
# setup_samba — a re-run on an owned install keeps the recorded hashes
# ===========================================================================
RERUN_SAVED_FUNCS=$(declare -f _ms_state_set _ms_state_get)
mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
printf '[Media]\n   path = /data\n' >"$SAMBA_INCLUDE_FILE"
printf '[global]\ninclude = %s\n' "$SAMBA_INCLUDE_FILE" >"$SAMBA_MAIN_CONF"
sudo() {
    [[ "$1" == grep ]] || return 0
    shift
    command grep "$@"
}
_ms_state_set() { RERUN_SETS+=("$1"); }
smbd() { :; }

# Given an owned Samba install with its include and effective-config hashes recorded
# When setup runs again with SMB on
# Then neither hash is written again, so shares the user adds later still read as theirs
_ms_state_get() {
    case "$1" in
        SAMBA_OWNERSHIP_RECORDED) echo true ;;
        SAMBA_INCLUDE_SHA256 | SAMBA_EFFECTIVE_SHA256) printf '%064d\n' 0 ;;
        *) echo false ;;
    esac
}
RERUN_SETS=()
SMB_ENABLED=true SMB_SHARE_SCOPE=data DATA_DIR=/data setup_samba >/dev/null 2>&1
assert_not_contains "${RERUN_SETS[*]}" "SAMBA_EFFECTIVE_SHA256" "setup_samba re-run: recorded effective-config hash is kept"
assert_not_contains "${RERUN_SETS[*]}" "SAMBA_INCLUDE_SHA256" "setup_samba re-run: recorded include hash is kept"

# Given the same install from before MediaStack recorded these hashes
# When setup runs again with SMB on
# Then both hashes are recorded
_ms_state_get() { [[ "$1" == SAMBA_OWNERSHIP_RECORDED ]] && echo true || echo false; }
RERUN_SETS=()
SMB_ENABLED=true SMB_SHARE_SCOPE=data DATA_DIR=/data setup_samba >/dev/null 2>&1
assert_contains "${RERUN_SETS[*]}" "SAMBA_EFFECTIVE_SHA256" "setup_samba re-run: a missing effective-config hash is backfilled"
assert_contains "${RERUN_SETS[*]}" "SAMBA_INCLUDE_SHA256" "setup_samba re-run: a missing include hash is backfilled"
unset -f sudo smbd
unset RERUN_SETS
eval "$RERUN_SAVED_FUNCS"

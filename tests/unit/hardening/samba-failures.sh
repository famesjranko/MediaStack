# Owns: setup_samba failure reporting tests (smbpasswd, services, and UFW).
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/samba.sh.

# ===========================================================================
# setup_samba — required failures must not end in a success line; nmbd is optional.
# ===========================================================================

FAIL_TMP=$(mktemp -d)
SAMBA_INCLUDE_FILE="$FAIL_TMP/mediastack.conf"
SAMBA_MAIN_CONF="$FAIL_TMP/smb.conf"
FAIL_SAVED_FUNCS=$(declare -f log_ok log_warn log_error _ms_state_get _ms_state_set ufw_installed)
# Fixtures consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="true"
# shellcheck disable=SC2034
JELLYFIN_ADMIN_USER="testadmin"
# shellcheck disable=SC2034
JELLYFIN_ADMIN_PASSWORD="testpass"
# shellcheck disable=SC2034
DATA_DIR="/data"
# shellcheck disable=SC2034
PGID="1000"
FAIL_SMBPASSWD_RC=0
FAIL_SMBD_RC=0
FAIL_NMBD_RC=0
FAIL_UFW_ALLOW_RC=0
FAIL_UFW_RELOAD_RC=0
FAIL_UFW_INSTALLED=true
sudo() {
    case "${1:-}" in
        grep)
            shift
            command grep "$@"
            return $?
            ;;
        install | tee)
            local cmd="$1"
            shift
            command "$cmd" "$@" >/dev/null
            return $?
            ;;
        smbpasswd)
            cat >/dev/null
            echo "Failed to open passdb" >&2
            return "$FAIL_SMBPASSWD_RC"
            ;;
        systemctl)
            [[ "$*" == "systemctl enable --now smbd" ]] && return "$FAIL_SMBD_RC"
            [[ "$*" == "systemctl enable --now nmbd" ]] && return "$FAIL_NMBD_RC"
            return 0
            ;;
        ufw)
            "$FAIL_UFW_INSTALLED" || {
                echo "ufw is not installed" >&2
                return 127
            }
            [[ "$*" == "ufw allow"* ]] && {
                echo "Could not add UFW rule" >&2
                return "$FAIL_UFW_ALLOW_RC"
            }
            [[ "$*" == "ufw reload" ]] && {
                echo "Could not reload UFW" >&2
                return "$FAIL_UFW_RELOAD_RC"
            }
            return 0
            ;;
        pdbedit) return 1 ;;
        *) return 0 ;;
    esac
}
smbd() { :; }
id() { [[ "${1:-}" == "-u" || "${1:-}" == "-g" ]] && echo 1000; }
getent() { [[ "${1:-}" == "group" ]] && echo "mediaadmin:x:1000:"; }
_ms_state_get() {
    [[ "$1" == "SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK" ]] && echo true || echo false
}
_ms_state_set() { FAIL_STATE_SETS+="$1=$2"$'\n'; }
ufw_installed() { "$FAIL_UFW_INSTALLED"; }
log_ok() { FAIL_LOG+="ok:$*"$'\n'; }
log_warn() { FAIL_LOG+="warn:$*"$'\n'; }
log_error() { FAIL_LOG+="error:$*"$'\n'; }
fail_fixture() {
    rm -f "$SAMBA_INCLUDE_FILE"
    printf '[global]\n   workgroup = HOMEUSER\n' >"$SAMBA_MAIN_CONF"
    FAIL_LOG=""
    FAIL_STATE_SETS=""
}

# Given a fresh setup where smbpasswd fails to create the Samba account
# When setup_samba runs
# Then it reports the tool's error, returns non-zero, and prints no success line
fail_fixture
FAIL_SMBPASSWD_RC=1
setup_samba
FAIL_RC=$?
FAIL_SMBPASSWD_RC=0
assert_eq "1" "$FAIL_RC" "setup_samba: smbpasswd failure returns non-zero"
assert_contains "$FAIL_LOG" "error:Could not create the Samba account" "setup_samba: smbpasswd failure is reported"
assert_contains "$FAIL_LOG" "Failed to open passdb" "setup_samba: smbpasswd failure shows the tool message"
assert_eq "no" "$([[ "$FAIL_LOG" == *"SMB share configured"* ]] && echo yes || echo no)" \
    "setup_samba: smbpasswd failure prints no success line"

# Given a fresh setup where smbd cannot be enabled and started
# When setup_samba runs
# Then it reports the error, returns non-zero, and prints no success line
fail_fixture
FAIL_SMBD_RC=1
setup_samba
FAIL_RC=$?
FAIL_SMBD_RC=0
assert_eq "1" "$FAIL_RC" "setup_samba: smbd start failure returns non-zero"
assert_contains "$FAIL_LOG" "error:Could not start smbd" "setup_samba: smbd start failure is reported"
assert_eq "no" "$([[ "$FAIL_LOG" == *"SMB share configured"* ]] && echo yes || echo no)" \
    "setup_samba: smbd start failure prints no success line"

# Given a fresh setup where optional nmbd cannot be enabled and started
# When setup_samba runs
# Then it warns with the journal command and still reports SMB success
fail_fixture
FAIL_NMBD_RC=1
setup_samba
FAIL_RC=$?
FAIL_NMBD_RC=0
assert_eq "0" "$FAIL_RC" "setup_samba: nmbd failure does not fail SMB setup"
assert_contains "$FAIL_LOG" "warn:Could not start nmbd" "setup_samba: nmbd failure is warned"
assert_contains "$FAIL_LOG" "journalctl -u nmbd" "setup_samba: nmbd warning gives the journal command"
assert_contains "$FAIL_LOG" "ok:SMB share configured" "setup_samba: nmbd failure still prints success"

# Given a fresh setup where adding the first SMB firewall rule fails
# When setup_samba runs
# Then it reports the CIDR and command, returns non-zero, and leaves setup pending
fail_fixture
FAIL_UFW_ALLOW_RC=1
setup_samba
FAIL_RC=$?
FAIL_UFW_ALLOW_RC=0
assert_eq "1" "$FAIL_RC" "setup_samba: UFW rule failure returns non-zero"
assert_contains "$FAIL_LOG" "error:Could not add SMB firewall rule for '10.0.0.0/8' with 'ufw allow'" \
    "setup_samba: UFW rule failure names the CIDR and command"
assert_eq "no" "$([[ "$FAIL_LOG" == *"SMB share configured"* ]] && echo yes || echo no)" \
    "setup_samba: UFW rule failure prints no success line"
assert_eq "no" "$([[ "$FAIL_STATE_SETS" == *"SAMBA_CONFIGURED=true"* ]] && echo yes || echo no)" \
    "setup_samba: UFW rule failure does not record configured"

# Given a fresh setup where reloading UFW fails after the SMB rules are added
# When setup_samba runs
# Then it reports the command, returns non-zero, and leaves setup pending
fail_fixture
FAIL_UFW_RELOAD_RC=1
setup_samba
FAIL_RC=$?
FAIL_UFW_RELOAD_RC=0
assert_eq "1" "$FAIL_RC" "setup_samba: UFW reload failure returns non-zero"
assert_contains "$FAIL_LOG" "error:Could not run 'ufw reload'" "setup_samba: UFW reload failure names the command"
assert_eq "no" "$([[ "$FAIL_LOG" == *"SMB share configured"* ]] && echo yes || echo no)" \
    "setup_samba: UFW reload failure prints no success line"
assert_eq "no" "$([[ "$FAIL_STATE_SETS" == *"SAMBA_CONFIGURED=true"* ]] && echo yes || echo no)" \
    "setup_samba: UFW reload failure does not record configured"

# Given a fresh setup where UFW is absent
# When setup_samba runs
# Then it tolerates missing UFW and reports success
fail_fixture
FAIL_UFW_INSTALLED=false
setup_samba
FAIL_RC=$?
FAIL_UFW_INSTALLED=true
assert_eq "0" "$FAIL_RC" "setup_samba: absent UFW does not fail setup"
assert_contains "$FAIL_LOG" "ok:SMB share configured" "setup_samba: absent UFW still prints success"

# Given the same fixture with every command succeeding
# When setup_samba runs
# Then it returns zero and prints the success line
fail_fixture
setup_samba
FAIL_RC=$?
assert_eq "0" "$FAIL_RC" "setup_samba: all commands succeeding returns zero"
assert_contains "$FAIL_LOG" "ok:SMB share configured" "setup_samba: success line printed when everything worked"

unset -f sudo smbd id getent fail_fixture
eval "$FAIL_SAVED_FUNCS"
rm -rf "$FAIL_TMP"

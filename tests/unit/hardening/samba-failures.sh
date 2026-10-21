# Owns: setup_samba failure reporting tests (smbpasswd and smbd start).
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/samba.sh.

# ===========================================================================
# setup_samba — a failed smbpasswd or smbd start must not end in a success line.
# Bug: both calls discarded stderr and the exit status, so "SMB share
# configured" printed while smbd was down or the account was never created.
# ===========================================================================

FAIL_TMP=$(mktemp -d)
SAMBA_INCLUDE_FILE="$FAIL_TMP/mediastack.conf"
SAMBA_MAIN_CONF="$FAIL_TMP/smb.conf"
FAIL_SAVED_FUNCS=$(declare -f log_ok log_error _ms_state_get _ms_state_set)
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
            return 0
            ;;
        pdbedit) return 1 ;;
        *) return 0 ;;
    esac
}
smbd() { :; }
id() { [[ "${1:-}" == "-u" || "${1:-}" == "-g" ]] && echo 1000; }
getent() { [[ "${1:-}" == "group" ]] && echo "mediaadmin:x:1000:"; }
_ms_state_get() { echo false; }
_ms_state_set() { :; }
log_ok() { FAIL_LOG+="ok:$*"$'\n'; }
log_error() { FAIL_LOG+="error:$*"$'\n'; }
fail_fixture() {
    rm -f "$SAMBA_INCLUDE_FILE"
    printf '[global]\n   workgroup = HOMEUSER\n' >"$SAMBA_MAIN_CONF"
    FAIL_LOG=""
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

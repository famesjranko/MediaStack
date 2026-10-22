# Owns: Secure Boot with a DKMS-signed module (enrolled MOK) on both NVIDIA routes.
# Sources: tests/unit/gpu-branching.sh setup, nvidia-driver.sh, nvidia-apt.sh, nvidia-install.sh.
# shellcheck disable=SC2034 # GPU_TYPE and STAGE3_FALLBACK_REASON are read by product code and asserts.
# Live enrolment needs the firmware MOK screen and is not covered here.

# Stubbed mokutil: MOK_ENROLLED (yes/no) answers --test-key; MOK_NEW holds the
# --list-new text. Output strings follow mokutil's real wording.
MOK_ENROLLED=no
MOK_NEW="MokNew is empty"
mokutil() {
    case "${1:-}" in
        --sb-state) echo "SecureBoot enabled" ;;
        --test-key)
            if [[ "$MOK_ENROLLED" == yes ]]; then
                echo "$2 is already enrolled"
            else
                echo "$2 is not enrolled"
                return 1
            fi
            ;;
        --list-new) echo "$MOK_NEW" ;;
    esac
}
# Later suites rely on the sudo stub left by earlier ones; put it back at the end.
_saved_sudo=$(declare -f sudo 2>/dev/null || true)
_mok_tmp=$(mktemp -d)
NVIDIA_DKMS_MOK_PUB="$_mok_tmp/mok.pub"

_mok_logs=()
_mok_calls=()
log_ok() { _mok_logs+=("$*"); }
log_warn() { _mok_logs+=("$*"); }
log_error() { _mok_logs+=("$*"); }
_mok_setup() { # $1 key (yes/no), $2 enrolled, $3 pending
    rm -f "$NVIDIA_DKMS_MOK_PUB"
    [[ "$1" == yes ]] && : >"$NVIDIA_DKMS_MOK_PUB"
    MOK_ENROLLED=$2
    MOK_NEW="MokNew is empty"
    [[ "$3" == yes ]] && MOK_NEW="[key 1] SHA1 Fingerprint: aa:bb"
    _mok_logs=()
    _mok_calls=()
    GPU_TYPE=nvidia
    STAGE3_FALLBACK_REASON=""
}
sudo() {
    if [[ "${1:-}" == mokutil ]]; then
        shift
        mokutil "$@"
        return
    fi
    _mok_calls+=("$*")
    return 0
}

# --- nvidia_driver_mok_state ---
_mok_setup no no no
assert_eq "no_key" "$(nvidia_driver_mok_state)" "mok_state: no DKMS key file"
_mok_setup yes yes no
assert_eq "enrolled" "$(nvidia_driver_mok_state)" "mok_state: key is enrolled"
_mok_setup yes no no
assert_eq "not_enrolled" "$(nvidia_driver_mok_state)" "mok_state: key exists, not enrolled, nothing queued"
_mok_setup yes no yes
assert_eq "pending" "$(nvidia_driver_mok_state)" "mok_state: key not enrolled, import queued"

# --- Debian DKMS route (install_nvidia_drivers_apt) ---
nvidia_driver_source() { printf 'none'; }
nvidia_driver_check_secure_boot() { printf 'enabled'; }
nvidia_driver_ensure_debian_nonfree() { return 0; }
_resolve_debian_nvidia_driver() { printf 'nvidia-driver'; }
_nvidia_apt_consider_backports() { :; }
_install_nvidia_container_toolkit() { return 0; }
_saved_dkms_fn=$(declare -f _nvidia_ensure_dkms_all_kernels)
_nvidia_ensure_dkms_all_kernels() { return 0; }
nvidia_driver_nouveau_is_active() { return 1; }
nvidia_driver_debian_codename() { printf 'bookworm'; }
dpkg-query() { return 1; }
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-18-amd64\n' || builtin uname "$@"; }
apt-cache() {
    [[ "${1:-}" == "madison" && "${2:-}" == "linux-headers-amd64" ]] \
        && printf ' linux-headers-amd64 | 6.1.0-18 | http://deb.debian.org/debian bookworm/main amd64 Packages\n'
    return 0
}
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }

# Given Secure Boot is on and the DKMS key is enrolled
# When the Debian route runs
# Then it installs the driver and logs that DKMS signs with the enrolled key
_mok_setup yes yes no
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "SB+enrolled apt route: proceeds"
assert_contains "${_mok_calls[*]}" "nvidia-driver" "SB+enrolled apt route: installs the driver"
assert_contains "${_mok_logs[*]}" "Secure Boot is on with an enrolled MOK" "SB+enrolled apt route: logs the enrolled MOK"
assert_contains "${_mok_logs[*]}" "nvidia-smi does not work yet under Secure Boot" "SB+enrolled apt route: warns when nvidia-smi cannot load the module"

# Given Secure Boot is on and the key exists but is not enrolled
# When the Debian route runs
# Then it refuses and lists the remaining steps, not the key-creation step
_mok_setup yes no no
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "SB+key not enrolled apt route: refused"
assert_eq "secure_boot" "$STAGE3_FALLBACK_REASON" "SB+key not enrolled apt route: records secure_boot"
assert_eq "none" "$GPU_TYPE" "SB+key not enrolled apt route: software transcoding"
assert_contains "${_mok_logs[*]}" "sudo mokutil --import /var/lib/dkms/mok.pub" "SB+key not enrolled apt route: shows the import step"
assert_not_contains "${_mok_logs[*]}" "openssl req" "SB+key not enrolled apt route: does not repeat key creation"
assert_eq "0" "${#_mok_calls[@]}" "SB+key not enrolled apt route: installs nothing"

# Given Secure Boot is on and a MOK import is queued
# When the Debian route runs
# Then it refuses and says to reboot and enrol
_mok_setup yes no yes
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "SB+pending apt route: refused"
assert_contains "${_mok_logs[*]}" "reboot; in the blue MOK screen" "SB+pending apt route: says reboot to enrol"
assert_not_contains "${_mok_logs[*]}" "mokutil --import" "SB+pending apt route: does not ask to import again"

# Given Secure Boot is on and no DKMS key exists
# When the Debian route runs
# Then it refuses with the full remedy including key creation
_mok_setup no no no
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "SB+no key apt route: refused"
assert_contains "${_mok_logs[*]}" "openssl req" "SB+no key apt route: shows key creation"
assert_contains "${_mok_logs[*]}" "Disable Secure Boot" "SB+no key apt route: offers disabling Secure Boot"

unset -f nvidia_driver_source nvidia_driver_ensure_debian_nonfree _resolve_debian_nvidia_driver _nvidia_apt_consider_backports \
    _install_nvidia_container_toolkit nvidia_driver_nouveau_is_active \
    nvidia_driver_debian_codename dpkg-query uname apt-cache command
eval "$_saved_dkms_fn"
unset _saved_dkms_fn

# --- Unlock (.run) route (install_nvidia_drivers) ---
# Given Secure Boot is on, whatever the DKMS key state
# When the Unlock route runs
# Then it refuses, because the .run installer does not use the DKMS key
nvidia_driver_healthy() { return 1; }
_run_state_cases=("no no no" "yes yes no" "yes no no" "yes no yes")
for _case in "${_run_state_cases[@]}"; do
    # shellcheck disable=SC2086
    _mok_setup $_case
    rc=0
    install_nvidia_drivers || rc=$?
    assert_eq "1" "$rc" "SB Unlock route (key/enrolled/pending: $_case): refused"
    assert_eq "secure_boot" "$STAGE3_FALLBACK_REASON" "SB Unlock route ($_case): records secure_boot"
    assert_contains "${_mok_logs[*]}" "Unlock (.run) driver cannot use the DKMS signing key" "SB Unlock route ($_case): gives the reason"
    assert_eq "0" "${#_mok_calls[@]}" "SB Unlock route ($_case): installs nothing"
done

unset -f nvidia_driver_check_secure_boot nvidia_driver_healthy mokutil sudo log_ok log_warn log_error
log_ok() { :; }
log_warn() { :; }
log_error() { :; }
rm -rf "$_mok_tmp"
[[ -n "$_saved_sudo" ]] && eval "$_saved_sudo"
unset _saved_sudo _mok_tmp _mok_logs _mok_calls _case _run_state_cases MOK_ENROLLED MOK_NEW NVIDIA_DKMS_MOK_PUB GPU_TYPE STAGE3_FALLBACK_REASON rc

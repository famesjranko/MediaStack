# Owns: Secure Boot with a DKMS-signed module (enrolled MOK) on both NVIDIA routes.
# Sources: tests/unit/gpu-branching.sh setup, nvidia-driver.sh, nvidia-apt.sh, nvidia-install.sh.
# shellcheck disable=SC2034 # GPU_TYPE and STAGE3_FALLBACK_REASON are read by product code and asserts.
# Live enrolment needs the firmware MOK screen and is not covered here.

# Stubbed mokutil: MOK_TRUST (mok/db/none) answers --test-key; MOK_NEW holds the
# --list-new text. Wording and exit codes follow mokutil 0.6.0/0.7.2 test_key:
# exit 1 when the key is already trusted, exit 0 when it can still be enrolled.
MOK_TRUST=none
MOK_NEW="MokNew is empty"
mokutil() {
    case "${1:-}" in
        --sb-state) echo "SecureBoot enabled" ;;
        --test-key)
            case "$MOK_TRUST" in
                mok) echo "$2 is already enrolled" ;;
                db) echo "$2 is already in db" ;;
                *)
                    echo "$2 is not enrolled"
                    return 0
                    ;;
            esac
            return 1
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
_mok_setup() { # $1 key (yes/no), $2 trust (mok/db/none), $3 pending (yes/no)
    rm -f "$NVIDIA_DKMS_MOK_PUB"
    [[ "$1" == yes ]] && : >"$NVIDIA_DKMS_MOK_PUB"
    MOK_TRUST=$2
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
_mok_setup no none no
assert_eq "no_key" "$(nvidia_driver_mok_state)" "mok_state: no DKMS key file"
_mok_setup yes mok no
assert_eq "enrolled" "$(nvidia_driver_mok_state)" "mok_state: key is enrolled as a MOK"
_mok_setup yes db no
assert_eq "enrolled" "$(nvidia_driver_mok_state)" "mok_state: key is in the firmware db"
_mok_setup yes none no
assert_eq "not_enrolled" "$(nvidia_driver_mok_state)" "mok_state: key exists, not enrolled, nothing queued"
_mok_setup yes none yes
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
_mok_setup yes mok no
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "0" "$rc" "SB+enrolled apt route: proceeds"
assert_contains "${_mok_calls[*]}" "nvidia-driver" "SB+enrolled apt route: installs the driver"
assert_contains "${_mok_logs[*]}" "the kernel trusts the DKMS key" "SB+enrolled apt route: logs the trusted key"
assert_contains "${_mok_logs[*]}" "nvidia-smi does not work yet under Secure Boot" "SB+enrolled apt route: warns when nvidia-smi cannot load the module"

# Given Secure Boot is on and the key exists but is not enrolled
# When the Debian route runs
# Then it refuses and lists the remaining steps, not the key-creation step
_mok_setup yes none no
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
_mok_setup yes none yes
rc=0
install_nvidia_drivers_apt || rc=$?
assert_eq "1" "$rc" "SB+pending apt route: refused"
assert_contains "${_mok_logs[*]}" "reboot; in the blue MOK screen" "SB+pending apt route: says reboot to enrol"
assert_not_contains "${_mok_logs[*]}" "mokutil --import" "SB+pending apt route: does not ask to import again"

# Given Secure Boot is on and no DKMS key exists
# When the Debian route runs
# Then it refuses with the full remedy including key creation
_mok_setup no none no
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
# The fresh path runs for real up to the installer; the stubs below replace the
# steps that touch the host. SCRIPT_DIR points at the temp dir so the resume
# cases never write .nvidia-tmp into the repository.
_saved_script_dir=$SCRIPT_DIR
SCRIPT_DIR=$_mok_tmp
_saved_unlock_fns=$(declare -f nvidia_driver_blacklist_nouveau nvidia_driver_try_unload_nouveau nvidia_driver_resolve_driver)
nvidia_driver_healthy() { return 1; }
nvidia_driver_blacklist_nouveau() { return 0; }
nvidia_driver_try_unload_nouveau() { return 0; }
nvidia_driver_nouveau_is_active() { return 1; }
# _nvidia_tmp is install_nvidia_drivers' local, which this stub sees.
# shellcheck disable=SC2154
nvidia_driver_resolve_driver() {
    _driver_ver=580.142
    _run_file="$_nvidia_tmp/NVIDIA-Linux-x86_64-580.142.run"
}
_install_nvidia_container_toolkit() { return 0; }
_mok_installer_call() { # Prints the recorded .run installer command, if any.
    local call
    for call in "${_mok_calls[@]}"; do
        [[ "$call" == "sh "*".run "* ]] && printf '%s' "$call"
    done
}
_mok_sign_args="--module-signing-secret-key=$_mok_tmp/mok.key --module-signing-public-key=$_mok_tmp/mok.pub"

# Given Secure Boot is on and the DKMS key is enrolled as a MOK
# When the Unlock route runs
# Then it runs the .run installer with the DKMS key as its signing key
_mok_setup yes mok no
rc=0
install_nvidia_drivers || rc=$?
assert_eq "0" "$rc" "SB+enrolled Unlock route: proceeds"
assert_contains "$(_mok_installer_call)" "--dkms" "SB+enrolled Unlock route: runs the .run installer"
assert_contains "$(_mok_installer_call)" "$_mok_sign_args" "SB+enrolled Unlock route: signs with the DKMS key"
assert_eq "" "$STAGE3_FALLBACK_REASON" "SB+enrolled Unlock route: records no fallback"

# Given Secure Boot is on and the DKMS key is in the firmware db
# When the Unlock route runs
# Then it signs with the DKMS key, because the kernel trusts db keys too
_mok_setup yes db no
rc=0
install_nvidia_drivers || rc=$?
assert_eq "0" "$rc" "SB+db key Unlock route: proceeds"
assert_contains "$(_mok_installer_call)" "$_mok_sign_args" "SB+db key Unlock route: signs with the DKMS key"

# Given Secure Boot is on and the DKMS key is not trusted (no key, not enrolled, or pending)
# When the Unlock route runs
# Then it refuses before it installs anything and shows the steps for that key state
_unlock_refusals=("no none no|openssl req" "yes none no|sudo mokutil --import" "yes none yes|reboot; in the blue MOK screen")
for _case in "${_unlock_refusals[@]}"; do
    # shellcheck disable=SC2086
    _mok_setup ${_case%%|*}
    rc=0
    install_nvidia_drivers || rc=$?
    assert_eq "1" "$rc" "SB Unlock route (key/trust/pending: ${_case%%|*}): refused"
    assert_eq "secure_boot" "$STAGE3_FALLBACK_REASON" "SB Unlock route (${_case%%|*}): records secure_boot"
    assert_eq "none" "$GPU_TYPE" "SB Unlock route (${_case%%|*}): software transcoding"
    assert_contains "${_mok_logs[*]}" "${_case#*|}" "SB Unlock route (${_case%%|*}): shows the remaining key steps"
    assert_not_contains "${_mok_calls[*]}" "linux-headers" "SB Unlock route (${_case%%|*}): installs no prerequisites"
    assert_eq "" "$(_mok_installer_call)" "SB Unlock route (${_case%%|*}): does not run the installer"
done

# Given a .run cached for a post-reboot install, and the DKMS key is no longer trusted
# When the Unlock route resumes after the reboot
# Then it refuses and does not run the cached installer
_mok_setup yes none no
mkdir -p "$_mok_tmp/.nvidia-tmp"
: >"$_mok_tmp/.nvidia-tmp/NVIDIA.run"
printf "_driver_ver='580.142'\n_run_file='%s'\n" "$_mok_tmp/.nvidia-tmp/NVIDIA.run" >"$_mok_tmp/.nvidia-tmp/pending"
rc=0
install_nvidia_drivers || rc=$?
assert_eq "1" "$rc" "SB resume, key not trusted: refused"
assert_eq "secure_boot" "$STAGE3_FALLBACK_REASON" "SB resume, key not trusted: records secure_boot"
assert_eq "" "$(_mok_installer_call)" "SB resume, key not trusted: does not run the cached installer"
assert_contains "${_mok_calls[*]}" "rm -rf $_mok_tmp/.nvidia-tmp" "SB resume, key not trusted: removes the cached installer"

# Given a .run cached for a post-reboot install, and the DKMS key is enrolled
# When the Unlock route resumes after the reboot
# Then it runs the cached installer with the DKMS key as its signing key
_mok_setup yes mok no
rc=0
install_nvidia_drivers || rc=$?
assert_eq "0" "$rc" "SB resume, key enrolled: proceeds"
assert_contains "$(_mok_installer_call)" "sh $_mok_tmp/.nvidia-tmp/NVIDIA.run" "SB resume, key enrolled: runs the cached installer"
assert_contains "$(_mok_installer_call)" "$_mok_sign_args" "SB resume, key enrolled: signs with the DKMS key"
rm -rf "$_mok_tmp/.nvidia-tmp"

# Given Secure Boot is off
# When the Unlock route runs
# Then the installer gets no signing options, so a host without the DKMS key still installs
nvidia_driver_check_secure_boot() { printf 'disabled'; }
_mok_setup no none no
rc=0
install_nvidia_drivers || rc=$?
assert_eq "0" "$rc" "SB off Unlock route: proceeds"
assert_contains "$(_mok_installer_call)" "--dkms" "SB off Unlock route: runs the .run installer"
assert_not_contains "$(_mok_installer_call)" "--module-signing" "SB off Unlock route: passes no signing options"

SCRIPT_DIR=$_saved_script_dir
unset -f nvidia_driver_nouveau_is_active _install_nvidia_container_toolkit _mok_installer_call
eval "$_saved_unlock_fns"
unset _saved_script_dir _saved_unlock_fns _mok_sign_args _unlock_refusals

unset -f nvidia_driver_check_secure_boot nvidia_driver_healthy mokutil sudo log_ok log_warn log_error
log_ok() { :; }
log_warn() { :; }
log_error() { :; }
rm -rf "$_mok_tmp"
[[ -n "$_saved_sudo" ]] && eval "$_saved_sudo"
unset _saved_sudo _mok_tmp _mok_logs _mok_calls _case MOK_TRUST MOK_NEW NVIDIA_DKMS_MOK_PUB GPU_TYPE STAGE3_FALLBACK_REASON rc

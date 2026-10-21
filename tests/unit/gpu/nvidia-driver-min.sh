# Owns: NVIDIA driver compatibility classes and Jellyfin's NVENC minimum-driver gate.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-driver.sh, nvidia-apt.sh.
# shellcheck disable=SC2034 # GPU_TYPE, STAGE3_FALLBACK_REASON are read by product code under test.
# The fixtures mirror NVIDIA's supportedchips.html (anchors "devidXXXX", a
# "Current NVIDIA GPUs" heading, "legacy_NNN.xx" anchors) and Debian's apt-cache
# madison layout. Log lines go to a file so assertions also see subshell output.

_LOGF=$(mktemp)
log_info() { printf 'info: %s\n' "$1" >>"$_LOGF"; }
log_ok() { printf 'ok: %s\n' "$1" >>"$_LOGF"; }
log_warn() { printf 'warn: %s\n' "$1" >>"$_LOGF"; }
log_error() { printf 'error: %s\n' "$1" >>"$_LOGF"; }
_logs() { cat "$_LOGF"; }
_logs_reset() { : >"$_LOGF"; }

# --- _nvidia_driver_check_compat: current / legacy / absent / unknown are distinct ---
_page_current=$'<h3>Current NVIDIA GPUs</h3>\n<tr id="devid1C03">\n<tr id="devid1B80">\n<p><a name="legacy_470.xx" id="legacy_470.xx"></a> The 470.xx\n<tr id="devid0FE4">\n'
_page_no_current_section=$'<h3>NVIDIA GeForce GPUs</h3>\n<tr id="devid1BB3">\n<td>Tesla P4</td>\n'

# Given a page that lists the GPU under "Current NVIDIA GPUs",
# When the compatibility check runs,
# Then the answer is "current".
curl() { printf '%s' "$_page_current"; }
assert_eq "current" "$(_nvidia_driver_check_compat 535.261.03 1c03)" \
    "_nvidia_driver_check_compat: GPU under Current NVIDIA GPUs → current"

# Given a page that lists the GPU under the 470.xx legacy anchor,
# When the compatibility check runs,
# Then the answer names the legacy branch.
assert_eq "legacy_470" "$(_nvidia_driver_check_compat 535.261.03 0fe4)" \
    "_nvidia_driver_check_compat: GPU under legacy_470 → legacy_470"

# Given a page with a Current section that does not list the GPU at all (Tesla P4 on 535),
# When the compatibility check runs,
# Then the answer is "absent", not "unknown".
assert_eq "absent" "$(_nvidia_driver_check_compat 535.261.03 1bb3)" \
    "_nvidia_driver_check_compat: GPU in no section of a classified page → absent"

# Given a page with no "Current NVIDIA GPUs" section that lists the GPU (470 README),
# When the compatibility check runs,
# Then the answer is "unknown": the listing cannot be classified.
curl() { printf '%s' "$_page_no_current_section"; }
assert_eq "unknown" "$(_nvidia_driver_check_compat 470.256.02 1bb3)" \
    "_nvidia_driver_check_compat: page without a Current section → unknown"

# Given the page cannot be fetched,
# When the compatibility check runs,
# Then the answer is "unknown" and the call still succeeds.
curl() { return 22; }
_compat_rc=0
_compat_out=$(_nvidia_driver_check_compat 535.261.03 1bb3) || _compat_rc=$?
assert_eq "unknown:0" "${_compat_out}:${_compat_rc}" \
    "_nvidia_driver_check_compat: fetch failure → unknown, rc 0"
unset -f curl
unset _page_current _page_no_current_section _compat_rc _compat_out

# --- _nvidia_driver_below_nvenc_min: the boundary is Jellyfin's minimum ---
# Given the minimum is 520.56.06,
# When versions around it are tested,
# Then only older ones are below it, and an unparseable version is never "below".
_below() { _nvidia_driver_below_nvenc_min "$1" && echo yes || echo no; }
assert_eq "no" "$(_below 520.56.06)" "_nvidia_driver_below_nvenc_min: the minimum itself is allowed"
assert_eq "yes" "$(_below 520.56.05)" "_nvidia_driver_below_nvenc_min: one patch below is too old"
assert_eq "yes" "$(_below 470.256.02-2)" "_nvidia_driver_below_nvenc_min: Debian 470 package version is too old"
assert_eq "yes" "$(_below 470)" "_nvidia_driver_below_nvenc_min: a bare 470 branch is too old"
assert_eq "no" "$(_below 1:535.261.03-1~deb12u1)" "_nvidia_driver_below_nvenc_min: epoch and revision are ignored; 535 passes"
assert_eq "no" "$(_below '')" "_nvidia_driver_below_nvenc_min: empty version is not 'too old'"
unset -f _below

# --- Shared stubs for the apt decision tests ---
APT_MADISON=""
# Compat answer per upstream driver version; unlisted versions answer "unknown".
declare -A COMPAT_BY_VERSION=()
# _set_compat VERSION ANSWER [VERSION ANSWER]...: replace the per-version answers.
_set_compat() {
    COMPAT_BY_VERSION=()
    while (($#)); do
        COMPAT_BY_VERSION["$1"]="$2"
        shift 2
    done
}
GPU_LSPCI=""
SUDO_LOG=()
BACKPORTS_ENABLED=0
nvidia_driver_debian_codename() { printf 'bookworm'; }
lspci() { printf '%s\n' "$GPU_LSPCI"; }
apt-cache() {
    [[ "${1:-}" == "madison" && "${2:-}" == "nvidia-driver" ]] && printf '%s' "$APT_MADISON"
    return 0
}
_nvidia_driver_check_compat() { printf '%s' "${COMPAT_BY_VERSION[${1:-}]:-unknown}"; }
nvidia_driver_ensure_debian_backports() {
    BACKPORTS_ENABLED=1
    return 0
}
sudo() {
    SUDO_LOG+=("$*")
    return 0
}
_madison_normal() { printf ' nvidia-driver | %s | http://deb.debian.org/debian bookworm/non-free amd64 Packages\n' "$1"; }
_madison_backports() { printf ' nvidia-driver | %s | http://deb.debian.org/debian bookworm-backports/non-free amd64 Packages\n' "$1"; }
GPU_GTX1060='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP106 [GeForce GTX 1060 3GB] [10de:1c02] (rev a1)'
GPU_P4='00:04.0 3D controller [0302]: NVIDIA Corporation GP104GL [Tesla P4] [10de:1bb3] (rev a1)'
GPU_GT750M='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GK107M [GeForce GT 750M] [10de:0fe4] (rev a1)'

# --- _nvidia_apt_consider_backports: each compat class has its own logged decision ---
# Given the normal driver lists the GPU as current,
# When the backports decision runs,
# Then backports stays off and the log says the driver lists the GPU.
APT_MADISON=$(_madison_normal 535.261.03-1)
GPU_LSPCI="$GPU_GTX1060"
_set_compat 535.261.03 current
BACKPORTS_ENABLED=0
_logs_reset
_nvidia_apt_consider_backports
assert_eq "0" "$BACKPORTS_ENABLED" "backports decision: current → backports stays off"
assert_contains "$(_logs)" "lists this GPU as current" "backports decision: current → the log names the reason"

# Given the supported-chips page cannot classify the GPU (unknown),
# When the backports decision runs,
# Then backports stays off and the log says it could not tell.
_set_compat 535.261.03 unknown
BACKPORTS_ENABLED=0
_logs_reset
_nvidia_apt_consider_backports
assert_eq "0" "$BACKPORTS_ENABLED" "backports decision: unknown → backports stays off (no spurious enable)"
assert_contains "$(_logs)" "Cannot tell" "backports decision: unknown → the log says it cannot tell"

# Given the GPU sits in a legacy branch or is absent from the current list,
# When the backports decision runs,
# Then backports is enabled and apt is refreshed.
for _c in legacy_470 absent; do
    _set_compat 535.261.03 "$_c"
    BACKPORTS_ENABLED=0
    SUDO_LOG=()
    _logs_reset
    _nvidia_apt_consider_backports
    assert_eq "1" "$BACKPORTS_ENABLED" "backports decision: ${_c} → backports enabled"
    assert_contains "${SUDO_LOG[*]}" "apt-get update" "backports decision: ${_c} → apt refreshed"
    assert_contains "$(_logs)" "checking bookworm-backports" "backports decision: ${_c} → the log says why"
done
unset _c

# --- _resolve_debian_nvidia_driver: unknown never escalates, evidence does ---
# Given the normal compat is unknown while backports has a newer driver that lists the GPU,
# When the driver is resolved,
# Then the normal driver stays: no evidence the normal one is wrong.
APT_MADISON="$(
    _madison_normal 535.261.03-1
    _madison_backports 550.163.01-1~bpo12+1
)"
_set_compat 535.261.03 unknown 550.163.01 current
assert_eq "nvidia-driver firmware-misc-nonfree" "$(_resolve_debian_nvidia_driver 2>/dev/null)" \
    "_resolve_debian_nvidia_driver: unknown compat keeps the normal driver"

# Given a normal driver older than Jellyfin's NVENC minimum and a newer backports branch that lists the GPU,
# When the driver is resolved,
# Then the backports branch is chosen.
APT_MADISON="$(
    _madison_normal 470.256.02-2
    _madison_backports 535.183.01-1~bpo12+1
)"
GPU_LSPCI="$GPU_GTX1060"
_set_compat 470.256.02 unknown 535.183.01 current
_resolve_rc=0
_resolve_out=$(_resolve_debian_nvidia_driver 2>/dev/null) || _resolve_rc=$?
assert_eq "-t bookworm-backports nvidia-driver firmware-misc-nonfree:0" "${_resolve_out}:${_resolve_rc}" \
    "_resolve_debian_nvidia_driver: driver below the NVENC minimum + supporting backports → backports"

# Given a Kepler GT 750M whose newest supported branch is 470 (legacy) and no better backports driver,
# When the driver is resolved,
# Then it refuses with rc 3 and the log names the GPU, the 470 branch and the minimum.
APT_MADISON="$(
    _madison_normal 535.261.03-1
    _madison_backports 550.163.01-1~bpo12+1
)"
GPU_LSPCI="$GPU_GT750M"
_set_compat 535.261.03 legacy_470 550.163.01 legacy_470
_logs_reset
_resolve_rc=0
_resolve_debian_nvidia_driver >/dev/null 2>&1 || _resolve_rc=$?
assert_eq "3" "$_resolve_rc" "_resolve_debian_nvidia_driver: Kepler (max branch 470) → rc 3 (driver too old)"
assert_contains "$(_logs)" "GeForce GT 750M" "driver too old: the message names the GPU"
assert_contains "$(_logs)" "470.xx driver branch" "driver too old: the message names the 470 branch"
assert_contains "$(_logs)" "520.56.06" "driver too old: the message names Jellyfin's minimum"

# Given a Tesla P4 that driver 535 does not list (datacenter parts are omitted) and no backports,
# When the driver is resolved,
# Then driver 535 proceeds: absent is not proof the GPU is unsupported.
APT_MADISON=$(_madison_normal 535.261.03-1)
GPU_LSPCI="$GPU_P4"
_set_compat 535.261.03 absent
_resolve_rc=0
_resolve_out=$(_resolve_debian_nvidia_driver 2>/dev/null) || _resolve_rc=$?
assert_eq "nvidia-driver firmware-misc-nonfree:0" "${_resolve_out}:${_resolve_rc}" \
    "_resolve_debian_nvidia_driver: driver 535 (above the minimum) proceeds"

# Given only a driver below the minimum is available and nothing newer exists,
# When the driver is resolved,
# Then it refuses with rc 3 and the message names the driver version found.
APT_MADISON=$(_madison_normal 470.256.02-2)
GPU_LSPCI="$GPU_P4"
_set_compat 470.256.02 unknown
_logs_reset
_resolve_rc=0
_resolve_debian_nvidia_driver >/dev/null 2>&1 || _resolve_rc=$?
assert_eq "3" "$_resolve_rc" "_resolve_debian_nvidia_driver: only 470 available → rc 3"
assert_contains "$(_logs)" "470.256.02" "driver too old: the message names the driver found"

# --- install_nvidia_drivers_apt: a too-old driver means software fallback, no apt install ---
# Given the Kepler GT 750M and a Debian whose only drivers cannot run NVENC for it,
# When the Standard apt install runs,
# Then it falls back with reason driver_too_old and installs no driver package.
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
uname() { [[ "${1:-}" == "-r" ]] && printf '6.1.0-18-amd64\n' || builtin uname "$@"; }
nvidia_driver_check_secure_boot() { printf 'disabled'; }
nvidia_driver_ensure_debian_nonfree() { return 0; }
_nvidia_preflight_kernel_headers() { return 0; }
APT_MADISON="$(
    _madison_normal 535.261.03-1
    _madison_backports 550.163.01-1~bpo12+1
)"
GPU_LSPCI="$GPU_GT750M"
_set_compat 535.261.03 legacy_470 550.163.01 legacy_470
SUDO_LOG=()
GPU_TYPE=nvidia
STAGE3_FALLBACK_REASON=""
_logs_reset
_install_rc=0
install_nvidia_drivers_apt >/dev/null 2>&1 || _install_rc=$?
assert_eq "1" "$_install_rc" "install_nvidia_drivers_apt: Kepler → returns 1 (caller falls back)"
assert_eq "none" "$GPU_TYPE" "install_nvidia_drivers_apt: Kepler → GPU_TYPE none"
assert_eq "driver_too_old" "$STAGE3_FALLBACK_REASON" "install_nvidia_drivers_apt: Kepler → reason driver_too_old"
assert_not_contains "${SUDO_LOG[*]}" "apt-get install" "install_nvidia_drivers_apt: Kepler → no driver package installed"
assert_not_contains "$(_logs)" "NVENC configured" "install_nvidia_drivers_apt: Kepler → never claims NVENC"
unset -f command dpkg-query uname nvidia_driver_check_secure_boot nvidia_driver_ensure_debian_nonfree _nvidia_preflight_kernel_headers

# --- nvidia_driver_resolve_driver (Unlock .run route): same gate before the download ---
# Given the latest patchable driver is 580.142, the Kepler GT 750M is legacy_470, and the patch README has a 470 build,
# When the .run driver is resolved,
# Then it stops with driver_too_old before downloading anything.
_nvidia_tmp="$(mktemp -d)"
RUN_CURL_CALLS=()
lspci() { printf '%s\n' "$GPU_LSPCI"; }
nvidia_patch_readme_url() { printf 'https://example.invalid/readme'; }
curl() {
    RUN_CURL_CALLS+=("$*")
    case " $* " in
        *example.invalid/readme*)
            printf '%s\n' '| 470.256.02 | Linux x86_64 | YES | [driver](https://download.nvidia.com/XFree86/Linux-x86_64/470.256.02/NVIDIA-Linux-x86_64-470.256.02.run) |'
            printf '%s\n' '| 580.142 | Linux x86_64 | YES | [driver](https://download.nvidia.com/XFree86/Linux-x86_64/580.142/NVIDIA-Linux-x86_64-580.142.run) |'
            ;;
        *" -o "*)
            # The driver download: create the file named after -o.
            local _a _next=0
            for _a in "$@"; do
                ((_next)) && : >"$_a"
                _next=0
                [[ "$_a" == "-o" ]] && _next=1
            done
            ;;
    esac
    return 0
}
GPU_LSPCI="$GPU_GT750M"
_set_compat 580.142 legacy_470
STAGE3_FALLBACK_REASON=""
_driver_ver=""
_run_file=""
_logs_reset
_run_rc=0
nvidia_driver_resolve_driver >/dev/null 2>&1 || _run_rc=$?
assert_eq "1" "$_run_rc" "nvidia_driver_resolve_driver: legacy 470 driver is below the NVENC minimum → rc 1"
assert_eq "driver_too_old" "$STAGE3_FALLBACK_REASON" "nvidia_driver_resolve_driver: reason driver_too_old"
assert_contains "$(_logs)" "470.xx driver branch" "nvidia_driver_resolve_driver: the message names the 470 branch"
assert_not_contains "${RUN_CURL_CALLS[*]}" " -o " "nvidia_driver_resolve_driver: nothing is downloaded"

# Given a current GPU and the same README,
# When the .run driver is resolved,
# Then driver 580.142 is downloaded.
GPU_LSPCI="$GPU_GTX1060"
_set_compat 580.142 current
STAGE3_FALLBACK_REASON=""
RUN_CURL_CALLS=()
_run_rc=0
nvidia_driver_resolve_driver >/dev/null 2>&1 || _run_rc=$?
assert_eq "0:580.142" "${_run_rc}:${_driver_ver}" "nvidia_driver_resolve_driver: current GPU proceeds with 580.142"
assert_eq "" "$STAGE3_FALLBACK_REASON" "nvidia_driver_resolve_driver: current GPU records no fallback reason"
rm -rf "$_nvidia_tmp"
unset -f curl nvidia_patch_readme_url
unset _nvidia_tmp _driver_ver _run_file _run_rc RUN_CURL_CALLS

# --- _stage3_nvidia_use_driver: an installed driver below the minimum falls back ---
# Given an installed driver 470.256.02 on the Kepler GT 750M,
# When "use installed driver" runs,
# Then setup falls back with driver_too_old and never installs the container toolkit.
nvidia_driver_version() { printf '%s' "$INSTALLED_DRIVER"; }
TOOLKIT_CALLS=0
FALLBACK_ARGS=()
_install_nvidia_container_toolkit() {
    TOOLKIT_CALLS=$((TOOLKIT_CALLS + 1))
    return 0
}
_stage3_fallback() {
    FALLBACK_ARGS+=("$*|${STAGE3_FALLBACK_REASON:-}")
    return 0
}
verify_gpu_usable() { return 0; }
_stage3_configure_and_verify() { return 0; }
GPU_LSPCI="$GPU_GT750M"
INSTALLED_DRIVER="470.256.02"
_logs_reset
_stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified." >/dev/null 2>&1
assert_eq "nvidia nvenc driver_too_old|driver_too_old" "${FALLBACK_ARGS[*]}" "use installed driver: 470 → software fallback driver_too_old"
assert_eq "0" "$TOOLKIT_CALLS" "use installed driver: 470 → toolkit not installed"
assert_contains "$(_logs)" "520.56.06" "use installed driver: 470 → the message names the minimum"

# Given an installed driver 535.261.03,
# When "use installed driver" runs,
# Then the flow proceeds to the toolkit and does not fall back.
INSTALLED_DRIVER="535.261.03"
TOOLKIT_CALLS=0
FALLBACK_ARGS=()
GPU_TYPE=nvidia
STAGE3_FALLBACK_REASON=""
_stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified." >/dev/null 2>&1
assert_eq "1:0" "${TOOLKIT_CALLS}:${#FALLBACK_ARGS[@]}" "use installed driver: 535 → toolkit installed, no fallback"
unset -f nvidia_driver_version _install_nvidia_container_toolkit _stage3_fallback verify_gpu_usable _stage3_configure_and_verify
unset TOOLKIT_CALLS FALLBACK_ARGS INSTALLED_DRIVER

# --- Restore the suite's shared state ---
rm -f "$_LOGF"
unset -f _set_compat log_info log_ok log_warn log_error _logs _logs_reset lspci apt-cache _nvidia_driver_check_compat \
    nvidia_driver_ensure_debian_backports nvidia_driver_debian_codename sudo _madison_normal _madison_backports
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
unset APT_MADISON COMPAT_BY_VERSION GPU_LSPCI SUDO_LOG BACKPORTS_ENABLED _LOGF
unset GPU_GTX1060 GPU_P4 GPU_GT750M _resolve_rc _resolve_out _install_rc STAGE3_FALLBACK_REASON
# The stubs above replaced real gpu.sh helpers (mock + real share one function slot).
# shellcheck source=../../scripts/setup/gpu.sh
source "$REPO_ROOT/scripts/setup/gpu.sh"

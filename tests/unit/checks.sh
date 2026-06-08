#!/usr/bin/env bash
# tests/unit/checks.sh
#
# Pure-bash unit tests for the PRE-* checks in scripts/setup/checks.sh.
# Shims df, stat, grep, awk as in-shell functions per the gpu-branching.sh
# pattern. Hard-fail (exit 1) paths are captured in a subshell:
#   ( check_x ); rc=$?
# No DinD, no Docker, no network. The host's actual disk/RAM are not touched —
# every probe used by the checks under test is shimmed before invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="checks"
echo -e "${CYAN}${BOLD}▶ scenario: checks${NC}"

# Source setup.sh for the helper functions. The guard at setup.sh:206-208
# ensures main() does not run under `source`.
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# setup.sh sets -euo pipefail; relax so asserts can run a full pass/fail.
set +e
set +u

# Silence log_* output — the test drives its own assertions.
log_ok()    { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
log_skip()  { :; }

# ---------------------------------------------------------------------------
# _resolve_data_partition — walk-up via temp .env
# ---------------------------------------------------------------------------

# Test 7: missing DATA_DIR path walks up via dirname loop.
# The temp .env points DATA_DIR at a $$-salted path that cannot exist on the
# host filesystem; walk-up should land at "/" (the loop's terminating ancestor).
_tmpdir=$(mktemp -d)
printf 'DATA_DIR=/nonexistent-walkup-test-%d/deeper/path\n' "$$" > "$_tmpdir/.env"
_orig_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$_tmpdir"
out=$(_resolve_data_partition)
SCRIPT_DIR="$_orig_script_dir"
rm -rf "$_tmpdir"
assert_eq "/" "$out" "_resolve_data_partition: missing path walks up to /"

# ---------------------------------------------------------------------------
# check_disk_floor — hard-fail and single-FS branches
# ---------------------------------------------------------------------------

# Disk-floor tests below assert on the warn message text, so they need
# log_warn to actually emit. The file-wide silence stub at top of file
# stays in place; we re-enable per-test then restore.
_silent_log_warn() { :; }
_visible_log_warn() { echo "[WARN] $1"; }

# Test 4: root <10 GB on a two-FS host → warn-and-continue (return 0 with warn message)
# Disk floors are recommended minimums, not hard gates — see check_disk_floor comment.
df() {
    case "$*" in
        *"-BG /")     printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 95G 5G 95%% /\n' ;;
        *"-BG /data") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sdb1 500G 100G 400G 25%% /data\n' ;;
        *)            printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 95G 5G 95%% /\n' ;;
    esac
}
stat() {
    # two-FS mode: / and /data on different mountpoints
    case "$*" in
        *"-c %m /")     echo "/" ;;
        *"-c %m /data") echo "/data" ;;
        *"-c %m"*)      echo "/" ;;
        *) builtin stat "$@" ;;
    esac
}
# Force _resolve_data_partition to return /data without touching .env or FS:
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$( check_disk_floor 2>&1 ); rc=$?
log_warn() { _silent_log_warn "$@"; }
assert_eq "0" "$rc" "check_disk_floor: root 5GB → return 0 (warn, never exit)"
assert_contains "$out" "10GB" "check_disk_floor: root 5GB → warn message names 10GB minimum"
unset -f df stat _resolve_data_partition

# Test 5: data <30 GB on a two-FS host → warn-and-continue (return 0 with warn message)
df() {
    case "$*" in
        *"-BG /")     printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 50G 50G 50%% /\n' ;;
        *"-BG /data") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sdb1 500G 480G 20G 96%% /data\n' ;;
        *)            printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 50G 50G 50%% /\n' ;;
    esac
}
stat() {
    case "$*" in
        *"-c %m /")     echo "/" ;;
        *"-c %m /data") echo "/data" ;;
        *) echo "/" ;;
    esac
}
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$( check_disk_floor 2>&1 ); rc=$?
log_warn() { _silent_log_warn "$@"; }
assert_eq "0" "$rc" "check_disk_floor: data 20GB → return 0 (warn, never exit)"
assert_contains "$out" "30GB" "check_disk_floor: data 20GB → warn message names 30GB minimum"
unset -f df stat _resolve_data_partition

# Test 6: single-FS mode — stat -c %m identical for both paths → one combined
# check at 30 GB floor; 50GB free passes (no second probe; no combined warn).
df() {
    case "$*" in
        *"-BG"*) printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 50G 50G 50%% /\n' ;;
    esac
}
stat() { echo "/" ; }
_resolve_data_partition() { echo "/data"; }
( check_disk_floor ); rc=$?
assert_eq "0" "$rc" "check_disk_floor: single-FS 50GB → ok (no double check)"
unset -f df stat _resolve_data_partition

# Bonus single-FS guard: same mountpoint but only 20 GB free → warn-and-continue
# at the recommended 30 GB minimum (D-08 reference floor, not a hard gate).
df() {
    case "$*" in
        *"-BG"*) printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 80G 20G 80%% /\n' ;;
    esac
}
stat() { echo "/" ; }
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$( check_disk_floor 2>&1 ); rc=$?
log_warn() { _silent_log_warn "$@"; }
assert_eq "0" "$rc" "check_disk_floor: single-FS 20GB → return 0 (warn at 30GB recommended)"
assert_contains "$out" "30GB" "check_disk_floor: single-FS 20GB → warn message names 30GB minimum"
unset -f df stat _resolve_data_partition

# ---------------------------------------------------------------------------
# check_ram_warn — soft warn, never hard fails
# ---------------------------------------------------------------------------

# Test 1: 1 GB free → soft warn, return 0 (must NOT exit 1)
grep() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        return 0
    fi
    builtin grep "$@" 2>/dev/null
}
awk() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        echo "1"
        return 0
    fi
    builtin awk "$@"
}
( check_ram_warn ); rc=$?
assert_eq "0" "$rc" "check_ram_warn: 1GB → returns 0 (warn, never exit)"
unset -f grep awk

# Test 2: 8 GB free → ok, return 0
grep() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        return 0
    fi
    builtin grep "$@" 2>/dev/null
}
awk() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        echo "8"
        return 0
    fi
    builtin awk "$@"
}
( check_ram_warn ); rc=$?
assert_eq "0" "$rc" "check_ram_warn: 8GB → ok"
unset -f grep awk

# Test 3: MemAvailable absent → graceful skip, return 0
grep() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        return 1
    fi
    builtin grep "$@" 2>/dev/null
}
( check_ram_warn ); rc=$?
assert_eq "0" "$rc" "check_ram_warn: MemAvailable absent → graceful skip, return 0"
unset -f grep

# ---------------------------------------------------------------------------
# stash_gpu_type (PRE-07)
# ---------------------------------------------------------------------------
# Wraps the existing detect_gpu (gpu.sh:9-31). We shim lspci with the same
# pattern as tests/unit/gpu-branching.sh so detect_gpu's grep cascade resolves
# the expected GPU_TYPE without touching real PCI hardware.

# Test: stash_gpu_type — nvidia path
lspci() { printf '01:00.0 VGA compatible controller: NVIDIA Corporation GA104\n'; }
GPU_TYPE=""; stash_gpu_type
assert_eq "nvidia" "$GPU_TYPE" "stash_gpu_type: nvidia via lspci"
unset -f lspci

# Test: stash_gpu_type — intel path
lspci() { printf '00:02.0 VGA compatible controller: Intel Corporation UHD Graphics\n'; }
GPU_TYPE=""; stash_gpu_type
assert_eq "intel" "$GPU_TYPE" "stash_gpu_type: intel via lspci"
unset -f lspci

# Test: stash_gpu_type — lspci missing → none, no exit
# Subshell capture proves the wrapper does not call exit 1; a second call
# without subshell verifies the resulting GPU_TYPE in the parent shell
# (subshell mutation of GPU_TYPE is lost on return).
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "lspci" ]]; then
        return 1
    fi
    builtin command "$@"
}
GPU_TYPE=""
( stash_gpu_type ); rc=$?
assert_eq "0" "$rc" "stash_gpu_type: lspci missing → returns 0 (no exit 1)"
GPU_TYPE=""; stash_gpu_type
assert_eq "none" "$GPU_TYPE" "stash_gpu_type: lspci missing → GPU_TYPE=none"
unset -f command

# ---------------------------------------------------------------------------
# check_internet_reachability (PRE-03)
# ---------------------------------------------------------------------------
# curl is shimmed entirely (no real network calls). The function delegates
# message text through log_error, which is silenced at the top of this
# scenario; for the message-content assertion we re-enable log_error/log_warn
# temporarily, then re-silence.

# Test: curl missing during --full → skip/defer instead of failing before
# install_base_packages has had a chance to install curl.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "curl" ]]; then
        return 1
    fi
    builtin command "$@"
}
curl() { return 127; }
log_warn() { echo "[WARN] $1"; }
FULL_MODE=true
out=$( check_internet_reachability 2>&1 ); rc=$?
FULL_MODE=false
log_warn() { :; }
assert_eq "0" "$rc" "check_internet_reachability: curl missing in --full → defer"
assert_contains "$out" "curl is not installed yet" "check_internet_reachability: curl missing in --full → message explains deferral"
unset -f command curl

# Test: hub.docker.com fails (resolve error 6) → exit 1
curl() { return 6; }
( check_internet_reachability 2>&1 ); rc=$?
assert_eq "1" "$rc" "check_internet_reachability: hub fails → exit 1"
unset -f curl

# Test: hub succeeds, ACME fails (timeout 28) → warn and continue, because
# Stage 1 LAN setup does not require Let's Encrypt. Stage 2 classifies the
# real certificate attempt.
log_warn() { echo "[WARN] $1"; }

_CURL_CALL=0
curl() {
    _CURL_CALL=$((_CURL_CALL + 1))
    if (( _CURL_CALL == 1 )); then return 0; fi
    return 28
}
out=$( check_internet_reachability 2>&1 ); rc=$?
assert_eq "0" "$rc" "check_internet_reachability: ACME fails → warn and continue"
assert_contains "$out" "Let's Encrypt unreachable" "check_internet_reachability: warning names Let's Encrypt"
assert_contains "$out" "(28)" "check_internet_reachability: message contains curl exit code 28"

# Re-silence log_warn for downstream tests.
log_warn() { :; }
unset -f curl
unset _CURL_CALL

# Test: both probes succeed → return 0 (no exit)
curl() { return 0; }
( check_internet_reachability ); rc=$?
assert_eq "0" "$rc" "check_internet_reachability: both succeed → return 0"
unset -f curl

# ---------------------------------------------------------------------------
# prompt_sudo_cache (PRE-04)
# ---------------------------------------------------------------------------
# Shim sudo entirely. The `command -v sudo` absence path uses Pattern O
# (override of the `command` builtin) — same idiom as gpu-branching.sh:83-91.

# Test: sudo not installed → exit 1
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "sudo" ]]; then
        return 1
    fi
    builtin command "$@"
}
( prompt_sudo_cache ); rc=$?
assert_eq "1" "$rc" "prompt_sudo_cache: sudo absent → exit 1"
unset -f command

# Test: passwordless sudo (sudo -n true returns 0)
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 0; fi
    return 0
}
( prompt_sudo_cache ); rc=$?
assert_eq "0" "$rc" "prompt_sudo_cache: passwordless → return 0"
unset -f sudo

# Test: sudo -n true fails, sudo -v succeeds (cached path)
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 1; fi
    # sudo -p "..." -v
    if [[ "$1" == "-p" ]]; then return 0; fi
    return 0
}
( prompt_sudo_cache ); rc=$?
assert_eq "0" "$rc" "prompt_sudo_cache: sudo -v cached → return 0"
unset -f sudo

# Test: sudo -n true fails AND sudo -v fails → exit 1
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 1; fi
    return 1
}
( prompt_sudo_cache ); rc=$?
assert_eq "1" "$rc" "prompt_sudo_cache: sudo -v fails → exit 1"
unset -f sudo

# ---------------------------------------------------------------------------
# detect_existing_install (PRE-05)
# ---------------------------------------------------------------------------
# Each scenario uses a tempdir as a synthetic SCRIPT_DIR so the real host's
# .env / config tree is never read. ui_choose, docker, and timeout are all
# shimmed; the real ones are never invoked. Hard-exit branches are captured
# in subshells (Pattern P).

_orig_script_dir="$SCRIPT_DIR"

# Sentinel-file convention used in this section: ui_choose runs inside
# `choice=$(ui_choose ...)` (command-substitution subshell), so variable
# mutations from a ui_choose shim are lost on return. We use a sentinel
# file instead — touched inside the shim, checked from the parent shell.

# Test 1: .env absent → returns 0 (CR-01 contract), no ui_choose call,
# EXISTING_INSTALL_DETECTED=false
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() { : > "$_ui_sentinel"; echo "Abort"; }
docker() { :; }   # never called in this branch
unset EXISTING_INSTALL_DETECTED
detect_existing_install; rc=$?
assert_eq "0" "$rc" "detect_existing_install: .env absent → returns 0 (CR-01: no-install path is rc=0)"
[[ ! -f "$_ui_sentinel" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
ui_not_called=$?
assert_eq "0" "$ui_not_called" "detect_existing_install: .env absent → ui_choose NOT called"
assert_eq "false" "$EXISTING_INSTALL_DETECTED" "detect_existing_install: .env absent → EXISTING_INSTALL_DETECTED=false"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker
unset _ui_sentinel ui_not_called EXISTING_INSTALL_DETECTED

# Test 2: .env empty (zero-byte) → returns 0 (CR-01)
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: > "$_tmpdir/.env"   # zero-byte file
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() { : > "$_ui_sentinel"; echo "Abort"; }
docker() { :; }
unset EXISTING_INSTALL_DETECTED
detect_existing_install; rc=$?
assert_eq "0" "$rc" "detect_existing_install: .env empty → returns 0 (CR-01)"
[[ ! -f "$_ui_sentinel" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
ui_not_called=$?
assert_eq "0" "$ui_not_called" "detect_existing_install: .env empty → ui_choose NOT called"
assert_eq "false" "$EXISTING_INSTALL_DETECTED" "detect_existing_install: .env empty → EXISTING_INSTALL_DETECTED=false"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker
unset EXISTING_INSTALL_DETECTED
unset _ui_sentinel ui_not_called

# Test 2b: .env non-empty but STAGE_1_COMPLETE empty → returns 0 and does
# not show the existing-install menu, even when install evidence exists.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() { : > "$_ui_sentinel"; echo "Use existing install"; }
docker() { :; }
unset EXISTING_INSTALL_DETECTED
detect_existing_install; rc=$?
assert_eq "0" "$rc" "detect_existing_install: incomplete Stage 1 evidence → returns 0"
[[ ! -f "$_ui_sentinel" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
ui_not_called=$?
assert_eq "0" "$ui_not_called" "detect_existing_install: incomplete Stage 1 evidence → ui_choose NOT called"
assert_eq "false" "$EXISTING_INSTALL_DETECTED" "detect_existing_install: incomplete Stage 1 evidence → EXISTING_INSTALL_DETECTED=false"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker
unset EXISTING_INSTALL_DETECTED
unset _ui_sentinel ui_not_called

# Test 3: .env non-empty + ddns config exists + ui_choose returns "Use existing install"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() { RECOVERY_MENU_ACTION="continue"; return 0; }
EXISTING_INSTALL_DETECTED=""
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: ddns config + Use existing → return 0"
assert_eq "true" "$EXISTING_INSTALL_DETECTED" "detect_existing_install: Use existing → EXISTING_INSTALL_DETECTED=true"
assert_eq "continue" "$RECOVERY_MENU_ACTION" "detect_existing_install: Use existing → delegates to recovery menu"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker show_existing_install_menu
unset EXISTING_INSTALL_DETECTED RECOVERY_MENU_ACTION

# Test 4: ui_choose returns "Abort" → exit 0 (subshell-captured)
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Abort"; }
docker() { :; }
( detect_existing_install ); rc=$?
assert_eq "0" "$rc" "detect_existing_install: Abort → exit 0 (NOT exit 1)"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker

# Test 6: .env non-empty + no ddns config + docker ps returns container ID → ui_choose called
# Sentinel-file trick: ui_choose runs inside `choice=$(ui_choose ...)` (a
# command-substitution subshell), so any variable mutation it performs is
# lost on return. We touch a sentinel file instead, then check the file
# in the parent shell.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
# NO ddns config in this scenario.
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
timeout() {
    # Bypass the timeout wrapper; pass through to docker shim.
    shift   # discard the timeout duration arg
    "$@"
}
docker() {
    if [[ "${1:-}" == "ps" ]]; then
        printf 'abc123\n'
    fi
}
ui_choose() { : > "$_ui_sentinel"; echo "Use existing install"; }
show_existing_install_menu() { RECOVERY_MENU_ACTION="continue"; return 0; }
EXISTING_INSTALL_DETECTED=""
detect_existing_install
rc=$?
[[ -f "$_ui_sentinel" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
ui_was_called=$?
assert_eq "0" "$ui_was_called" "detect_existing_install: jellyfin container → ui_choose called"
assert_eq "0" "$rc" "detect_existing_install: jellyfin container + Use existing → return 0"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker timeout show_existing_install_menu
unset _ui_sentinel ui_was_called EXISTING_INSTALL_DETECTED RECOVERY_MENU_ACTION

# Test 7: .env non-empty + no ddns config + docker ps returns empty → returns 0 (CR-01)
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
timeout() { shift; "$@"; }
docker() { :; }   # ps returns empty
ui_choose() { : > "$_ui_sentinel"; echo "Abort"; }
unset EXISTING_INSTALL_DETECTED
detect_existing_install; rc=$?
assert_eq "0" "$rc" "detect_existing_install: no ddns + no jellyfin → returns 0 (CR-01)"
[[ ! -f "$_ui_sentinel" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
ui_not_called=$?
assert_eq "0" "$ui_not_called" "detect_existing_install: no ddns + no jellyfin → ui_choose NOT called"
assert_eq "false" "$EXISTING_INSTALL_DETECTED" "detect_existing_install: no ddns + no jellyfin → EXISTING_INSTALL_DETECTED=false"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker timeout
unset _ui_sentinel ui_not_called EXISTING_INSTALL_DETECTED

# Test 8: Use existing + recovery menu wipe action delegates to nuke_existing_install.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() { RECOVERY_MENU_ACTION=wipe; return 0; }
_NUKE_CALLED=0
nuke_existing_install() { _NUKE_CALLED=1; return 0; }
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: Use existing + menu wipe → return 0 after nuke"
assert_eq "1" "$_NUKE_CALLED" "detect_existing_install: Use existing + menu wipe → nuke_existing_install was called"
assert_eq "" "${RECOVERY_MENU_ACTION:-}" "detect_existing_install: successful menu wipe clears RECOVERY_MENU_ACTION"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker show_existing_install_menu nuke_existing_install
unset _NUKE_CALLED RECOVERY_MENU_ACTION EXISTING_INSTALL_DETECTED

# Test 9: Use existing + failed add-stage propagates non-zero and does not wipe.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() { RECOVERY_MENU_ACTION=completed; return 42; }
_NUKE_CALLED=0
nuke_existing_install() { _NUKE_CALLED=1; return 0; }
detect_existing_install
rc=$?
assert_eq "42" "$rc" "detect_existing_install: failed add-stage menu action → propagates non-zero"
assert_eq "0" "$_NUKE_CALLED" "detect_existing_install: failed add-stage menu action → does not wipe"
assert_eq "completed" "${RECOVERY_MENU_ACTION:-}" "detect_existing_install: failed add-stage preserves menu action"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker show_existing_install_menu nuke_existing_install
unset _NUKE_CALLED RECOVERY_MENU_ACTION EXISTING_INSTALL_DETECTED

# Test 5 (moved to end — re-sources checks.sh, so any function clobbering
# cannot affect tests above): ui_choose returns "Wipe..." → nuke_existing_install is called.
# Shim nuke_existing_install with a sentinel to verify it was invoked.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Wipe everything and start fresh"; }
docker() { :; }
_NUKE_CALLED=0
nuke_existing_install() { _NUKE_CALLED=1; }
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: Wipe → returns 0 after nuke"
assert_eq "1" "$_NUKE_CALLED" "detect_existing_install: Wipe → nuke_existing_install was called"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker nuke_existing_install
unset _NUKE_CALLED

# Test 5b: direct Wipe propagates nuke failure instead of continuing setup.
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' > "$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' > "$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Wipe everything and start fresh"; }
docker() { :; }
nuke_existing_install() { return 37; }
detect_existing_install
rc=$?
assert_eq "37" "$rc" "detect_existing_install: Wipe → propagates nuke failure"
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_choose docker nuke_existing_install
# Re-source checks.sh to restore the real nuke_existing_install
# so any subsequent tests in the file see production state.
source "$REPO_ROOT/scripts/setup/checks.sh"

# ---------------------------------------------------------------------------
# nuke_existing_install + _print_destroy_preview (PRE-06)
# ---------------------------------------------------------------------------
# All happy-path tests redirect SCRIPT_DIR to a mktemp -d directory before
# invoking the function so even an unshimmed `rm -f "$SCRIPT_DIR/.env"`
# cannot harm a real file.

# Test 1: _print_destroy_preview emits the #97-corrected DELETE/PRESERVE phrases.
preview_out=$(_print_destroy_preview)
assert_contains "$preview_out" "Docker containers (compose" "_print_destroy_preview: lists Docker containers (destroy command)"
assert_contains "$preview_out" ".env (your secrets file" "_print_destroy_preview: lists .env"
assert_contains "$preview_out" "data/ - your media library" "_print_destroy_preview: PRESERVES data/ explicitly"
assert_contains "$preview_out" "config/ - all service settings" "_print_destroy_preview: #97 — PRESERVES config/ (survives down -v)"
assert_contains "$preview_out" "clear ./config" "_print_destroy_preview: #97 — notes how to truly start clean"
assert_contains "$preview_out" "Pre-seeded configs tracked in git" "_print_destroy_preview: PRESERVES git-tracked configs"
assert_contains "$preview_out" "This will DELETE:" "_print_destroy_preview: DELETE header present"
assert_contains "$preview_out" "This will PRESERVE:" "_print_destroy_preview: PRESERVE header present"
# #97: the phantom "named volumes" DELETE wording is gone — docker-compose.yml
# declares no top-level volumes, so 'down -v' removes nothing on disk and the
# old phrase misled users into expecting a clean slate. Non-tautological: the
# pre-#97 body contained "Docker containers and named volumes".
named_vol_negative=$(printf '%s' "$preview_out" | grep -c 'named volume' || true)
assert_eq "0" "$named_vol_negative" "_print_destroy_preview: #97 — phantom 'named volumes' phrasing is gone"
# WR-04: the misleading DELETE-bullet wording "config/ runtime-generated
# files (gitignored — re-rendered on next setup)" was removed because
# nuke_existing_install does not delete config/.
preview_negative=$(printf '%s' "$preview_out" | grep -c 'config/ runtime-generated files (gitignored — re-rendered on next setup)' || true)
assert_eq "0" "$preview_negative" "_print_destroy_preview: WR-04 — misleading DELETE-bullet wording is gone"
profile_all_negative=$(printf '%s' "$preview_out" | grep -c 'compose --profile all down -v' || true)
assert_eq "0" "$profile_all_negative" "_print_destroy_preview: profiled-service reset does not advertise literal profile all"
assert_contains "$preview_out" "compose --profile '*' down -v" "_print_destroy_preview: profiled-service reset advertises Compose all-profile wildcard"

# Test 2: typed "DESTROY" → destroy commands invoked, return 0
# Success path does NOT call exit — invoke directly so docker/rm shim
# mutations are visible in the parent shell. (Subshell-capture, used
# below for the abort paths, would lose those mutations.)
ui_input() { echo "DESTROY"; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; return 0; }
_RM_ARGS=""
# rm is a builtin override hazard — bash will use the function before the
# binary, but only when the function exists. We use a function-shim instead
# of `command -p rm`. Guard SCRIPT_DIR with a temp dir so even if the
# function chain is buggy, we don't `rm` a real file.
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: > "$_tmpdir/.env"
: > "$_tmpdir/.nvidia-finalize-pending"
_NUKE_ORDER=()
storage_pause_watchdog_for_install() { _NUKE_ORDER+=("pause"); return 0; }
docker() { _DOCKER_ARGS="$*"; _NUKE_ORDER+=("docker_down"); return 0; }
rm() { _RM_ARGS="$*"; }
nuke_existing_install; rc=$?
assert_eq "0" "$rc" "nuke_existing_install: typed DESTROY → return 0"
# docker compose --profile "*" down -v 2>/dev/null || true
assert_contains "$_DOCKER_ARGS" "compose --profile * down -v" "nuke_existing_install: docker compose all-profile down -v invoked"
assert_eq "compose --profile * down -v" "$_DOCKER_ARGS" "nuke_existing_install: uses all-profile wildcard, not literal profile all"
assert_contains "$_RM_ARGS" "$_tmpdir/.env" "nuke_existing_install: rm -f \$SCRIPT_DIR/.env invoked"
assert_contains "$_RM_ARGS" "$_tmpdir/.nvidia-finalize-pending" "nuke_existing_install: rm -f NVIDIA finalize marker invoked"
assert_eq "pause docker_down" "${_NUKE_ORDER[*]}" "nuke_existing_install: pauses watchdog before compose down"
rm() { command rm "$@"; }   # restore so the cleanup below works
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_input docker rm storage_pause_watchdog_for_install
unset _DOCKER_ARGS _RM_ARGS _NUKE_ORDER

# Test 2b: failed watchdog pause aborts before docker down or .env removal.
source "$REPO_ROOT/scripts/setup/storage.sh"
ui_input() { echo "DESTROY"; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; return 0; }
_RM_ARGS=""
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'STORAGE_MODE=nas\nDATA_DIR=/data\n' > "$_tmpdir/.env"
storage_pause_watchdog_for_install() { return 1; }
rm() { _RM_ARGS="$*"; }
nuke_existing_install; rc=$?
assert_eq "1" "$rc" "nuke_existing_install: failed watchdog pause returns non-zero"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: failed watchdog pause does not run docker down"
assert_eq "" "$_RM_ARGS" "nuke_existing_install: failed watchdog pause does not remove .env"
rm() { command rm "$@"; }
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_input docker rm storage_pause_watchdog_for_install
unset _DOCKER_ARGS _RM_ARGS
source "$REPO_ROOT/scripts/setup/storage.sh"

# Test 3: typed "destroy" (lowercase) → exit 0, NO destroy commands
ui_input() { echo "destroy"; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; }
rm() { :; }
( nuke_existing_install ); rc=$?
assert_eq "0" "$rc" "nuke_existing_install: lowercase destroy → exit 0"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: lowercase → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

# Test 4: typed "DESTROY\r" (CR-suffixed paste from Windows) → DESTROY accepted
# Success path — invoke directly (no subshell) so the docker shim mutation
# is visible in the parent shell.
ui_input() { printf 'DESTROY\r'; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; return 0; }
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: > "$_tmpdir/.env"
storage_pause_watchdog_for_install() { return 0; }
rm() { :; }
nuke_existing_install; rc=$?
assert_eq "0" "$rc" "nuke_existing_install: DESTROY\\r (CR paste) → return 0"
assert_contains "$_DOCKER_ARGS" "compose --profile * down -v" "nuke_existing_install: CR-suffix → docker invoked with all profiles (CR strip works)"
rm() { command rm "$@"; }   # restore for cleanup
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_input docker rm storage_pause_watchdog_for_install
unset _DOCKER_ARGS
source "$REPO_ROOT/scripts/setup/storage.sh"

# Test 5: typed " DESTROY " (whitespace) → exit 0, NO destroy commands
ui_input() { echo " DESTROY "; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; }
rm() { :; }
( nuke_existing_install ); rc=$?
assert_eq "0" "$rc" "nuke_existing_install: ' DESTROY ' (whitespace) → exit 0 (no whitespace tolerance)"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: whitespace → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

# Test 6: typed "" (empty) → exit 0
ui_input() { echo ""; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; }
rm() { :; }
( nuke_existing_install ); rc=$?
assert_eq "0" "$rc" "nuke_existing_install: empty input → exit 0"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: empty → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

# ===========================================================================
# Integration-shape sub-suite (WR-06 fix)
# ---------------------------------------------------------------------------
# The unit tests above run with `set +e; set +u` (line 27-28) so assertions
# can run after expected-fail commands. That harness masks every `set -e`
# interaction bug class. This sub-suite re-enables `set -euo pipefail` in
# subshells so the production runtime shape is exercised.
#
# Each test runs in `bash -c '...'` so set -e/-u/-o pipefail are scoped to
# the subshell — we re-source setup.sh inside each subshell because the
# parent process disabled strict mode for the unit tests.
# ===========================================================================

echo -e "${CYAN}─ integration-shape sub-suite (set -euo pipefail) ─${NC}"

_REPO_ROOT="$REPO_ROOT"

# Integration Test 1 (CR-01): fresh-host detect_existing_install under
# set -euo pipefail returns cleanly.
# Use a tempdir as SCRIPT_DIR so the host's real .env is not consulted.
_intg_tmp=$(mktemp -d)
out=$(bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$_intg_tmp"'"
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    detect_existing_install
    echo "AFTER_DETECT"
' 2>&1); rc=$?
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "INTG/CR-01: detect_existing_install on fresh host → rc=0 under set -euo pipefail"
assert_contains "$out" "AFTER_DETECT" "INTG/CR-01: control reaches AFTER detect_existing_install (script does not die silently)"

# Integration Test 2 (CR-02 part 1): Docker Hub probe failure under set -e
# emits the locked D-11 message and exits 1 (NOT curl's 6).
out=$(bash -c '
    set -euo pipefail
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    curl() { return 6; }
    check_internet_reachability
' 2>&1); rc=$?
assert_eq "1" "$rc" "INTG/CR-02a: Docker Hub probe fail → exit 1 under set -euo pipefail (NOT 6)"
assert_contains "$out" "Pre-flight: Docker Hub unreachable (6)" "INTG/CR-02a: D-11 Docker Hub message verbatim with curl exit code"

# Integration Test 3 (CR-02 part 2): Let's Encrypt probe failure under set -e
# (after Docker Hub succeeds) warns and continues. Stage 1 LAN setup must not
# be blocked by a remote-access-only dependency.
out=$(bash -c '
    set -euo pipefail
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    _CC=0
    curl() {
        _CC=$((_CC+1))
        if (( _CC == 1 )); then return 0; fi
        return 28
    }
    check_internet_reachability
    echo "AFTER_LE_WARN"
' 2>&1); rc=$?
assert_eq "0" "$rc" "INTG/CR-02b: Let's Encrypt probe fail → rc=0 under set -euo pipefail"
assert_contains "$out" "Let's Encrypt unreachable (28)" "INTG/CR-02b: LE warning includes curl exit code"
assert_contains "$out" "AFTER_LE_WARN" "INTG/CR-02b: control reaches caller after LE warning"

# Integration Test 4 (CR-03): GPU_TYPE survives the pre-flight battery
# block. We replicate the eight-call sequence in the new D-04 order
# (with globals initialised BEFORE) and assert GPU_TYPE is "nvidia"
# at the end. Run main() is interactive (calls run_wizard); we instead
# exercise the prologue + battery block in isolation, which is what
# the bug fix actually changed.
#
# Stub out the pre-flight checks that need real system state (docker,
# disk, internet, sudo) — we are testing the GPU_TYPE preservation,
# not those checks.
_intg_tmp=$(mktemp -d)
out=$(bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$_intg_tmp"'"
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    source scripts/setup/gpu.sh
    # Shim system probes — they are not under test here.
    check_docker() { :; }
    check_compose() { :; }
    check_disk_floor() { :; }
    check_internet_reachability() { :; }
    check_ram_warn() { :; }
    prompt_sudo_cache() { :; }
    lspci() { printf "01:00.0 VGA compatible controller: NVIDIA Corporation GA104\n"; }
    # Replicate setup.sh::main prologue post-fix (CR-03 fix in effect):
    FULL_MODE=false
    NEEDS_REBOOT=false
    GPU_TYPE="none"
    check_docker
    check_compose
    check_disk_floor
    check_internet_reachability
    check_ram_warn
    prompt_sudo_cache
    stash_gpu_type
    detect_existing_install
    printf "GPU_TYPE_AT_END=%s\n" "$GPU_TYPE"
' 2>&1); rc=$?
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "INTG/CR-03: pre-flight battery in fixed order under set -euo pipefail → rc=0"
assert_contains "$out" "GPU_TYPE_AT_END=nvidia" "INTG/CR-03: GPU_TYPE survives pre-flight battery (stash write is last write)"

# Integration Test 5 (WR-01): empty df output on / is hard-failed under
# set -euo pipefail (not silently passed through to log_ok).
out=$(bash -c '
    set -euo pipefail
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    df() { :; }   # produces no output → root_free=""
    stat() { echo "/"; }
    _resolve_data_partition() { echo "/data"; }
    check_disk_floor
' 2>&1); rc=$?
assert_eq "1" "$rc" "INTG/WR-01: empty df output → exit 1 under set -euo pipefail"
assert_contains "$out" "could not read free space on /" "INTG/WR-01: hard-fail message names / explicitly"

# Integration Test 6 (CR-04): destroy failure surfaces a log_warn before
# rm -f .env. The post-WARNING-1-fix code is a flat `docker compose ... ||
# _down_rc=$?` (no group-membership branch), so we just shim `docker` to
# fail with a known rc and capture the resulting log_warn. SCRIPT_DIR is
# a tempdir so rm -f only touches the synthetic .env.
_intg_tmp=$(mktemp -d)
: > "$_intg_tmp/.env"
out=$(bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$_intg_tmp"'"
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    ui_input() { echo "DESTROY"; }
    storage_pause_watchdog_for_install() { :; }
    docker() { return 126; }       # any non-zero rc
    nuke_existing_install
' 2>&1); rc=$?
env_after_destroy="absent"
[[ -f "$_intg_tmp/.env" ]] && env_after_destroy="present"
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "INTG/CR-04: destroy with docker rc!=0 still returns 0 (rm .env still runs)"
assert_contains "$out" "destroy did not complete cleanly" "INTG/CR-04: log_warn fires when destroy fails"
assert_contains "$out" "(docker compose exit 126)" "INTG/CR-04: log_warn includes the captured exit code"
assert_eq "absent" "$env_after_destroy" "INTG/CR-04: rm -f .env still runs after the warn (D-23 sequence preserved)"

unset _REPO_ROOT _intg_tmp

echo -e "${CYAN}◀ checks done${NC}"
summary

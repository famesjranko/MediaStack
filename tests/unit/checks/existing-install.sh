# Owns: detect_existing_install. Sourced by tests/unit/checks.sh; inherits
# its preamble (setup.sh sourced, log_* silenced, set +e/+u).
# Each scenario uses a tempdir as a synthetic SCRIPT_DIR so the real host's
# .env / config tree is never read. ui_choose, docker, and timeout are all
# shimmed; the real ones are never invoked. Hard-exit branches are captured
# in subshells (Pattern P).

_orig_script_dir="$SCRIPT_DIR"

# Sentinel-file convention used in this section: ui_choose runs inside
# `choice=$(ui_choose ...)` (command-substitution subshell), so variable
# mutations from a ui_choose shim are lost on return. We use a sentinel
# file instead — touched inside the shim, checked from the parent shell.

# Test 1: .env absent → returns 0, no ui_choose call,
# EXISTING_INSTALL_DETECTED=false
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() {
    : >"$_ui_sentinel"
    echo "Abort"
}
docker() { :; } # never called in this branch
unset EXISTING_INSTALL_DETECTED
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: .env absent → returns 0"
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

# Test 2: .env empty (zero-byte) → returns 0
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: >"$_tmpdir/.env" # zero-byte file
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() {
    : >"$_ui_sentinel"
    echo "Abort"
}
docker() { :; }
unset EXISTING_INSTALL_DETECTED
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: .env empty → returns 0"
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
ui_choose() {
    : >"$_ui_sentinel"
    echo "Use existing install"
}
docker() { :; }
unset EXISTING_INSTALL_DETECTED
detect_existing_install
rc=$?
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() {
    RECOVERY_MENU_ACTION="continue"
    return 0
}
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Abort"; }
docker() { :; }
(detect_existing_install)
rc=$?
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
# NO ddns config in this scenario.
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
timeout() {
    # Bypass the timeout wrapper; pass through to docker shim.
    shift # discard the timeout duration arg
    "$@"
}
docker() {
    if [[ "${1:-}" == "ps" ]]; then
        printf 'abc123\n'
    fi
}
ui_choose() {
    : >"$_ui_sentinel"
    echo "Use existing install"
}
show_existing_install_menu() {
    RECOVERY_MENU_ACTION="continue"
    return 0
}
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

# Test 7: .env non-empty + no ddns config + docker ps returns empty → returns 0
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
_ui_sentinel="$_tmpdir/.ui-choose-was-called"
timeout() {
    shift
    "$@"
}
docker() { :; } # ps returns empty
ui_choose() {
    : >"$_ui_sentinel"
    echo "Abort"
}
unset EXISTING_INSTALL_DETECTED
detect_existing_install
rc=$?
assert_eq "0" "$rc" "detect_existing_install: no ddns + no jellyfin → returns 0"
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() {
    RECOVERY_MENU_ACTION=wipe
    return 0
}
_NUKE_CALLED=0
nuke_existing_install() {
    _NUKE_CALLED=1
    return 0
}
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
ui_choose() { echo "Use existing install"; }
docker() { :; }
show_existing_install_menu() {
    RECOVERY_MENU_ACTION=completed
    return 42
}
_NUKE_CALLED=0
nuke_existing_install() {
    _NUKE_CALLED=1
    return 0
}
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
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
printf 'DATA_DIR=/data\nSTAGE_1_COMPLETE=1\n' >"$_tmpdir/.env"
mkdir -p "$_tmpdir/config/ddns-updater"
printf '{}' >"$_tmpdir/config/ddns-updater/config.json"
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

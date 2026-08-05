# Owns: nuke_existing_install, _print_destroy_preview. Sourced by
# tests/unit/checks.sh; inherits its preamble (setup.sh sourced, log_*
# silenced, set +e/+u).
# All happy-path tests redirect SCRIPT_DIR to a mktemp -d directory before
# invoking the function so even an unshimmed `rm -f "$SCRIPT_DIR/.env"`
# cannot harm a real file.

# Test 1: _print_destroy_preview emits the corrected DELETE/PRESERVE phrases.
preview_out=$(_print_destroy_preview)
assert_contains "$preview_out" "Docker containers (compose" "_print_destroy_preview: lists Docker containers (destroy command)"
assert_contains "$preview_out" ".env (your secrets file" "_print_destroy_preview: lists .env"
assert_contains "$preview_out" "data/ - your media library" "_print_destroy_preview: PRESERVES data/ explicitly"
assert_contains "$preview_out" "config/ - all service settings" "_print_destroy_preview: PRESERVES config/ (survives down -v)"
assert_contains "$preview_out" "clear ./config" "_print_destroy_preview: notes how to truly start clean"
assert_contains "$preview_out" "Pre-seeded configs (fail2ban filters, jackett ServerConfig, etc.)" "_print_destroy_preview: PRESERVES pre-seeded configs"
assert_contains "$preview_out" "This will DELETE:" "_print_destroy_preview: DELETE header present"
assert_contains "$preview_out" "This will PRESERVE:" "_print_destroy_preview: PRESERVE header present"
# The phantom "named volumes" DELETE wording is gone — docker-compose.yml
# declares no top-level volumes, so 'down -v' removes nothing on disk and the
# old phrase misled users into expecting a clean slate. Non-tautological: the
# body before the fix contained "Docker containers and named volumes".
named_vol_negative=$(printf '%s' "$preview_out" | grep -c 'named volume' || true)
assert_eq "0" "$named_vol_negative" "_print_destroy_preview: phantom 'named volumes' phrasing is gone"
# The misleading DELETE-bullet wording "config/ runtime-generated
# files (gitignored — re-rendered on next setup)" was removed because
# nuke_existing_install does not delete config/.
preview_negative=$(printf '%s' "$preview_out" | grep -c 'config/ runtime-generated files (gitignored — re-rendered on next setup)' || true)
assert_eq "0" "$preview_negative" "_print_destroy_preview: misleading DELETE-bullet wording is gone"
profile_all_negative=$(printf '%s' "$preview_out" | grep -c 'compose --profile all down -v' || true)
assert_eq "0" "$profile_all_negative" "_print_destroy_preview: profiled-service reset does not advertise literal profile all"
assert_contains "$preview_out" "compose --profile '*' down -v" "_print_destroy_preview: profiled-service reset advertises Compose all-profile wildcard"

# Test 2: typed "DESTROY" → destroy commands invoked, return 0
# Success path does NOT call exit — invoke directly so docker/rm shim
# mutations are visible in the parent shell. (Subshell-capture, used
# below for the abort paths, would lose those mutations.)
ui_input() { echo "DESTROY"; }
_DOCKER_ARGS=""
docker() {
    _DOCKER_ARGS="$*"
    return 0
}
_RM_ARGS=""
# rm is a builtin override hazard — bash will use the function before the
# binary, but only when the function exists. We use a function-shim instead
# of `command -p rm`. Guard SCRIPT_DIR with a temp dir so even if the
# function chain is buggy, we don't `rm` a real file.
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: >"$_tmpdir/.env"
: >"$_tmpdir/.nvidia-finalize-pending"
_NUKE_ORDER=()
storage_pause_watchdog_for_install() {
    _NUKE_ORDER+=("pause")
    return 0
}
docker() {
    _DOCKER_ARGS="$*"
    _NUKE_ORDER+=("docker_down")
    return 0
}
rm() { _RM_ARGS="$*"; }
nuke_existing_install
rc=$?
assert_eq "0" "$rc" "nuke_existing_install: typed DESTROY → return 0"
# docker compose --profile "*" down -v 2>/dev/null || true
assert_contains "$_DOCKER_ARGS" "compose --profile * down -v" "nuke_existing_install: docker compose all-profile down -v invoked"
assert_eq "compose --profile * down -v --remove-orphans" "$_DOCKER_ARGS" "nuke_existing_install: uses all-profile wildcard and removes orphans"
assert_contains "$_RM_ARGS" "$_tmpdir/.env" "nuke_existing_install: rm -f \$SCRIPT_DIR/.env invoked"
assert_contains "$_RM_ARGS" "$_tmpdir/.nvidia-finalize-pending" "nuke_existing_install: rm -f NVIDIA finalize marker invoked"
assert_eq "pause docker_down" "${_NUKE_ORDER[*]}" "nuke_existing_install: pauses watchdog before compose down"
rm() { command rm "$@"; } # restore so the cleanup below works
rm -rf "$_tmpdir"
SCRIPT_DIR="$_orig_script_dir"
unset -f ui_input docker rm storage_pause_watchdog_for_install
unset _DOCKER_ARGS _RM_ARGS _NUKE_ORDER

# Test 2b: failed watchdog pause aborts before docker down or .env removal.
source "$REPO_ROOT/scripts/setup/storage.sh"
ui_input() { echo "DESTROY"; }
_DOCKER_ARGS=""
docker() {
    _DOCKER_ARGS="$*"
    return 0
}
_RM_ARGS=""
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
printf 'STORAGE_MODE=nas\nDATA_DIR=/data\n' >"$_tmpdir/.env"
storage_pause_watchdog_for_install() { return 1; }
rm() { _RM_ARGS="$*"; }
nuke_existing_install
rc=$?
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
(nuke_existing_install)
rc=$?
assert_eq "0" "$rc" "nuke_existing_install: lowercase destroy → exit 0"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: lowercase → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

# Test 4: typed "DESTROY\r" (CR-suffixed paste from Windows) → DESTROY accepted
# Success path — invoke directly (no subshell) so the docker shim mutation
# is visible in the parent shell.
ui_input() { printf 'DESTROY\r'; }
_DOCKER_ARGS=""
docker() {
    _DOCKER_ARGS="$*"
    return 0
}
_orig_script_dir="$SCRIPT_DIR"
_tmpdir=$(mktemp -d)
SCRIPT_DIR="$_tmpdir"
: >"$_tmpdir/.env"
storage_pause_watchdog_for_install() { return 0; }
rm() { :; }
nuke_existing_install
rc=$?
assert_eq "0" "$rc" "nuke_existing_install: DESTROY\\r (CR paste) → return 0"
assert_contains "$_DOCKER_ARGS" "compose --profile * down -v" "nuke_existing_install: CR-suffix → docker invoked with all profiles (CR strip works)"
rm() { command rm "$@"; } # restore for cleanup
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
(nuke_existing_install)
rc=$?
assert_eq "0" "$rc" "nuke_existing_install: ' DESTROY ' (whitespace) → exit 0 (no whitespace tolerance)"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: whitespace → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

# Test 6: typed "" (empty) → exit 0
ui_input() { echo ""; }
_DOCKER_ARGS=""
docker() { _DOCKER_ARGS="$*"; }
rm() { :; }
(nuke_existing_install)
rc=$?
assert_eq "0" "$rc" "nuke_existing_install: empty input → exit 0"
assert_eq "" "$_DOCKER_ARGS" "nuke_existing_install: empty → docker NOT invoked"
unset -f ui_input docker rm
unset _DOCKER_ARGS

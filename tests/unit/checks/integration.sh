# Owns: the integration-shape sub-suite for scripts/setup/checks.sh. Sourced
# by tests/unit/checks.sh; inherits its preamble (setup.sh sourced, log_*
# silenced, set +e/+u) plus REPO_ROOT.
#
# The unit tests in the sibling files run with `set +e; set +u` so assertions
# can run after expected-fail commands. That harness masks every `set -e`
# interaction bug class. This sub-suite re-enables `set -euo pipefail` in
# subshells so the production runtime shape is exercised.
#
# Each test runs in `bash -c '...'` so set -e/-u/-o pipefail are scoped to
# the subshell — we re-source setup.sh inside each subshell because the
# parent process disabled strict mode for the unit tests.

echo -e "${CYAN}─ integration-shape sub-suite (set -euo pipefail) ─${NC}"

_REPO_ROOT="$REPO_ROOT"

# Integration Test 1: fresh-host detect_existing_install under
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
' 2>&1)
rc=$?
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "detect_existing_install on fresh host → rc=0 under set -euo pipefail"
assert_contains "$out" "AFTER_DETECT" "control reaches AFTER detect_existing_install (script does not die silently)"

# Integration Test 2: Docker Hub probe failure under set -e
# emits the locked message and exits 1 (NOT curl's 6).
out=$(bash -c '
    set -euo pipefail
    cd "'"$_REPO_ROOT"'"
    source scripts/lib/common.sh
    source scripts/lib/ui.sh
    source scripts/setup/checks.sh
    curl() { return 6; }
    check_internet_reachability
' 2>&1)
rc=$?
assert_eq "1" "$rc" "Docker Hub probe fail → exit 1 under set -euo pipefail (NOT 6)"
assert_contains "$out" "Pre-flight: Docker Hub unreachable (6)" "Docker Hub message verbatim with curl exit code"

# Integration Test 3: Let's Encrypt probe failure under set -e
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
' 2>&1)
rc=$?
assert_eq "0" "$rc" "Let's Encrypt probe fail → rc=0 under set -euo pipefail"
assert_contains "$out" "Let's Encrypt unreachable (28)" "LE warning includes curl exit code"
assert_contains "$out" "AFTER_LE_WARN" "control reaches caller after LE warning"

# Integration Test 4: GPU_TYPE survives the pre-flight battery
# block. We replicate the eight-call sequence in the new order
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
    # Replicate setup.sh::main prologue post-fix:
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
' 2>&1)
rc=$?
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "pre-flight battery in fixed order under set -euo pipefail → rc=0"
assert_contains "$out" "GPU_TYPE_AT_END=nvidia" "GPU_TYPE survives pre-flight battery (stash write is last write)"

# Integration Test 5: empty df output on / is hard-failed under
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
' 2>&1)
rc=$?
assert_eq "1" "$rc" "empty df output → exit 1 under set -euo pipefail"
assert_contains "$out" "could not read free space on /" "hard-fail message names / explicitly"

# Integration Test 6: destroy failure surfaces a log_warn before
# rm -f .env. The current code is a flat `docker compose ... ||
# _down_rc=$?` (no group-membership branch), so we just shim `docker` to
# fail with a known rc and capture the resulting log_warn. SCRIPT_DIR is
# a tempdir so rm -f only touches the synthetic .env.
_intg_tmp=$(mktemp -d)
: >"$_intg_tmp/.env"
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
' 2>&1)
rc=$?
env_after_destroy="absent"
[[ -f "$_intg_tmp/.env" ]] && env_after_destroy="present"
rm -rf "$_intg_tmp"
assert_eq "0" "$rc" "destroy with docker rc!=0 still returns 0 (rm .env still runs)"
assert_contains "$out" "destroy did not complete cleanly" "log_warn fires when destroy fails"
assert_contains "$out" "(docker compose exit 126)" "log_warn includes the captured exit code"
assert_eq "absent" "$env_after_destroy" "rm -f .env still runs after the warn (sequence preserved)"

unset _REPO_ROOT _intg_tmp

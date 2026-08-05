# Owns: _resolve_data_partition, check_disk_floor, check_ram_warn,
# stash_gpu_type, check_internet_reachability, prompt_sudo_cache.
# Sourced by tests/unit/checks.sh; inherits its preamble (setup.sh sourced,
# log_* silenced, set +e/+u).

# ---------------------------------------------------------------------------
# _resolve_data_partition — walk-up via temp .env
# ---------------------------------------------------------------------------

# Test 7: missing DATA_DIR path walks up via dirname loop.
# The temp .env points DATA_DIR at a $$-salted path that cannot exist on the
# host filesystem; walk-up should land at "/" (the loop's terminating ancestor).
_tmpdir=$(mktemp -d)
printf 'DATA_DIR=/nonexistent-walkup-test-%d/deeper/path\n' "$$" >"$_tmpdir/.env"
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
        *"-BG /") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 95G 5G 95%% /\n' ;;
        *"-BG /data") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sdb1 500G 100G 400G 25%% /data\n' ;;
        *) printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 95G 5G 95%% /\n' ;;
    esac
}
stat() {
    # two-FS mode: / and /data on different mountpoints
    case "$*" in
        *"-c %m /") echo "/" ;;
        *"-c %m /data") echo "/data" ;;
        *"-c %m"*) echo "/" ;;
        *) builtin stat "$@" ;;
    esac
}
# Force _resolve_data_partition to return /data without touching .env or FS:
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$(check_disk_floor 2>&1)
rc=$?
log_warn() { _silent_log_warn "$@"; }
assert_eq "0" "$rc" "check_disk_floor: root 5GB → return 0 (warn, never exit)"
assert_contains "$out" "10GB" "check_disk_floor: root 5GB → warn message names 10GB minimum"
unset -f df stat _resolve_data_partition

# Test 5: data <30 GB on a two-FS host → warn-and-continue (return 0 with warn message)
df() {
    case "$*" in
        *"-BG /") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 50G 50G 50%% /\n' ;;
        *"-BG /data") printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sdb1 500G 480G 20G 96%% /data\n' ;;
        *) printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 50G 50G 50%% /\n' ;;
    esac
}
stat() {
    case "$*" in
        *"-c %m /") echo "/" ;;
        *"-c %m /data") echo "/data" ;;
        *) echo "/" ;;
    esac
}
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$(check_disk_floor 2>&1)
rc=$?
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
stat() { echo "/"; }
_resolve_data_partition() { echo "/data"; }
(check_disk_floor)
rc=$?
assert_eq "0" "$rc" "check_disk_floor: single-FS 50GB → ok (no double check)"
unset -f df stat _resolve_data_partition

# Bonus single-FS guard: same mountpoint but only 20 GB free → warn-and-continue
# at the recommended 30 GB minimum (reference floor, not a hard gate).
df() {
    case "$*" in
        *"-BG"*) printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/root 100G 80G 20G 80%% /\n' ;;
    esac
}
stat() { echo "/"; }
_resolve_data_partition() { echo "/data"; }
log_warn() { _visible_log_warn "$@"; }
out=$(check_disk_floor 2>&1)
rc=$?
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
(check_ram_warn)
rc=$?
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
(check_ram_warn)
rc=$?
assert_eq "0" "$rc" "check_ram_warn: 8GB → ok"
unset -f grep awk

# Test 3: MemAvailable absent → graceful skip, return 0
grep() {
    if [[ "$*" == *"MemAvailable"* ]]; then
        return 1
    fi
    builtin grep "$@" 2>/dev/null
}
(check_ram_warn)
rc=$?
assert_eq "0" "$rc" "check_ram_warn: MemAvailable absent → graceful skip, return 0"
unset -f grep

# ---------------------------------------------------------------------------
# stash_gpu_type
# ---------------------------------------------------------------------------
# Wraps the existing detect_gpu (gpu.sh:9-31). We shim lspci with the same
# pattern as tests/unit/gpu-branching.sh so detect_gpu's grep cascade resolves
# the expected GPU_TYPE without touching real PCI hardware.

# Test: stash_gpu_type — nvidia path
lspci() { printf '01:00.0 VGA compatible controller: NVIDIA Corporation GA104\n'; }
GPU_TYPE=""
stash_gpu_type
assert_eq "nvidia" "$GPU_TYPE" "stash_gpu_type: nvidia via lspci"
unset -f lspci

# Test: stash_gpu_type — intel path
lspci() { printf '00:02.0 VGA compatible controller: Intel Corporation UHD Graphics\n'; }
GPU_TYPE=""
stash_gpu_type
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
(stash_gpu_type)
rc=$?
assert_eq "0" "$rc" "stash_gpu_type: lspci missing → returns 0 (no exit 1)"
GPU_TYPE=""
stash_gpu_type
assert_eq "none" "$GPU_TYPE" "stash_gpu_type: lspci missing → GPU_TYPE=none"
unset -f command

# ---------------------------------------------------------------------------
# check_internet_reachability
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
out=$(check_internet_reachability 2>&1)
rc=$?
# shellcheck disable=SC2034 # read by check_internet_reachability in scripts/setup/checks/preflight.sh, sourced by the suite entry point
FULL_MODE=false
log_warn() { :; }
assert_eq "0" "$rc" "check_internet_reachability: curl missing in --full → defer"
assert_contains "$out" "curl is not installed yet" "check_internet_reachability: curl missing in --full → message explains deferral"
unset -f command curl

# Test: hub.docker.com fails (resolve error 6) → exit 1
curl() { return 6; }
(check_internet_reachability 2>&1)
rc=$?
assert_eq "1" "$rc" "check_internet_reachability: hub fails → exit 1"
unset -f curl

# Test: hub succeeds, ACME fails (timeout 28) → warn and continue, because
# Stage 1 LAN setup does not require Let's Encrypt. Stage 2 classifies the
# real certificate attempt.
log_warn() { echo "[WARN] $1"; }

_CURL_CALL=0
curl() {
    _CURL_CALL=$((_CURL_CALL + 1))
    if ((_CURL_CALL == 1)); then return 0; fi
    return 28
}
out=$(check_internet_reachability 2>&1)
rc=$?
assert_eq "0" "$rc" "check_internet_reachability: ACME fails → warn and continue"
assert_contains "$out" "Let's Encrypt unreachable" "check_internet_reachability: warning names Let's Encrypt"
assert_contains "$out" "(28)" "check_internet_reachability: message contains curl exit code 28"

# Re-silence log_warn for downstream tests.
log_warn() { :; }
unset -f curl
unset _CURL_CALL

# Test: both probes succeed → return 0 (no exit)
curl() { return 0; }
(check_internet_reachability)
rc=$?
assert_eq "0" "$rc" "check_internet_reachability: both succeed → return 0"
unset -f curl

# ---------------------------------------------------------------------------
# prompt_sudo_cache
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
(prompt_sudo_cache)
rc=$?
assert_eq "1" "$rc" "prompt_sudo_cache: sudo absent → exit 1"
unset -f command

# Test: passwordless sudo (sudo -n true returns 0)
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 0; fi
    return 0
}
(prompt_sudo_cache)
rc=$?
assert_eq "0" "$rc" "prompt_sudo_cache: passwordless → return 0"
unset -f sudo

# Test: sudo -n true fails, sudo -v succeeds (cached path)
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 1; fi
    # sudo -p "..." -v
    if [[ "$1" == "-p" ]]; then return 0; fi
    return 0
}
(prompt_sudo_cache)
rc=$?
assert_eq "0" "$rc" "prompt_sudo_cache: sudo -v cached → return 0"
unset -f sudo

# Test: sudo -n true fails AND sudo -v fails → exit 1
sudo() {
    if [[ "$1" == "-n" && "$2" == "true" ]]; then return 1; fi
    return 1
}
(prompt_sudo_cache)
rc=$?
assert_eq "1" "$rc" "prompt_sudo_cache: sudo -v fails → exit 1"
unset -f sudo

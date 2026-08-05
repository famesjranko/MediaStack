#!/usr/bin/env bash
# Owns: the ordered GPU unit-suite entry point and shared test setup.
# Sources: tests/unit/gpu/* and scripts/setup/gpu.sh via setup.sh.
# tests/unit/gpu-branching.sh
#
# Pure-bash unit test for the GPU helpers in setup.sh: detect_gpu,
# nvidia_driver_check_secure_boot, verify_gpu_usable. No DinD, no Docker, no network.
#
# Shims are defined as bash functions in the test shell — when setup.sh's
# helpers call `lspci` / `mokutil` / `nvidia-smi` / `docker`, the in-shell
# function wins over PATH. `command -v` absence is simulated by overriding
# `command` itself (since mokutil may actually exist on the host).
#
# Render-node cases are mocked in-shell so this unit is deterministic on hosts
# with Intel, AMD, NVIDIA, or no GPU hardware.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="gpu-branching"
echo -e "${CYAN}${BOLD}▶ scenario: gpu-branching${NC}"

# Source setup.sh for the helper functions. The guard added to setup.sh's
# bottom ensures main() does not run under `source`.
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# setup.sh sets -euo pipefail; relax so asserts can run a full pass/fail.
set +e
set +u

# Silence log_* output from the helpers — the test drives its own assertions.
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# ui_spin normally runs its command in a background subshell (the spinner owns
# the TTY), which discards mock side-effects (e.g. an array a stubbed sudo fills).
# Run the wrapped command in-process so call-capturing mocks observe the calls.
ui_spin() {
    shift
    "$@"
}

GPU_TEST_DIR="$REPO_ROOT/tests/unit/gpu"
source "$GPU_TEST_DIR/detection.sh"
source "$GPU_TEST_DIR/nvidia-secure-boot.sh"
source "$GPU_TEST_DIR/verify.sh"
source "$GPU_TEST_DIR/intel-amd.sh"
source "$GPU_TEST_DIR/nvidia-driver.sh"
source "$GPU_TEST_DIR/nvidia-install.sh"
source "$GPU_TEST_DIR/nvidia-modes.sh"
source "$GPU_TEST_DIR/nvidia-patch.sh"
source "$GPU_TEST_DIR/nvidia-apt.sh"

# --- nvidia_driver_ensure_debian_nonfree: per-release component set + idempotent ---
# `printf ... | sudo tee` runs sudo in a pipe subshell, so capture the written
# source line to a temp file (a variable assignment wouldn't reach this shell).
_nf_cap=$(mktemp)
# nvidia_driver_ensure_debian_nonfree greps the system sources file directly (apt-cache is
# circular — our own stale managed file would make a component look "visible").
# Point it at a temp file via the test-only seam so per-case "already present"
# state is deterministic instead of depending on the host's real sources.list.
_nf_src=$(mktemp)
export MEDIASTACK_APT_SOURCES="$_nf_src"
sudo() {
    if [[ "${1:-}" == "tee" ]]; then cat >"$_nf_cap"; else cat >/dev/null 2>&1 || true; fi
    return 0
}
: >"$_nf_src" # no components visible → managed file is written
nvidia_driver_debian_codename() { printf 'bookworm'; }
_nvidia_driver_debian_version_id() { printf '12'; }
: >"$_nf_cap"
nvidia_driver_ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "nvidia_driver_ensure_debian_nonfree: Debian 12 includes contrib"
assert_contains "$_nf_line" "non-free-firmware" "nvidia_driver_ensure_debian_nonfree: Debian 12 includes non-free-firmware"
nvidia_driver_debian_codename() { printf 'bullseye'; }
_nvidia_driver_debian_version_id() { printf '11'; }
: >"$_nf_cap"
nvidia_driver_ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "nvidia_driver_ensure_debian_nonfree: Debian 11 includes contrib"
case "$_nf_line" in
    *non-free-firmware*) fail "nvidia_driver_ensure_debian_nonfree: Debian 11 must NOT use non-free-firmware" ;;
    *non-free*) pass "nvidia_driver_ensure_debian_nonfree: Debian 11 uses non-free without non-free-firmware" ;;
    *) fail "nvidia_driver_ensure_debian_nonfree: Debian 11 missing non-free component" ;;
esac
nvidia_driver_debian_codename() { printf 'trixie'; }
_nvidia_driver_debian_version_id() { printf '13'; }
: >"$_nf_cap"
nvidia_driver_ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "non-free-firmware" "nvidia_driver_ensure_debian_nonfree: Debian 13 includes non-free-firmware"
# Partial setup: non-free visible but contrib/non-free-firmware missing → still writes.
printf 'deb http://deb.debian.org/debian trixie main non-free\n' >"$_nf_src"
: >"$_nf_cap"
nvidia_driver_ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_contains "$_nf_line" "contrib" "nvidia_driver_ensure_debian_nonfree: partial setup (non-free only) still enables contrib"
assert_contains "$_nf_line" "non-free-firmware" "nvidia_driver_ensure_debian_nonfree: partial setup still enables non-free-firmware"
# Idempotent: when ALL required components are already visible, do not rewrite.
printf 'deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\n' >"$_nf_src"
: >"$_nf_cap"
nvidia_driver_ensure_debian_nonfree
_nf_line=$(cat "$_nf_cap")
assert_eq "" "$_nf_line" "nvidia_driver_ensure_debian_nonfree: idempotent — skips when all components visible"
rm -f "$_nf_cap" "$_nf_src"
unset MEDIASTACK_APT_SOURCES
unset -f sudo nvidia_driver_debian_codename _nvidia_driver_debian_version_id
unset _nf_cap _nf_src _nf_line

# --- nvidia_driver_ensure_debian_backports: managed source, idempotent, codename-aware ---
_bp_cap=$(mktemp)
sudo() {
    if [[ "${1:-}" == "tee" ]]; then cat >"$_bp_cap"; else cat >/dev/null 2>&1 || true; fi
    return 0
}
nvidia_driver_debian_codename() { printf 'bookworm'; }
_nvidia_driver_debian_version_id() { printf '12'; }
apt-cache() { return 0; } # backports not visible → written
: >"$_bp_cap"
nvidia_driver_ensure_debian_backports
_bp_line=$(cat "$_bp_cap")
assert_contains "$_bp_line" "bookworm-backports" "nvidia_driver_ensure_debian_backports: writes a <codename>-backports source"
assert_contains "$_bp_line" "non-free-firmware" "nvidia_driver_ensure_debian_backports: Debian 12 backports includes non-free-firmware"
# Idempotent: skip when backports is already visible to apt.
apt-cache() { printf ' 100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages\n'; }
: >"$_bp_cap"
nvidia_driver_ensure_debian_backports
_bp_line=$(cat "$_bp_cap")
assert_eq "" "$_bp_line" "nvidia_driver_ensure_debian_backports: idempotent — skips when backports already visible"
rm -f "$_bp_cap"
unset -f apt-cache sudo nvidia_driver_debian_codename _nvidia_driver_debian_version_id
unset _bp_cap _bp_line

# --- Mode chooser default is Standard (patch never default) non-interactively ---
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
UI_DEMO=1
mode_default=$(_stage3_choose_nvidia_mode 2>/dev/null)
assert_eq "standard" "$mode_default" "_stage3_choose_nvidia_mode: non-interactive default is Standard, never Unlock"
unset UI_DEMO mode_default

# --- write_env driver-mode migration (_nvidia_resolve_driver_mode) ---
assert_eq "unlock" "$(_nvidia_resolve_driver_mode "" "true")" "_nvidia_resolve_driver_mode: legacy NVIDIA_PATCH_ENABLED=true → unlock"
assert_eq "standard" "$(_nvidia_resolve_driver_mode "standard" "")" "_nvidia_resolve_driver_mode: explicit standard preserved"
assert_eq "unlock" "$(_nvidia_resolve_driver_mode "unlock" "")" "_nvidia_resolve_driver_mode: explicit unlock preserved"
assert_eq "existing" "$(_nvidia_resolve_driver_mode "existing" "")" "_nvidia_resolve_driver_mode: existing preserved"
assert_eq "" "$(_nvidia_resolve_driver_mode "" "")" "_nvidia_resolve_driver_mode: fresh install → empty (wizard sets standard on install)"
assert_eq "" "$(_nvidia_resolve_driver_mode "bogus" "")" "_nvidia_resolve_driver_mode: invalid value rejected"

# --- nvidia-repatch.sh: only patches in Unlock mode ---
# Black-box run in a temp tree with a fake (always-failing) nvidia-smi so the
# --force path can never touch a real host driver.
_rp=$(mktemp -d)
mkdir -p "$_rp/scripts/lib" "$_rp/bin"
cp "$REPO_ROOT/scripts/nvidia-repatch.sh" "$_rp/scripts/"
cp "$REPO_ROOT/scripts/lib/nvidia-patch.sh" "$_rp/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 1\n' >"$_rp/bin/nvidia-smi"
chmod +x "$_rp/bin/nvidia-smi"
printf 'NVIDIA_DRIVER_MODE=standard\n' >"$_rp/.env"
_rp_out=$(PATH="$_rp/bin:$PATH" bash "$_rp/scripts/nvidia-repatch.sh" 2>&1)
_rp_rc=$?
assert_eq "0" "$_rp_rc" "nvidia-repatch.sh: Standard mode exits 0 (no-op)"
assert_contains "$_rp_out" "nothing to repatch" "nvidia-repatch.sh: Standard mode reports nothing to repatch"
_rp_out2=$(PATH="$_rp/bin:$PATH" bash "$_rp/scripts/nvidia-repatch.sh" --force 2>&1) || true
case "$_rp_out2" in
    *"nothing to repatch"*) fail "nvidia-repatch.sh: --force must bypass the mode guard" ;;
    *) pass "nvidia-repatch.sh: --force bypasses the mode guard" ;;
esac
rm -rf "$_rp"
unset _rp _rp_out _rp_out2 _rp_rc

unset -f sudo
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

echo -e "${CYAN}◀ gpu-branching done${NC}"
summary

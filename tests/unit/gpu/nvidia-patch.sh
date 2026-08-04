# Owns: NVIDIA Unlock patch assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-patch.sh.
# --- apply_nvidia_patch: normalized multi-GPU version and strict failure status ---
PATCH_TEST_DIR=$(mktemp -d)
nvidia_patch_prepare_repo() { return 0; }
nvidia_patch_export_run_tree() {
    mkdir -p "$PATCH_TEST_DIR/run"
    printf '%s' "$PATCH_TEST_DIR/run"
}
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { printf '550.90\n550.90\n'; }
bash() {
    PATCH_COMPAT_ARG="${3:-}"
    return 0
}
sudo() { return 0; }
SCRIPT_DIR="$PATCH_TEST_DIR/root"
mkdir -p "$SCRIPT_DIR"
rc=0
apply_nvidia_patch || rc=$?
assert_eq "0" "$rc" "apply_nvidia_patch: successful NVENC patch returns success"
assert_eq "550.90" "$PATCH_COMPAT_ARG" "apply_nvidia_patch: duplicate GPU versions normalize before compatibility check"
sudo() { return 1; }
rc=0
apply_nvidia_patch || rc=$?
assert_eq "1" "$rc" "apply_nvidia_patch: failed NVENC patch returns failure"
rm -rf "$PATCH_TEST_DIR"
unset -f nvidia_patch_prepare_repo nvidia_patch_export_run_tree command nvidia-smi bash sudo
unset PATCH_TEST_DIR PATCH_COMPAT_ARG rc

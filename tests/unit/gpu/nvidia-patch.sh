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

# --- apply_nvidia_patch_cleanup: patch leftovers of a removed Unlock driver ---
# Fake host: a lib dir with MediaStack-patched encode/fbc libraries (the
# originals sit in the /opt/nvidia backups), their .so.1 links, an unrelated
# NVIDIA library, and an encode library of another version that was never patched.
_patch_host_fixture() {
    PH_DIR=$(mktemp -d)
    PH_LIB="$PH_DIR/lib"
    PH_OPT="$PH_DIR/opt/nvidia"
    mkdir -p "$PH_LIB" "$PH_OPT/libnvidia-encode-backup" "$PH_OPT/libnvidia-fbc-backup"
    printf 'PATCHED-enc' >"$PH_LIB/libnvidia-encode.so.580.142"
    printf 'PATCHED-fbc' >"$PH_LIB/libnvidia-fbc.so.580.142"
    ln -s libnvidia-encode.so.580.142 "$PH_LIB/libnvidia-encode.so.1"
    ln -s libnvidia-fbc.so.580.142 "$PH_LIB/libnvidia-fbc.so.1"
    printf 'ORIG-enc' >"$PH_OPT/libnvidia-encode-backup/libnvidia-encode.so.580.142"
    printf 'ORIG-fbc' >"$PH_OPT/libnvidia-fbc-backup/libnvidia-fbc.so.580.142"
    printf 'ml' >"$PH_LIB/libnvidia-ml.so.580.142"
    printf 'other-enc' >"$PH_LIB/libnvidia-encode.so.535.1"
    PH_PREV_SCRIPT_DIR="${SCRIPT_DIR-}"
    SCRIPT_DIR="$PH_DIR/root"
    mkdir -p "$SCRIPT_DIR"
    touch "$SCRIPT_DIR/.nvidia-nvenc-unpatched"
    export MS_NVIDIA_LIB_DIRS="$PH_LIB" MS_NVIDIA_BACKUP_ROOT="$PH_OPT"
    sudo() { "$@"; }
    ldconfig() { :; }
}
_patch_host_fixture_end() {
    rm -rf "$PH_DIR"
    unset -f sudo ldconfig
    unset PH_DIR PH_LIB PH_OPT MS_NVIDIA_LIB_DIRS MS_NVIDIA_BACKUP_ROOT
    SCRIPT_DIR="$PH_PREV_SCRIPT_DIR"
    unset PH_PREV_SCRIPT_DIR
}
_patch_host_left() { (cd "$PH_DIR" && find lib opt root -mindepth 1 \( -type f -o -type l \) | sort | tr '\n' ' '); }

# Given the Unlock driver was removed but its patched libraries, .so.1 links and /opt/nvidia backups remain,
# When MediaStack removes its patch artefacts,
# Then only the patched files of the backed-up version, their links and the backups are gone.
_patch_host_fixture
rc=0
apply_nvidia_patch_cleanup || rc=$?
assert_eq "0" "$rc" "apply_nvidia_patch_cleanup: leftovers of a patched driver are removed"
assert_eq "lib/libnvidia-encode.so.535.1 lib/libnvidia-ml.so.580.142 " "$(_patch_host_left)" \
    "apply_nvidia_patch_cleanup: patched libs, .so.1 links, backups and the unpatched marker go; nothing else"
assert_eq "no" "$([[ -d "$PH_OPT/libnvidia-encode-backup" || -d "$PH_OPT/libnvidia-fbc-backup" ]] && echo yes || echo no)" \
    "apply_nvidia_patch_cleanup: the backup directories are removed"
_patch_host_fixture_end

# Given the backups use a <version>/ subdirectory and the patched libraries are already gone,
# When MediaStack removes its patch artefacts,
# Then the dangling .so.1 links are removed too, so nothing points at the old version.
_patch_host_fixture
rm -f "$PH_LIB/libnvidia-encode.so.580.142" "$PH_LIB/libnvidia-fbc.so.580.142"
mkdir -p "$PH_OPT/libnvidia-encode-backup/580.142"
mv "$PH_OPT/libnvidia-encode-backup/libnvidia-encode.so.580.142" "$PH_OPT/libnvidia-encode-backup/580.142/"
rc=0
apply_nvidia_patch_cleanup || rc=$?
dangling=$(find "$PH_LIB" -xtype l | wc -l)
assert_eq "0" "$rc" "apply_nvidia_patch_cleanup: versioned backup layout is handled"
assert_eq "0" "$dangling" "apply_nvidia_patch_cleanup: no .so.1 link is left pointing at the old version"
_patch_host_fixture_end

# Given no MediaStack patch backup exists (the driver was never patched),
# When MediaStack removes its patch artefacts,
# Then it removes nothing and succeeds.
_patch_host_fixture
rm -rf "$PH_OPT"
before="$(_patch_host_left)"
rc=0
apply_nvidia_patch_cleanup || rc=$?
assert_eq "0" "$rc" "apply_nvidia_patch_cleanup: no backups is not an error"
assert_eq "${before/root\/.nvidia-nvenc-unpatched /}" "$(_patch_host_left)" "apply_nvidia_patch_cleanup: without backups no library is touched"
_patch_host_fixture_end
unset -f _patch_host_fixture _patch_host_fixture_end _patch_host_left
unset before dangling rc

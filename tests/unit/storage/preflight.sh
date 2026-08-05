# Owns: storage_env_set, create_data_dirs (manual/NAS), storage_data_services,
# and the early storage_preflight_nas sentinel-creation case. Sourced by
# tests/unit/storage.sh; inherits its preamble.

SCRIPT_DIR="$TMP_DIR/storage-env-set"
mkdir -p "$SCRIPT_DIR"
printf '%s\n' \
    "SONARR_API_KEY=old-sonarr-secret" \
    "STAGE_1_COMPLETE=1" \
    "JELLYFIN_ADMIN_PASSWORD='old-admin-password'" \
    >"$SCRIPT_DIR/.env"
cp "$SCRIPT_DIR/.env" "$SCRIPT_DIR/expected.env"

# storage_env_set delegates to common.sh's _env_write_kv (the one blessed
# .env writer, unit-tested in tests/unit/common.sh). Stub the writer to fail
# and assert the wrapper propagates the failure and leaves .env intact.
_env_write_kv() { return 1; }
storage_env_set STORAGE_EXPECTED_SOURCE "192.0.2.10:/exports/media"
storage_env_set_rc=$?
# NB: this removes the REAL writer too (common.sh's include guard means the
# later re-sources of storage.sh do not restore it). Nothing below reaches an
# env-writing path; restub _env_write_kv if a future test needs one.
unset -f _env_write_kv

if [[ "$storage_env_set_rc" -ne 0 ]]; then
    pass "storage_env_set: propagates writer failure"
else
    fail "storage_env_set: propagates writer failure" "storage_env_set exited 0"
fi

if cmp -s "$SCRIPT_DIR/expected.env" "$SCRIPT_DIR/.env"; then
    pass "storage_env_set: previous .env preserved on write failure"
else
    fail "storage_env_set: previous .env preserved on write failure"
fi

SCRIPT_DIR="$REPO_ROOT"
DATA_DIR="$TMP_DIR/manual-root"
STORAGE_MODE=local
# shellcheck disable=SC2034 # consumed by storage_manual_wiring in storage/core.sh, sourced below
STORAGE_APP_WIRING=manual
SUDO_CALLS="$TMP_DIR/sudo-calls"
mkdir -p "$DATA_DIR"
log_skip() { :; }
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
sudo() {
    printf '%s\n' "$*" >>"$SUDO_CALLS"
    "$@"
}
create_data_dirs
assert_eq "absent" "$([[ -e "$DATA_DIR/media" || -e "$DATA_DIR/torrents" ]] && echo present || echo absent)" "manual storage: create_data_dirs leaves media/torrents untouched"
assert_eq "absent" "$([[ -s "$SUDO_CALLS" ]] && echo present || echo absent)" "manual storage: create_data_dirs does not sudo/chown"
unset STORAGE_APP_WIRING
unset -f sudo log_skip log_info log_ok log_warn

SCRIPT_DIR="$REPO_ROOT"
DATA_DIR="$TMP_DIR/nas-root-user-writable"
STORAGE_MODE=nas
SUDO_CALLS="$TMP_DIR/nas-dir-sudo-calls"
mkdir -p "$DATA_DIR"
log_skip() { :; }
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
sudo() {
    printf '%s\n' "$*" >>"$SUDO_CALLS"
    "$@"
}
create_data_dirs
assert_eq "present" "$([[ -d "$DATA_DIR/media/movies" && -d "$DATA_DIR/torrents/incomplete" ]] && echo present || echo absent)" "NAS storage: create_data_dirs creates managed layout"
assert_eq "absent" "$([[ -s "$SUDO_CALLS" ]] && echo present || echo absent)" "NAS storage: create_data_dirs writes user-writable export without sudo"
unset DATA_DIR STORAGE_MODE SUDO_CALLS
unset -f sudo log_skip log_info log_ok log_warn

BAZARR_ENABLED=false
services_without_bazarr="$(storage_data_services)"
case "$services_without_bazarr" in
    *bazarr*) fail "storage services: excludes Bazarr when subtitles are disabled" ;;
    *) pass "storage services: excludes Bazarr when subtitles are disabled" ;;
esac
# shellcheck disable=SC2034 # consumed by storage_data_services in storage/core.sh, sourced below
BAZARR_ENABLED=true
assert_contains "$(storage_data_services)" "bazarr" "storage services: includes Bazarr when subtitles are enabled"
unset BAZARR_ENABLED

SCRIPT_DIR="$TMP_DIR/preflight-root"
mkdir -p "$SCRIPT_DIR"
cat >"$SCRIPT_DIR/.env" <<'ENV'
STORAGE_MODE=nas
ENV
DATA_DIR="$TMP_DIR/preflight-nas"
# shellcheck disable=SC2034 # consumed by storage_is_nas in storage/core.sh, sourced below
STORAGE_MODE=nas
# shellcheck disable=SC2034 # consumed by storage_mountpoint in storage/core.sh, sourced below
STORAGE_MOUNTPOINT="$DATA_DIR"
# shellcheck disable=SC2034 # consumed by the real storage_mount_nfs in storage/mount.sh; stubbed here
STORAGE_NFS_HOST=127.0.0.1
# shellcheck disable=SC2034 # consumed by the real storage_mount_nfs in storage/mount.sh; stubbed here
STORAGE_NFS_EXPORT=/exports/media
# shellcheck disable=SC2034 # consumed by the real storage_mount_nfs in storage/mount.sh; stubbed here
STORAGE_NFS_OPTS=vers=4.2
STORAGE_SENTINEL="$DATA_DIR/.mediastack-storage-ready"
SUDO_CALLS="$TMP_DIR/preflight-sudo-calls"
storage_ensure_nfs_common() { return 0; }
storage_mount_nfs() {
    mkdir -p "$DATA_DIR"
    return 0
}
findmnt() {
    case "$*" in
        *"-o SOURCE"*) echo "127.0.0.1:/exports/media" ;;
        *"-o FSTYPE"*) echo "nfs4" ;;
        *) return 0 ;;
    esac
}
sudo() {
    printf '%s\n' "$*" >>"$SUDO_CALLS"
    "$@"
}
# storage_configure_expected writes the expected source/fstype via common.sh's
# _env_write_kv; stub the writer as a no-op success so no real .env is touched
# (its real behavior is covered in tests/unit/common.sh).
_env_write_kv() { return 0; }
storage_preflight_nas
assert_eq "present" "$([[ -e "$STORAGE_SENTINEL" ]] && echo present || echo absent)" "NAS preflight: creates sentinel as installing user"
assert_eq "absent" "$([[ -s "$SUDO_CALLS" ]] && echo present || echo absent)" "NAS preflight: does not sudo-write sentinel on export"
unset -f storage_ensure_nfs_common storage_mount_nfs findmnt sudo _env_write_kv
unset DATA_DIR STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT STORAGE_NFS_OPTS STORAGE_SENTINEL SUDO_CALLS

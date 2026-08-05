# Owns: storage_* — storage mode predicates, NAS mount-identity/sentinel checks.
# Sourced by scripts/setup/storage.sh; depends on common.sh and
# DEFAULT_NFS_OPTS/MEDIASTACK_STORAGE_* being defined by the parent.

storage_mode() {
    printf '%s\n' "${STORAGE_MODE:-local}"
}

storage_is_nas() {
    [[ "$(storage_mode)" == "nas" ]]
}

storage_is_manual() {
    [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]
}

storage_data_services() {
    printf '%s\n' unpackerr qbittorrent sonarr radarr seerr jellyfin
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        printf '%s\n' bazarr
    fi
}

storage_log_info() { if declare -F log_info >/dev/null; then log_info "$*"; else echo "INFO: $*"; fi; }
storage_log_ok() { if declare -F log_ok >/dev/null; then log_ok "$*"; else echo "OK: $*"; fi; }
storage_log_warn() { if declare -F log_warn >/dev/null; then log_warn "$*"; else echo "WARN: $*"; fi; }
storage_log_err() { if declare -F log_error >/dev/null; then log_error "$*"; else echo "ERROR: $*"; fi; }
storage_log_skip() { if declare -F log_skip >/dev/null; then log_skip "$*"; else echo "SKIP: $*"; fi; }

storage_expected_source() {
    if [[ -n "${STORAGE_EXPECTED_SOURCE:-}" ]]; then
        printf '%s\n' "$STORAGE_EXPECTED_SOURCE"
    elif [[ -n "${STORAGE_NFS_HOST:-}" && -n "${STORAGE_NFS_EXPORT:-}" ]]; then
        printf '%s:%s\n' "$STORAGE_NFS_HOST" "$STORAGE_NFS_EXPORT"
    fi
}

storage_expected_fstype() {
    printf '%s\n' "${STORAGE_EXPECTED_FSTYPE:-nfs4}"
}

storage_sentinel_path() {
    printf '%s\n' "${STORAGE_SENTINEL:-${DATA_DIR:-/data}/.mediastack-storage-ready}"
}

storage_mountpoint() {
    printf '%s\n' "${STORAGE_MOUNTPOINT:-${DATA_DIR:-/data}}"
}

storage_path_is_under_mountpoint() {
    local path="$1" mountpoint="$2"
    python3 - "$path" "$mountpoint" <<'PY'
import os
import sys

path = os.path.abspath(os.path.normpath(sys.argv[1]))
mountpoint = os.path.abspath(os.path.normpath(sys.argv[2]))
try:
    ok = os.path.commonpath([path, mountpoint]) == mountpoint and path != mountpoint
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

storage_sentinel_is_under_mountpoint() {
    storage_path_is_under_mountpoint "$(storage_sentinel_path)" "$(storage_mountpoint)"
}

storage_findmnt_source() {
    findmnt -rn -M "$(storage_mountpoint)" -o SOURCE 2>/dev/null || true
}

storage_findmnt_fstype() {
    findmnt -rn -M "$(storage_mountpoint)" -o FSTYPE 2>/dev/null || true
}

storage_mount_matches() {
    local want_source want_fstype live_source live_fstype
    want_source="$(storage_expected_source)"
    want_fstype="$(storage_expected_fstype)"
    live_source="$(storage_findmnt_source)"
    live_fstype="$(storage_findmnt_fstype)"

    [[ -n "$live_source" && -n "$want_source" ]] || return 1
    [[ "$live_source" == "$want_source" ]] || return 1
    case "$want_fstype:$live_fstype" in
        nfs4:nfs | nfs4:nfs4 | nfs:nfs | nfs:nfs4) return 0 ;;
        *) [[ "$live_fstype" == "$want_fstype" ]] ;;
    esac
}

storage_sentinel_ok() {
    local sentinel
    sentinel="$(storage_sentinel_path)"
    storage_sentinel_is_under_mountpoint || return 1
    timeout 5 test -e "$sentinel" >/dev/null 2>&1
}

storage_nas_ok() {
    storage_is_nas || return 0
    storage_mount_matches && storage_sentinel_ok
}

# The mount watchdog/guard is opt-out per NAS install. Absent = enabled, so
# existing installs (no STORAGE_WATCHDOG key) keep their watchdog.
storage_watchdog_enabled() {
    [[ "${STORAGE_WATCHDOG:-true}" != "false" ]]
}

storage_mountpoint_has_mount() {
    findmnt -rn -M "$(storage_mountpoint)" >/dev/null 2>&1
}

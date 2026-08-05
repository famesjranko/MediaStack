# Owns: Stage 1 wizard NAS collection/preflight/retry/fallback scenarios
# (_stage1_preflight_nas_choice, _stage1_final_nas_preflight, etc).
# Sourced by tests/unit/storage.sh; inherits its preamble.

ui_log() { :; }
ui_choose() { printf '%s\n' "Use local storage instead"; }
storage_ensure_nfs_common() { return 0; }
storage_probe_nas() { return 1; }
findmnt() { return 1; }
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root"
_WIZ_DATA_DIR="$TMP_DIR/failed-nas-mount"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/media
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "local" "$_WIZ_STORAGE_MODE" "wizard NAS mount failure fallback: switches to local mode"
assert_eq "$TMP_DIR/local-root" "$_WIZ_DATA_DIR" "wizard NAS mount failure fallback: restores previous local data dir"
assert_eq "$TMP_DIR/local-root" "$_WIZ_STORAGE_MOUNTPOINT" "wizard NAS mount failure fallback: resets storage mountpoint"
assert_eq "" "$_WIZ_STORAGE_NFS_HOST" "wizard NAS mount failure fallback: clears NFS host"
assert_eq "" "$_WIZ_STORAGE_NFS_EXPORT" "wizard NAS mount failure fallback: clears NFS export"
assert_eq "$TMP_DIR/local-root/.mediastack-storage-ready" "$_WIZ_STORAGE_SENTINEL" "wizard NAS mount failure fallback: resets local sentinel"
unset -f ui_log ui_choose storage_ensure_nfs_common storage_probe_nas findmnt

ui_log() { :; }
ui_choose() { printf '%s\n' "Use local storage instead"; }
storage_ensure_nfs_common() { return 1; }
findmnt() { return 1; }
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-2"
_WIZ_DATA_DIR="$TMP_DIR/nas-without-client"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/media
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "local" "$_WIZ_STORAGE_MODE" "wizard nfs-common failure fallback: switches to local mode"
assert_eq "$TMP_DIR/local-root-2" "$_WIZ_DATA_DIR" "wizard nfs-common failure fallback: restores previous local data dir"
assert_eq "" "$_WIZ_STORAGE_NFS_HOST" "wizard nfs-common failure fallback: clears NFS host"
assert_eq "$TMP_DIR/local-root-2/.mediastack-storage-ready" "$_WIZ_STORAGE_SENTINEL" "wizard nfs-common failure fallback: resets local sentinel"
unset -f ui_log ui_choose storage_ensure_nfs_common findmnt

ui_log() { :; }
ui_choose() { printf '%s\n' "Retry with the same settings"; }
storage_ensure_nfs_common() { return 0; }
storage_probe_nas() {
    MOUNT_ATTEMPTS=$((MOUNT_ATTEMPTS + 1))
    [[ "$MOUNT_ATTEMPTS" -ge 2 ]] || return 1
    _STORAGE_PROBE_CLASS=empty
}
findmnt() { return 1; }
MOUNT_ATTEMPTS=0
mkdir -p "$TMP_DIR/retry-nas"
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-3"
_WIZ_DATA_DIR="$TMP_DIR/retry-nas"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/media
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "2" "$MOUNT_ATTEMPTS" "wizard NAS mount failure: retry with same settings retries mount"
assert_eq "nas" "$_WIZ_STORAGE_MODE" "wizard NAS mount retry: keeps NAS mode after successful retry"
assert_eq "$TMP_DIR/retry-nas" "$_WIZ_DATA_DIR" "wizard NAS mount retry: keeps selected NAS mountpoint"
unset -f ui_log ui_choose storage_ensure_nfs_common storage_probe_nas findmnt
unset MOUNT_ATTEMPTS

ui_log() { :; }
ui_choose() { printf '%s\n' "Edit NAS settings and retry"; }
ui_input_validated() {
    case "${1:-}" in
        "Local mountpoint for NAS storage") printf '%s\n' "$TMP_DIR/edited-nas" ;;
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)") printf '%s\n' "192.0.2.10" ;;
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)") printf '%s\n' "/exports/edited" ;;
        "NFS mount options") printf '%s\n' "vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec" ;;
        "NAS sentinel file") printf '%s\n' "${2:-}" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
storage_ensure_nfs_common() { return 0; }
storage_probe_nas() {
    MOUNT_ATTEMPTS=$((MOUNT_ATTEMPTS + 1))
    [[ "$MOUNT_ATTEMPTS" -ge 2 ]] || return 1
    _STORAGE_PROBE_CLASS=empty
}
findmnt() { return 1; }
MOUNT_ATTEMPTS=0
mkdir -p "$TMP_DIR/initial-nas" "$TMP_DIR/edited-nas"
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-4"
_WIZ_DATA_DIR="$TMP_DIR/initial-nas"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/old
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "2" "$MOUNT_ATTEMPTS" "wizard NAS mount failure: edit settings retries mount"
assert_eq "$TMP_DIR/edited-nas" "$_WIZ_DATA_DIR" "wizard NAS edit retry: updates mountpoint"
assert_eq "192.0.2.10" "$_WIZ_STORAGE_NFS_HOST" "wizard NAS edit retry: updates host"
assert_eq "/exports/edited" "$_WIZ_STORAGE_NFS_EXPORT" "wizard NAS edit retry: updates export"
assert_eq "$TMP_DIR/edited-nas/.mediastack-storage-ready" "$_WIZ_STORAGE_SENTINEL" "wizard NAS edit retry: resets sentinel default to edited mountpoint"
unset -f ui_log ui_choose ui_input_validated storage_ensure_nfs_common storage_probe_nas findmnt
unset MOUNT_ATTEMPTS

ui_log() { :; }
ui_choose() { printf '%s\n' "Retry installing NAS support"; }
storage_ensure_nfs_common() {
    NFS_COMMON_ATTEMPTS=$((NFS_COMMON_ATTEMPTS + 1))
    [[ "$NFS_COMMON_ATTEMPTS" -ge 2 ]]
}
storage_probe_nas() {
    _STORAGE_PROBE_CLASS=empty
    return 0
}
findmnt() { return 1; }
NFS_COMMON_ATTEMPTS=0
mkdir -p "$TMP_DIR/nfs-common-retry"
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-5"
_WIZ_DATA_DIR="$TMP_DIR/nfs-common-retry"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/media
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "2" "$NFS_COMMON_ATTEMPTS" "wizard nfs-common failure: retry installing NAS support retries dependency check"
assert_eq "nas" "$_WIZ_STORAGE_MODE" "wizard nfs-common retry: keeps NAS mode after successful retry"
unset -f ui_log ui_choose storage_ensure_nfs_common storage_probe_nas findmnt
unset NFS_COMMON_ATTEMPTS

ui_log() { :; }
ui_choose() {
    RESOLVE_PROMPTS=$((RESOLVE_PROMPTS + 1))
    printf '%s\n' "Use a new mediastack/ subfolder on this NAS (recommended)"
}
storage_ensure_nfs_common() { return 0; }
storage_probe_nas() {
    _STORAGE_PROBE_CLASS="conflict:media"
    return 0
}
storage_classify_data_root() { printf '%s\n' "conflict:media"; }
findmnt() { return 1; }
RESOLVE_PROMPTS=0
mkdir -p "$TMP_DIR/manual-conflict-nas"
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-6"
_WIZ_DATA_DIR="$TMP_DIR/manual-conflict-nas"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_APP_WIRING=manual
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/manual
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "0" "$RESOLVE_PROMPTS" "wizard manual NAS: nonstandard share does not force managed-layout resolver"
assert_eq "$TMP_DIR/manual-conflict-nas" "$_WIZ_DATA_DIR" "wizard manual NAS: keeps selected existing NAS root"
assert_eq "manual" "$_WIZ_STORAGE_APP_WIRING" "wizard manual NAS: keeps manual app wiring"
unset -f ui_log ui_choose storage_ensure_nfs_common storage_probe_nas storage_classify_data_root findmnt
unset RESOLVE_PROMPTS

ui_log() { :; }
log_info() { :; }
ui_choose() { printf '%s\n' "Use local storage instead"; }
storage_ensure_nfs_common() { return 0; }
storage_probe_nas() {
    STAGE1_REPAIR_SOURCE="127.0.0.1:/exports/media"
    STAGE1_REPAIR_FSTYPE="nfs4"
    _STORAGE_PROBE_CLASS="nonempty"
    return 0
}
storage_classify_data_root() { printf '%s\n' "nonempty"; }
findmnt() {
    case "$*" in
        *"-o SOURCE"*) [[ -n "$STAGE1_REPAIR_SOURCE" ]] && printf '%s\n' "$STAGE1_REPAIR_SOURCE" ;;
        *"-o FSTYPE"*) [[ -n "$STAGE1_REPAIR_FSTYPE" ]] && printf '%s\n' "$STAGE1_REPAIR_FSTYPE" ;;
        *) [[ -n "$STAGE1_REPAIR_SOURCE" ]] ;;
    esac
}
sudo() {
    printf '%s\n' "sudo $*" >>"$STAGE1_REPAIR_SUDO_LOG"
    case "${1:-}" in
        umount)
            STAGE1_REPAIR_SOURCE=""
            STAGE1_REPAIR_FSTYPE=""
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
STAGE1_REPAIR_SUDO_LOG="$TMP_DIR/stage1-repair-cleanup-sudo.log"
STAGE1_REPAIR_SOURCE="192.0.2.99:/exports/old"
STAGE1_REPAIR_FSTYPE="nfs4"
STORAGE_EXPECTED_SOURCE="$STAGE1_REPAIR_SOURCE"
STORAGE_EXPECTED_FSTYPE="$STAGE1_REPAIR_FSTYPE"
_WIZ_PREV_DATA_DIR="$TMP_DIR/local-root-7"
_WIZ_DATA_DIR="$TMP_DIR/repaired-conflict-nas"
_WIZ_STORAGE_MODE=nas
_WIZ_STORAGE_APP_WIRING=managed
_WIZ_STORAGE_PROTOCOL=nfs
_WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
_WIZ_STORAGE_NFS_HOST=127.0.0.1
_WIZ_STORAGE_NFS_EXPORT=/exports/media
_WIZ_STORAGE_NFS_OPTS=vers=4.2
_WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
_stage1_preflight_nas_choice
assert_eq "$TMP_DIR/local-root-7" "$_WIZ_DATA_DIR" "wizard repaired NAS conflict fallback: switches to previous local data dir"
assert_eq "local" "$_WIZ_STORAGE_MODE" "wizard repaired NAS conflict fallback: resets storage mode"
unset -f ui_log log_info ui_choose storage_ensure_nfs_common storage_probe_nas storage_classify_data_root findmnt sudo
unset STAGE1_REPAIR_SUDO_LOG STAGE1_REPAIR_SOURCE STAGE1_REPAIR_FSTYPE STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE
source "$REPO_ROOT/scripts/setup/storage.sh"

env_val_from() {
    local env_path="$1"
    local key="$2"
    python3 - "$env_path" "$key" <<'PY'
import pathlib
import shlex
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for raw in env_path.read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    found, value = raw.split("=", 1)
    if found == key:
        try:
            parsed = shlex.split(value, posix=True)
            value = parsed[0] if parsed else ""
        except ValueError:
            pass
        print(value, end="")
        break
PY
}

seed_stage1_env_vars() {
    SCRIPT_DIR="$TMP_DIR/$1"
    mkdir -p "$SCRIPT_DIR/config/ddns-updater"
    log_ok() { :; }
    log_warn() { :; }
    _ENV_TZ="Etc/UTC"
    _ENV_PUID="$(id -u)"
    _ENV_PGID="$(id -g)"
    _ENV_HOST_ADDRESS="192.168.1.10"
    _WIZ_TZ="Etc/UTC"
    _WIZ_DATA_DIR="$TMP_DIR/final-nas"
    _WIZ_STORAGE_MODE="nas"
    _WIZ_STORAGE_PROTOCOL="nfs"
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    _WIZ_STORAGE_NFS_HOST="127.0.0.1"
    _WIZ_STORAGE_NFS_EXPORT="/exports/media"
    _WIZ_STORAGE_NFS_OPTS="vers=4.2"
    _WIZ_STORAGE_SENTINEL="$_WIZ_DATA_DIR/.mediastack-storage-ready"
    _WIZ_PREV_DATA_DIR="$TMP_DIR/final-local"
    _WIZ_ADMIN_USER="admin"
    _WIZ_ADMIN_PW="GeneratedPassword123"
    _WIZ_ADMIN_EMAIL="admin@storage.test"
    _WIZ_DOMAIN=""
    _WIZ_WG_HOST=""
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR="192.168.1.0/24"
    _WIZ_WG_SERVER_LAN_IP="192.168.1.10"
    _WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD=""
    _WIZ_TORRENT_PORT="6881"
    _WIZ_DL_LIMIT="0"
    _WIZ_UL_LIMIT="0"
    _WIZ_BAZARR_ENABLED="false"
    _WIZ_SMB_ENABLED="false"
    _WIZ_SMB_SHARE_SCOPE="data"
    unset STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE
    mkdir -p "$_WIZ_DATA_DIR" "$_WIZ_PREV_DATA_DIR"
    write_env >/dev/null
    _stage1_source_env
}

ui_log() { :; }
ui_choose() { printf '%s\n' "Retry NAS check"; }
storage_preflight_nas() {
    FINAL_PREFLIGHT_ATTEMPTS=$((FINAL_PREFLIGHT_ATTEMPTS + 1))
    [[ "$FINAL_PREFLIGHT_ATTEMPTS" -ge 2 ]]
}
FINAL_PREFLIGHT_ATTEMPTS=0
seed_stage1_env_vars "final-preflight-retry"
_stage1_final_nas_preflight
assert_eq "2" "$FINAL_PREFLIGHT_ATTEMPTS" "wizard final NAS preflight: retry NAS check retries guard"
assert_eq "nas" "$STORAGE_MODE" "wizard final NAS preflight: successful retry keeps NAS mode"
unset -f ui_log ui_choose storage_preflight_nas
unset FINAL_PREFLIGHT_ATTEMPTS

ui_log() { :; }
ui_choose() { printf '%s\n' "Use local storage instead"; }
storage_preflight_nas() { return 1; }
seed_stage1_env_vars "final-preflight-local"
{
    printf '%s\n' "STORAGE_EXPECTED_SOURCE='127.0.0.1:/exports/media'"
    printf '%s\n' "STORAGE_EXPECTED_FSTYPE='nfs4'"
} >>"$SCRIPT_DIR/.env"
_stage1_source_env
_stage1_final_nas_preflight
assert_eq "local" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_MODE)" "wizard final NAS preflight: local fallback rewrites storage mode"
assert_eq "$TMP_DIR/final-local" "$(env_val_from "$SCRIPT_DIR/.env" DATA_DIR)" "wizard final NAS preflight: local fallback rewrites data dir"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_NFS_HOST)" "wizard final NAS preflight: local fallback clears NFS host"
assert_eq "$TMP_DIR/final-local/.mediastack-storage-ready" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_SENTINEL)" "wizard final NAS preflight: local fallback rewrites sentinel"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_EXPECTED_SOURCE)" "wizard final NAS preflight: local fallback clears expected NAS source"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_EXPECTED_FSTYPE)" "wizard final NAS preflight: local fallback clears expected NAS fstype"
unset -f ui_log ui_choose storage_preflight_nas

ui_log() { :; }
ui_choose() {
    case "${1:-}" in
        "NAS storage check failed."*) printf '%s\n' "Edit NAS settings and retry" ;;
        *) printf '%s\n' "Edit NAS settings and retry" ;;
    esac
}
ui_input_validated() {
    case "${1:-}" in
        "Local mountpoint for NAS storage") printf '%s\n' "$TMP_DIR/final-edited-nas" ;;
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)") printf '%s\n' "192.0.2.10" ;;
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)") printf '%s\n' "/exports/edited" ;;
        "NFS mount options") printf '%s\n' "vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec" ;;
        "NAS sentinel file") printf '%s\n' "${2:-}" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
storage_preflight_nas() {
    FINAL_PREFLIGHT_ATTEMPTS=$((FINAL_PREFLIGHT_ATTEMPTS + 1))
    [[ "$FINAL_PREFLIGHT_ATTEMPTS" -ge 2 ]]
}
storage_ensure_nfs_common() { return 0; }
# The "Edit" action runs _stage1_preflight_nas_choice, which calls storage_probe_nas
# (the real one was re-armed by the mid-file re-source); stub it so the re-verify
# passes without a real network probe.
storage_probe_nas() {
    _STORAGE_PROBE_CLASS=empty
    return 0
}
findmnt() { return 1; }
FINAL_PREFLIGHT_ATTEMPTS=0
mkdir -p "$TMP_DIR/final-edited-nas"
seed_stage1_env_vars "final-preflight-edit"
_stage1_final_nas_preflight
assert_eq "2" "$FINAL_PREFLIGHT_ATTEMPTS" "wizard final NAS preflight: edit settings retries guard"
assert_eq "nas" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_MODE)" "wizard final NAS preflight: edit keeps NAS mode"
assert_eq "$TMP_DIR/final-edited-nas" "$(env_val_from "$SCRIPT_DIR/.env" DATA_DIR)" "wizard final NAS preflight: edit rewrites data dir"
assert_eq "192.0.2.10" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_NFS_HOST)" "wizard final NAS preflight: edit rewrites NFS host"
assert_eq "/exports/edited" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_NFS_EXPORT)" "wizard final NAS preflight: edit rewrites NFS export"
unset -f ui_log ui_choose ui_input_validated storage_preflight_nas storage_ensure_nfs_common storage_probe_nas findmnt
unset FINAL_PREFLIGHT_ATTEMPTS

ui_log() { :; }
ui_choose() {
    case "${1:-}" in
        "NAS storage check failed."*) printf '%s\n' "Advanced manual storage" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
ui_confirm() { return 0; }
storage_preflight_nas() {
    FINAL_PREFLIGHT_ATTEMPTS=$((FINAL_PREFLIGHT_ATTEMPTS + 1))
    [[ "$FINAL_PREFLIGHT_ATTEMPTS" -ge 2 ]]
}
storage_ensure_nfs_common() { return 0; }
# ui_confirm=yes routes through _stage1_collect_manual_storage ->
# _stage1_preflight_nas_choice, which calls storage_probe_nas; stub it.
storage_probe_nas() {
    _STORAGE_PROBE_CLASS=empty
    return 0
}
storage_classify_data_root() { printf '%s\n' "empty"; }
findmnt() { return 1; }
FINAL_PREFLIGHT_ATTEMPTS=0
seed_stage1_env_vars "final-preflight-manual-guard"
_stage1_final_nas_preflight
assert_eq "2" "$FINAL_PREFLIGHT_ATTEMPTS" "wizard final NAS preflight: manual NAS guard reruns final guard before install"
assert_eq "nas" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_MODE)" "wizard final NAS preflight: manual guard keeps NAS mode"
assert_eq "manual" "$(env_val_from "$SCRIPT_DIR/.env" STORAGE_APP_WIRING)" "wizard final NAS preflight: manual guard writes manual app wiring"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" UNPACKERR_TORRENT_PATHS)" "wizard final NAS preflight: manual guard clears Unpackerr managed path"
unset -f ui_log ui_choose ui_confirm storage_preflight_nas storage_ensure_nfs_common storage_probe_nas storage_classify_data_root findmnt
unset FINAL_PREFLIGHT_ATTEMPTS

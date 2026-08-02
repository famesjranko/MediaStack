#!/usr/bin/env bash
# tests/unit/storage.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="storage"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/storage.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/setup/stages/stage1.sh"
source "$REPO_ROOT/scripts/setup/env_gen.sh"

set +e
set +u

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert_eq "empty" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: empty root"

mkdir -p "$TMP_DIR/media/movies" "$TMP_DIR/torrents/tv"
assert_eq "mediastack" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: existing MediaStack layout"

rm -rf "${TMP_DIR:?}"/*
mkdir -p "$TMP_DIR/Photos"
assert_eq "nonempty" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: unrelated non-empty root"

rm -rf "${TMP_DIR:?}"/*
touch "$TMP_DIR/media"
assert_eq "conflict:media" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: media file conflict"

rm -rf "${TMP_DIR:?}"/*
touch "$TMP_DIR/torrents"
assert_eq "conflict:torrents" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: torrents file conflict"

DATA_DIR="$TMP_DIR"
STORAGE_MODE=nas
STORAGE_MOUNTPOINT="$TMP_DIR"
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
STORAGE_EXPECTED_FSTYPE="nfs4"
STORAGE_SENTINEL="$TMP_DIR/.mediastack-storage-ready"
touch "$STORAGE_SENTINEL"

findmnt() {
    case "$*" in
        *"-o SOURCE"*) echo "192.0.2.10:/exports/mediastack-fixture" ;;
        *"-o FSTYPE"*) echo "nfs" ;;
        *) return 0 ;;
    esac
}

if storage_nas_ok; then
    pass "storage_nas_ok: accepts expected source and nfs/nfs4 compatibility"
else
    fail "storage_nas_ok: accepts expected source and nfs/nfs4 compatibility"
fi

STORAGE_EXPECTED_SOURCE="192.0.2.11:/exports/other"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects wrong source"
else
    pass "storage_nas_ok: rejects wrong source"
fi

STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
rm -f "$STORAGE_SENTINEL"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects missing sentinel"
else
    pass "storage_nas_ok: rejects missing sentinel"
fi

STORAGE_SENTINEL="$TMP_DIR-outside-sentinel"
touch "$STORAGE_SENTINEL"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects sentinel outside mountpoint"
else
    pass "storage_nas_ok: rejects sentinel outside mountpoint"
fi

# --- STORAGE_WATCHDOG opt-out gate (findmnt still stubbed; sentinel is outside
# the mountpoint from the block above, so storage_nas_ok fails here) ---
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
unset STORAGE_WATCHDOG
if storage_watchdog_enabled; then
    pass "storage_watchdog_enabled: absent flag defaults to enabled"
else
    fail "storage_watchdog_enabled: absent flag defaults to enabled"
fi

STORAGE_WATCHDOG=false
if storage_watchdog_enabled; then
    fail "storage_watchdog_enabled: false disables"
else
    pass "storage_watchdog_enabled: false disables"
fi

if storage_guard_before_start 2>/dev/null; then
    pass "storage_guard_before_start: watchdog off -> allows start despite failing nas_ok"
else
    fail "storage_guard_before_start: watchdog off -> allows start despite failing nas_ok"
fi

STORAGE_WATCHDOG=true
if storage_guard_before_start 2>/dev/null; then
    fail "storage_guard_before_start: watchdog on -> refuses start when nas_ok fails"
else
    pass "storage_guard_before_start: watchdog on -> refuses start when nas_ok fails"
fi
unset STORAGE_WATCHDOG

unset -f findmnt

DATA_DIR="$TMP_DIR/mount-repair"
STORAGE_MODE=nas
STORAGE_MOUNTPOINT="$DATA_DIR"
STORAGE_NFS_HOST=192.0.2.10
STORAGE_NFS_EXPORT=/exports/media
STORAGE_NFS_OPTS=vers=4.2
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/media"
STORAGE_EXPECTED_FSTYPE=nfs4
STORAGE_SENTINEL="$DATA_DIR/.mediastack-storage-ready"
mkdir -p "$DATA_DIR"
MOUNT_REPAIR_CALLS="$TMP_DIR/mount-repair-calls"
MOUNT_REPAIR_CONFIRM_PROMPTS=0
MOUNT_REPAIR_SOURCE="192.0.2.99:/exports/old"
MOUNT_REPAIR_FSTYPE=nfs4
findmnt() {
    case "$*" in
        *"-o SOURCE"*) [[ -n "$MOUNT_REPAIR_SOURCE" ]] && printf '%s\n' "$MOUNT_REPAIR_SOURCE" ;;
        *"-o FSTYPE"*) [[ -n "$MOUNT_REPAIR_FSTYPE" ]] && printf '%s\n' "$MOUNT_REPAIR_FSTYPE" ;;
        *) [[ -n "$MOUNT_REPAIR_SOURCE" ]] ;;
    esac
}
sudo() {
    printf '%s\n' "sudo $*" >>"$MOUNT_REPAIR_CALLS"
    case "${1:-}" in
        umount)
            MOUNT_REPAIR_SOURCE=""
            MOUNT_REPAIR_FSTYPE=""
            return 0
            ;;
        mkdir)
            command mkdir "$2" "$3"
            ;;
        mount)
            MOUNT_REPAIR_SOURCE="$6"
            MOUNT_REPAIR_FSTYPE="$3"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
ui_confirm() {
    MOUNT_REPAIR_CONFIRM_PROMPTS=$((MOUNT_REPAIR_CONFIRM_PROMPTS + 1))
    return 0
}
log_warn() { :; }
log_info() { :; }
log_ok() { :; }
log_error() { :; }
if storage_mount_nfs; then
    pass "storage_mount_nfs: repairs mismatched live mount"
else
    fail "storage_mount_nfs: repairs mismatched live mount"
fi
assert_eq "192.0.2.10:/exports/media" "$MOUNT_REPAIR_SOURCE" "storage_mount_nfs: selected NAS source mounted after repair"
assert_eq "1" "$MOUNT_REPAIR_CONFIRM_PROMPTS" "storage_mount_nfs: asks before detaching mismatched mount when UI is available"
case "$(cat "$MOUNT_REPAIR_CALLS")" in
    *"sudo umount -l $DATA_DIR"*"sudo mount -t nfs4"*)
        pass "storage_mount_nfs: detaches mismatched mount before mounting NAS"
        ;;
    *)
        fail "storage_mount_nfs: detaches mismatched mount before mounting NAS" "$(cat "$MOUNT_REPAIR_CALLS")"
        ;;
esac

: >"$MOUNT_REPAIR_CALLS"
MOUNT_REPAIR_CONFIRM_PROMPTS=0
MOUNT_REPAIR_SOURCE="192.0.2.99:/exports/old"
MOUNT_REPAIR_FSTYPE=nfs4
ui_confirm() {
    MOUNT_REPAIR_CONFIRM_PROMPTS=$((MOUNT_REPAIR_CONFIRM_PROMPTS + 1))
    return 1
}
if storage_mount_nfs; then
    fail "storage_mount_nfs: declined mismatched mount repair aborts"
else
    pass "storage_mount_nfs: declined mismatched mount repair aborts"
fi
case "$(cat "$MOUNT_REPAIR_CALLS")" in
    *"sudo umount"* | *"sudo mount"*)
        fail "storage_mount_nfs: declined repair leaves existing mount untouched" "$(cat "$MOUNT_REPAIR_CALLS")"
        ;;
    *)
        pass "storage_mount_nfs: declined repair leaves existing mount untouched"
        ;;
esac
assert_eq "1" "$MOUNT_REPAIR_CONFIRM_PROMPTS" "storage_mount_nfs: declined repair still prompted once"
unset -f findmnt sudo ui_confirm log_warn log_info log_ok log_error
unset DATA_DIR STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT STORAGE_NFS_OPTS STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE STORAGE_SENTINEL
unset MOUNT_REPAIR_CALLS MOUNT_REPAIR_CONFIRM_PROMPTS MOUNT_REPAIR_SOURCE MOUNT_REPAIR_FSTYPE

# --- storage_probe_nas: non-destructive verification (never mounts the real
#     mountpoint; temp-mounts, checks, classifies, unmounts) ---
ui_spin() {
    shift
    "$@"
} # run the wrapped command, drop the label
log_ok() { :; }
log_info() { :; }
log_error() { :; }
log_warn() { :; }
STORAGE_NFS_HOST=192.0.2.10
STORAGE_NFS_EXPORT=/exports/mediastack
STORAGE_NFS_OPTS="vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"
PROBE_NC_RC=0 PROBE_MOUNT_RC=0
nc() { return "$PROBE_NC_RC"; }
sudo() { case "$1" in mount) return "$PROBE_MOUNT_RC" ;; *) return 0 ;; esac }

# probe_opts must fail-fast: no hard, forced soft + short timeo/retrans.
probe_opts_out="$(storage_probe_opts "$STORAGE_NFS_OPTS")"
case "$probe_opts_out" in
    *hard*) fail "storage_probe_opts: strips hard from probe options" "$probe_opts_out" ;;
    *soft,timeo=50,retrans=2) pass "storage_probe_opts: forces fail-fast soft mount" ;;
    *) fail "storage_probe_opts: forces fail-fast soft mount" "$probe_opts_out" ;;
esac

PROBE_NC_RC=0 PROBE_MOUNT_RC=0
if storage_probe_nas && [[ "$_STORAGE_PROBE_CLASS" == "empty" ]]; then
    pass "storage_probe_nas: all checks green returns 0 and classifies the share"
else
    fail "storage_probe_nas: all checks green returns 0 and classifies the share"
fi

PROBE_NC_RC=1 PROBE_MOUNT_RC=0
if storage_probe_nas; then
    fail "storage_probe_nas: unreachable NAS fails the probe"
else
    pass "storage_probe_nas: unreachable NAS fails the probe"
fi

PROBE_NC_RC=0 PROBE_MOUNT_RC=1
if storage_probe_nas; then
    fail "storage_probe_nas: unmountable export fails the probe"
else
    pass "storage_probe_nas: unmountable export fails the probe"
fi

unset -f ui_spin nc sudo log_ok log_info log_error log_warn
unset STORAGE_NFS_HOST STORAGE_NFS_EXPORT STORAGE_NFS_OPTS PROBE_NC_RC PROBE_MOUNT_RC _STORAGE_PROBE_CLASS

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
BAZARR_ENABLED=true
assert_contains "$(storage_data_services)" "bazarr" "storage services: includes Bazarr when subtitles are enabled"
unset BAZARR_ENABLED

SCRIPT_DIR="$TMP_DIR/preflight-root"
mkdir -p "$SCRIPT_DIR"
cat >"$SCRIPT_DIR/.env" <<'ENV'
STORAGE_MODE=nas
ENV
DATA_DIR="$TMP_DIR/preflight-nas"
STORAGE_MODE=nas
STORAGE_MOUNTPOINT="$DATA_DIR"
STORAGE_NFS_HOST=127.0.0.1
STORAGE_NFS_EXPORT=/exports/media
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
source "$REPO_ROOT/scripts/setup/storage.sh"

unit_content="$(storage_watchdog_unit_content mediaadmin mediaadmin /home/mediaadmin/MediaStack/scripts/storage-watchdog.sh)"
assert_contains "$unit_content" "User=mediaadmin" "watchdog unit: runs as installing user"
assert_contains "$unit_content" "Group=mediaadmin" "watchdog unit: uses installing user's primary group"
assert_contains "$unit_content" "ExecStart=/home/mediaadmin/MediaStack/scripts/storage-watchdog.sh" "watchdog unit: executes repo script without root privileges"
sudoers_content="$(storage_watchdog_sudoers_content mediaadmin /usr/local/libexec/mediastack/storage-mount-helper)"
assert_contains "$sudoers_content" "NOPASSWD: /usr/local/libexec/mediastack/storage-mount-helper repair" "watchdog sudoers: only permits the root-owned mount helper"
helper_content="$(storage_mount_helper_content)"
case "$helper_content" in
    *'source "$SCRIPT_DIR/.env"'* | *'docker compose'*)
        fail "watchdog helper: does not source repo files or run Docker as root"
        ;;
    *)
        pass "watchdog helper: does not source repo files or run Docker as root"
        ;;
esac
assert_contains "$helper_content" 'CONFIG_FILE="/etc/mediastack/storage.env"' "watchdog helper: reads root-owned storage config"
case "$helper_content" in
    *'touch "$sentinel"'* | *'mkdir -p "$(dirname "$sentinel")"'*)
        fail "watchdog helper: does not root-write sentinel on NAS export"
        ;;
    *)
        pass "watchdog helper: does not root-write sentinel on NAS export"
        ;;
esac

# --- Disabled watchdog: install is a no-op that tears down any prior unit ---
WATCHDOG_INSTALL_PAUSED=false
storage_pause_watchdog_for_install() {
    WATCHDOG_INSTALL_PAUSED=true
    return 0
}
STORAGE_MODE=nas STORAGE_WATCHDOG=false
if storage_install_watchdog >/dev/null 2>&1 && $WATCHDOG_INSTALL_PAUSED; then
    pass "storage_install_watchdog: disabled flag skips install and tears down stale unit"
else
    fail "storage_install_watchdog: disabled flag skips install and tears down stale unit"
fi
unset -f storage_pause_watchdog_for_install
unset STORAGE_MODE STORAGE_WATCHDOG
source "$REPO_ROOT/scripts/setup/storage.sh"

WATCHDOG_SYSTEMCTL_LOG="$TMP_DIR/watchdog-systemctl.log"
WATCHDOG_SYSTEMCTL_STATE=inactive
WATCHDOG_SYSTEMCTL_QUERY_FAIL=false
systemctl() {
    printf '%s\n' "$*" >>"$WATCHDOG_SYSTEMCTL_LOG"
    if [[ "$*" == "is-active mediastack-storage-watchdog.service" ]]; then
        if $WATCHDOG_SYSTEMCTL_QUERY_FAIL; then
            return 1
        fi
        printf '%s\n' "$WATCHDOG_SYSTEMCTL_STATE"
        case "$WATCHDOG_SYSTEMCTL_STATE" in
            active | activating | reloading | deactivating) return 0 ;;
            inactive | failed | unknown) return 3 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}
sudo() {
    "$@"
}
STORAGE_MODE=nas
storage_pause_watchdog_for_install
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "stop mediastack-storage-watchdog.service" "watchdog install pause: stops existing service before Stage 1 stack stop"
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "disable mediastack-storage-watchdog.service" "watchdog install pause: disables existing service until stack starts"
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "is-active mediastack-storage-watchdog.service" "watchdog install pause: verifies service is inactive after stop"
: >"$WATCHDOG_SYSTEMCTL_LOG"
STORAGE_MODE=local
STORAGE_APP_WIRING=manual
storage_pause_watchdog_for_install
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "stop mediastack-storage-watchdog.service" "watchdog install pause: local/manual fallback still stops stale watchdog"
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "disable mediastack-storage-watchdog.service" "watchdog install pause: local/manual fallback still disables stale watchdog"
: >"$WATCHDOG_SYSTEMCTL_LOG"
WATCHDOG_SYSTEMCTL_STATE=active
if storage_pause_watchdog_for_install; then
    fail "watchdog install pause: active-after-stop watchdog aborts setup"
else
    pass "watchdog install pause: active-after-stop watchdog aborts setup"
fi
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "is-active mediastack-storage-watchdog.service" "watchdog install pause: active-after-stop path verifies live state"
: >"$WATCHDOG_SYSTEMCTL_LOG"
WATCHDOG_SYSTEMCTL_STATE=
WATCHDOG_SYSTEMCTL_QUERY_FAIL=true
if storage_pause_watchdog_for_install; then
    fail "watchdog install pause: unverified systemctl state aborts setup"
else
    pass "watchdog install pause: unverified systemctl state aborts setup"
fi
assert_contains "$(cat "$WATCHDOG_SYSTEMCTL_LOG")" "is-active mediastack-storage-watchdog.service" "watchdog install pause: query-failure path attempts verification"
WATCHDOG_SYSTEMCTL_STATE=inactive
WATCHDOG_SYSTEMCTL_QUERY_FAIL=false
unset -f systemctl sudo
unset STORAGE_MODE STORAGE_APP_WIRING WATCHDOG_SYSTEMCTL_LOG WATCHDOG_SYSTEMCTL_STATE WATCHDOG_SYSTEMCTL_QUERY_FAIL

WATCHDOG_DOCKER_LOG="$TMP_DIR/watchdog-docker.log"
WATCHDOG_FAKEBIN="$TMP_DIR/watchdog-fakebin"
mkdir -p "$WATCHDOG_FAKEBIN"
cat >"$WATCHDOG_FAKEBIN/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "$WATCHDOG_DOCKER_LOG"
exit 0
EOF
chmod +x "$WATCHDOG_FAKEBIN/docker"
MEDIASTACK_WATCHDOG_SOURCE_ONLY=1
STORAGE_MODE=nas
STORAGE_MOUNTPOINT="$TMP_DIR"
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
STORAGE_EXPECTED_FSTYPE="nfs4"
STORAGE_SENTINEL="$TMP_DIR/.mediastack-storage-ready"
BAZARR_ENABLED=false
PATH="$WATCHDOG_FAKEBIN:$PATH"
source "$REPO_ROOT/scripts/storage-watchdog.sh"

findmnt() {
    case "$*" in
        *"-o SOURCE"*) echo "192.0.2.10:/exports/mediastack-fixture" ;;
        *"-o FSTYPE"*) echo "nfs" ;;
        *) return 0 ;;
    esac
}
watchdog_sentinel_probe() {
    local end=$((SECONDS + 10))
    while ((SECONDS < end)); do
        :
    done
}
STORAGE_SENTINEL_PROBE_TIMEOUT=1
STORAGE_SENTINEL_PROBE_INTERVAL=0.1
watchdog_probe_started="$(date +%s)"
if watchdog_storage_nas_ok; then
    fail "watchdog sentinel: stale probe is treated as unavailable"
else
    watchdog_probe_elapsed=$(($(date +%s) - watchdog_probe_started))
    if ((watchdog_probe_elapsed <= 2)); then
        pass "watchdog sentinel: stale probe times out without blocking main loop"
    else
        fail "watchdog sentinel: stale probe times out without blocking main loop" "elapsed=${watchdog_probe_elapsed}s"
    fi
fi
watchdog_sentinel_probe() {
    local sentinel="$1"
    [[ -e "$sentinel" ]]
}
unset -f findmnt
unset STORAGE_SENTINEL_PROBE_TIMEOUT STORAGE_SENTINEL_PROBE_INTERVAL watchdog_probe_started watchdog_probe_elapsed

rm -f "$WATCHDOG_DOCKER_LOG"
start_managed_services
assert_contains "$(cat "$WATCHDOG_DOCKER_LOG")" "docker compose up -d jellyfin" "watchdog recovery: starts known NAS service set from live state"
assert_contains "$(cat "$WATCHDOG_DOCKER_LOG")" "docker compose up -d qbittorrent" "watchdog recovery: starts qBittorrent from known NAS service set"
case "$(cat "$WATCHDOG_DOCKER_LOG")" in
    *"docker compose up -d bazarr"*) fail "watchdog recovery: does not start disabled Bazarr" ;;
    *) pass "watchdog recovery: does not start disabled Bazarr" ;;
esac
PATH="${PATH#"$WATCHDOG_FAKEBIN:"}"
unset -f log compose_running service_is_running protected_running_count stop_managed_services start_managed_services repair_mount_if_needed watchdog_main
unset WATCHDOG_DOCKER_LOG WATCHDOG_FAKEBIN MEDIASTACK_WATCHDOG_SOURCE_ONLY STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE STORAGE_SENTINEL BAZARR_ENABLED

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

ui_log() {
    printf '%s %s\n' "${1:-}" "${*:2}" >>"$NAS_EXPORT_INFO_LOG"
}
# The export-path explanation moved from a ui_log line into the intro ui_box.
ui_box() { printf '%s\n' "$@" >>"$NAS_EXPORT_INFO_LOG"; }
ui_input_validated() {
    case "${1:-}" in
        "Local mountpoint for NAS storage") printf '%s\n' "$TMP_DIR/nas-export-default" ;;
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)") printf '%s\n' "192.0.2.10" ;;
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)")
            printf '%s:%s\n' "$NAS_EXPORT_DEFAULT_LABEL" "${2:-}" >>"$NAS_EXPORT_DEFAULT_LOG"
            printf '%s\n' "/exports/entered"
            ;;
        "NFS mount options") printf '%s\n' "${2:-vers=4.2}" ;;
        "NAS sentinel file") printf '%s\n' "${2:-$TMP_DIR/nas-export-default/.mediastack-storage-ready}" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
NAS_EXPORT_INFO_LOG="$TMP_DIR/nas-export-info.log"
NAS_EXPORT_DEFAULT_LOG="$TMP_DIR/nas-export-defaults.log"
NAS_EXPORT_DEFAULT_LABEL="first"
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT _WIZ_PREV_STORAGE_NFS_EXPORT
_WIZ_DATA_DIR=""
_stage1_collect_nas_settings
assert_eq "first:" "$(sed -n '1p' "$NAS_EXPORT_DEFAULT_LOG")" "wizard NAS export prompt: first run has blank default"
assert_contains "$(cat "$NAS_EXPORT_INFO_LOG")" "the shared folder on the NAS (its NFS export path)" "wizard NAS export prompt: explains export path"

NAS_EXPORT_DEFAULT_LABEL="previous"
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT
_WIZ_PREV_STORAGE_NFS_EXPORT="/exports/previous"
_WIZ_DATA_DIR=""
_stage1_collect_nas_settings
assert_eq "previous:/exports/previous" "$(sed -n '2p' "$NAS_EXPORT_DEFAULT_LOG")" "wizard NAS export prompt: previous export is reused as default"
unset -f ui_log ui_input_validated
unset NAS_EXPORT_INFO_LOG NAS_EXPORT_DEFAULT_LOG NAS_EXPORT_DEFAULT_LABEL
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT _WIZ_PREV_STORAGE_NFS_EXPORT

ui_section() { :; }
ui_log() { :; }
ui_input_validated() {
    case "${1:-}" in
        "Data directory") printf '%s\n' "$TMP_DIR/smb-data" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
# SMB collection is its own Stage-1 section (_stage1_collect_smb) since the
# d96bcc1 split — Bazarr/subtitles moved out, so match the SMB enable prompt by
# text rather than by call order.
ui_confirm() {
    case "${1:-}" in
        "Enable SMB"*) return 0 ;; # enable SMB
        *) return 1 ;;
    esac
}
ui_choose() {
    case "${1:-}" in
        "SMB needs TCP port 445"*) printf '%s\n' "Retry port check" ;;
        "Choose SMB share scope:"*) printf '%s\n' "Full system (/) - advanced admin access to the whole server." ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
validate_smb_port() {
    SMB_PORT_CHECKS=$((SMB_PORT_CHECKS + 1))
    [[ "$SMB_PORT_CHECKS" -ge 2 ]]
}
SMB_PORT_CHECKS=0
_WIZ_DATA_DIR=""
_WIZ_STORAGE_MODE=""
_WIZ_SMB_ENABLED=""
_WIZ_SMB_SHARE_SCOPE=""
_stage1_collect_smb >/dev/null 2>&1
assert_eq "2" "$SMB_PORT_CHECKS" "wizard SMB conflict: retry port check reruns validator"
assert_eq "true" "$_WIZ_SMB_ENABLED" "wizard SMB conflict: successful retry enables SMB"
assert_eq "system" "$_WIZ_SMB_SHARE_SCOPE" "wizard SMB conflict: successful retry continues to scope choice"
unset -f ui_section ui_log ui_input_validated ui_confirm ui_choose validate_smb_port
unset SMB_PORT_CHECKS

scenario_end "$CURRENT_SCENARIO"
summary

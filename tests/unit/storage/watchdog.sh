# Owns: watchdog content renderers (unit/sudoers/mount-helper), install/
# uninstall pause gating, and storage-watchdog.sh recovery behavior.
# Sourced by tests/unit/storage.sh; inherits its preamble.

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

# --- Mount helper: only NFS mounts it owns are ever detached ---
HELPER_DIR="$TMP_DIR/mount-helper"
mkdir -p "$HELPER_DIR/bin" "$HELPER_DIR/mnt"
HELPER_STATE="$HELPER_DIR/state"
HELPER_CALLS="$HELPER_DIR/calls.log"
cat >"$HELPER_DIR/storage.env" <<EOF
STORAGE_MODE=nas
STORAGE_MOUNTPOINT=$HELPER_DIR/mnt
STORAGE_NFS_HOST=192.0.2.10
STORAGE_NFS_EXPORT=/exports/mediastack-fixture
STORAGE_EXPECTED_SOURCE=192.0.2.10:/exports/mediastack-fixture
STORAGE_EXPECTED_FSTYPE=nfs4
STORAGE_SENTINEL=$HELPER_DIR/mnt/.mediastack-storage-ready
EOF
storage_mount_helper_content \
    | sed "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$HELPER_DIR/storage.env\"#" >"$HELPER_DIR/helper"
chmod +x "$HELPER_DIR/helper"

cat >"$HELPER_DIR/bin/findmnt" <<EOF
#!/usr/bin/env bash
printf 'findmnt %s\n' "\$*" >>"$HELPER_CALLS"
source "$HELPER_STATE"
case "\$*" in
    *--fstab*)
        # 2 is findmnt's error exit; 1 is the ordinary "no such entry".
        [[ "\$FSTAB_SOURCE" == lookup-error ]] && exit 2
        [[ -n "\$FSTAB_SOURCE" ]] || exit 1
        echo "\$FSTAB_SOURCE"
        exit 0
        ;;
esac
[[ "\$LIVE_SOURCE" == "none" ]] && exit 1
case "\$*" in
    *"-o SOURCE"*) echo "\$LIVE_SOURCE" ;;
    *"-o FSTYPE"*) echo "\$LIVE_FSTYPE" ;;
esac
exit 0
EOF
cat >"$HELPER_DIR/bin/umount" <<EOF
#!/usr/bin/env bash
printf 'umount %s\n' "\$*" >>"$HELPER_CALLS"
source "$HELPER_STATE"
if [[ "\$*" != *-l* ]]; then
    # A plain umount of a dead mount blocks in D-state on a real host; only a
    # lazy detach clears it. Busy likewise bites the plain form only.
    [[ "\$RESPONSIVE" == true ]] || sleep 20
    [[ "\$UMOUNT_FAILS" == true ]] && exit 32
fi
sed -i 's|^LIVE_SOURCE=.*|LIVE_SOURCE=none|' "$HELPER_STATE"
exit 0
EOF
cat >"$HELPER_DIR/bin/stat" <<EOF
#!/usr/bin/env bash
printf 'stat %s\n' "\$*" >>"$HELPER_CALLS"
source "$HELPER_STATE"
[[ "\$RESPONSIVE" == true ]] || exit 1
echo nfs
exit 0
EOF
cat >"$HELPER_DIR/bin/logger" <<EOF
#!/usr/bin/env bash
printf 'logger %s\n' "\$*" >>"$HELPER_CALLS"
exit 0
EOF
cat >"$HELPER_DIR/bin/mount" <<EOF
#!/usr/bin/env bash
printf 'mount %s\n' "\$*" >>"$HELPER_CALLS"
sed -i 's|^LIVE_SOURCE=.*|LIVE_SOURCE=192.0.2.10:/exports/mediastack-fixture|' "$HELPER_STATE"
sed -i 's|^LIVE_FSTYPE=.*|LIVE_FSTYPE=nfs4|' "$HELPER_STATE"
touch "$HELPER_DIR/mnt/.mediastack-storage-ready"
exit 0
EOF
chmod +x "$HELPER_DIR"/bin/{findmnt,umount,mount,stat,logger}

# A PATH holding only what the helper legitimately needs, minus timeout(1):
# proof that a host without it is refused rather than lazily detached.
mkdir -p "$HELPER_DIR/bin-no-timeout"
cp "$HELPER_DIR"/bin/{findmnt,umount,mount,stat,logger} "$HELPER_DIR/bin-no-timeout/"
for helper_tool in bash env python3 mkdir touch sed test; do
    helper_tool_path="$(command -v "$helper_tool")" \
        && ln -sf "$helper_tool_path" "$HELPER_DIR/bin-no-timeout/$helper_tool"
done
unset helper_tool helper_tool_path

helper_run() {
    # $1 live source, $2 live fstype, $3 fstab source, $4 plain umount fails,
    # $5 mount answers, $6 PATH override
    printf 'LIVE_SOURCE=%s\nLIVE_FSTYPE=%s\nFSTAB_SOURCE=%s\nUMOUNT_FAILS=%s\nRESPONSIVE=%s\n' \
        "$1" "$2" "${3:-}" "${4:-false}" "${5:-true}" >"$HELPER_STATE"
    : >"$HELPER_CALLS"
    rm -f "$HELPER_DIR/mnt/.mediastack-storage-ready"
    HELPER_OUTPUT="$(PATH="${6:-$HELPER_DIR/bin:$PATH}" "$HELPER_DIR/helper" repair 2>&1)"
    HELPER_RC=$?
}

helper_run /dev/sdb1 ext4
case "$HELPER_RC:$(cat "$HELPER_CALLS")" in
    0:* | *umount*) fail "mount helper: never unmounts a non-NFS filesystem at the mountpoint" ;;
    *) pass "mount helper: never unmounts a non-NFS filesystem at the mountpoint" ;;
esac
assert_contains "$HELPER_OUTPUT" "refusing to unmount" "mount helper: logs the refusal with what it found"
assert_contains "$HELPER_OUTPUT" "ext4" "mount helper: refusal names the unexpected fstype"

helper_run 198.51.100.9:/exports/old-nas nfs4
assert_contains "$(cat "$HELPER_CALLS")" "umount $HELPER_DIR/mnt" "mount helper: detaches a stale NFS source"
assert_contains "$(cat "$HELPER_CALLS")" "mount -t nfs4" "mount helper: remounts the expected NAS export"
if ((HELPER_RC == 0)); then
    pass "mount helper: stale NFS source is repaired end to end"
else
    fail "mount helper: stale NFS source is repaired end to end" "exit ${HELPER_RC}: ${HELPER_OUTPUT}"
fi

helper_run 198.51.100.9:/exports/old-nas nfs4 198.51.100.9:/exports/old-nas
case "$HELPER_RC:$(cat "$HELPER_CALLS")" in
    0:* | *umount*) fail "mount helper: never detaches an fstab-owned mount" ;;
    *) pass "mount helper: never detaches an fstab-owned mount" ;;
esac

helper_run 198.51.100.9:/exports/old-nas nfs4 "" true true
case "$(cat "$HELPER_CALLS")" in
    *"umount -l"*) fail "mount helper: never lazy-unmounts a live busy NFS mount" ;;
    *) pass "mount helper: never lazy-unmounts a live busy NFS mount" ;;
esac
if ((HELPER_RC != 0)); then
    pass "mount helper: a busy mount is refused, leaving NAS services stopped"
else
    fail "mount helper: a busy mount is refused, leaving NAS services stopped"
fi

# An unresponsive mount is the one case lazy detach exists for: it must be
# reached before any plain umount can block the helper past its 30s cap.
helper_run 198.51.100.9:/exports/old-nas nfs4 "" true false
assert_contains "$(cat "$HELPER_CALLS")" "umount -l $HELPER_DIR/mnt" "mount helper: lazy-detaches a mount that no longer answers"
assert_contains "$(cat "$HELPER_CALLS")" "mount -t nfs4" "mount helper: remounts after a lazy detach"
if grep -qx "umount $HELPER_DIR/mnt" "$HELPER_CALLS"; then
    fail "mount helper: never issues a blocking plain umount on a dead mount"
else
    pass "mount helper: never issues a blocking plain umount on a dead mount"
fi
if ((HELPER_RC == 0)); then
    pass "mount helper: unresponsive mount is repaired without a blocking umount"
else
    fail "mount helper: unresponsive mount is repaired without a blocking umount" "exit ${HELPER_RC}: ${HELPER_OUTPUT}"
fi

helper_run 198.51.100.9:/exports/old-nas nfs4 "" false false "$HELPER_DIR/bin-no-timeout"
case "$HELPER_RC:$(cat "$HELPER_CALLS")" in
    0:* | *umount*) fail "mount helper: refuses to detach anything without timeout(1)" ;;
    *) pass "mount helper: refuses to detach anything without timeout(1)" ;;
esac
assert_contains "$HELPER_OUTPUT" "timeout(1) unavailable" "mount helper: names the missing timeout(1) in the refusal"

# A findmnt --fstab lookup that fails outright is not "no entry": it fails
# closed like every other guard in the helper.
helper_run 198.51.100.9:/exports/old-nas nfs4 lookup-error
case "$HELPER_RC:$(cat "$HELPER_CALLS")" in
    0:* | *umount*) fail "mount helper: an unreadable fstab blocks the detach" ;;
    *) pass "mount helper: an unreadable fstab blocks the detach" ;;
esac
assert_contains "$HELPER_OUTPUT" "/etc/fstab lookup failed" "mount helper: reports the failed fstab lookup"
unset -f helper_run
unset HELPER_DIR HELPER_STATE HELPER_CALLS HELPER_OUTPUT HELPER_RC

# --- Disabled watchdog: install is a no-op that tears down any prior unit ---
WATCHDOG_INSTALL_PAUSED=false
storage_pause_watchdog_for_install() {
    WATCHDOG_INSTALL_PAUSED=true
    return 0
}
# shellcheck disable=SC2034 # consumed by storage_is_nas/storage_watchdog_enabled in storage/core.sh, sourced below
STORAGE_MODE=nas STORAGE_WATCHDOG=false
if storage_install_watchdog >/dev/null 2>&1 && $WATCHDOG_INSTALL_PAUSED; then
    pass "storage_install_watchdog: disabled flag skips install and tears down stale unit"
else
    fail "storage_install_watchdog: disabled flag skips install and tears down stale unit"
fi
unset -f storage_pause_watchdog_for_install
unset STORAGE_MODE STORAGE_WATCHDOG
source "$REPO_ROOT/scripts/setup/storage.sh"

# --- A login name that cannot be a sudoers token skips the whole install ---
WATCHDOG_SUDO_LOG="$TMP_DIR/watchdog-adname-sudo.log"
WATCHDOG_WARNINGS="$TMP_DIR/watchdog-adname-warnings.log"
: >"$WATCHDOG_SUDO_LOG"
: >"$WATCHDOG_WARNINGS"
id() { printf '%s\n' 'EXAMPLE\op'; }
sudo() { printf '%s\n' "sudo $*" >>"$WATCHDOG_SUDO_LOG"; }
storage_log_warn() { printf '%s\n' "$*" >>"$WATCHDOG_WARNINGS"; }
storage_log_info() { :; }
storage_log_ok() { :; }
WATCHDOG_ORIGINAL_SCRIPT_DIR="$SCRIPT_DIR"
SCRIPT_DIR="$REPO_ROOT"
# shellcheck disable=SC2034 # consumed by storage_is_nas/storage_watchdog_enabled in storage/core.sh
STORAGE_MODE=nas STORAGE_WATCHDOG=true
storage_install_watchdog >/dev/null 2>&1
assert_eq "0" "$?" "storage_install_watchdog: unusable sudoers user name does not fail setup"
assert_contains "$(cat "$WATCHDOG_WARNINGS")" 'EXAMPLE\op' "storage_install_watchdog: unusable sudoers user name is reported"
assert_eq "" "$(cat "$WATCHDOG_SUDO_LOG")" "storage_install_watchdog: unusable sudoers user name installs nothing"
# A dotted login name is a valid useradd and sudoers token, so it must not be
# swept up by the guard above: this run gets as far as needing visudo.
: >"$WATCHDOG_WARNINGS"
id() { printf '%s\n' 'first.last'; }
command() {
    [[ "$1" == -v && "$2" == visudo ]] && return 1
    builtin command "$@"
}
storage_install_watchdog >/dev/null 2>&1
assert_contains "$(cat "$WATCHDOG_WARNINGS")" "visudo is unavailable" "storage_install_watchdog: a dotted login name passes the sudoers-token guard"
unset -f command
SCRIPT_DIR="$WATCHDOG_ORIGINAL_SCRIPT_DIR"
unset -f id sudo storage_log_warn storage_log_info storage_log_ok
unset STORAGE_MODE STORAGE_WATCHDOG WATCHDOG_SUDO_LOG WATCHDOG_WARNINGS WATCHDOG_ORIGINAL_SCRIPT_DIR
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
# shellcheck disable=SC2034 # consumed by storage_manual_wiring in storage/core.sh, sourced below
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
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_MOUNTPOINT="$TMP_DIR"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_EXPECTED_FSTYPE="nfs4"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_SENTINEL="$TMP_DIR/.mediastack-storage-ready"
# shellcheck disable=SC2034 # consumed by storage_data_services in storage/core.sh, sourced below
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

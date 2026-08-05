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

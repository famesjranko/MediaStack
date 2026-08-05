#!/usr/bin/env bash
# =============================================================================
# MediaStack NAS storage watchdog
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

source "$SCRIPT_DIR/scripts/setup/storage.sh"

if ! storage_is_nas; then
    echo "$(date '+%F %T') [storage-watchdog] STORAGE_MODE=${STORAGE_MODE:-local}; exiting"
    exit 0
fi

if ! storage_watchdog_enabled; then
    echo "$(date '+%F %T') [storage-watchdog] STORAGE_WATCHDOG=false; exiting"
    exit 0
fi

STATE_DIR="$SCRIPT_DIR/config/state"
LOCKFILE="$STATE_DIR/storage-watchdog.lock"
STATE_FILE="$STATE_DIR/storage-watchdog-stopped"
CHECK_INTERVAL="${STORAGE_CHECK_INTERVAL:-15}"
FAIL_GRACE="${STORAGE_FAIL_GRACE:-30}"
OK_STABLE="${STORAGE_OK_STABLE:-60}"
MOUNT_HELPER="${MEDIASTACK_STORAGE_MOUNT_HELPER:-/usr/local/libexec/mediastack/storage-mount-helper}"

mkdir -p "$STATE_DIR"

exec 200>"$LOCKFILE" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
    flock -n 200 || {
        echo "$(date '+%F %T') [storage-watchdog] another instance is already running"
        exit 0
    }
fi

log() {
    echo "$(date '+%F %T') [storage-watchdog] $*"
}

WATCHDOG_ABANDONED_SENTINEL_PIDS=()

watchdog_job_running() {
    local pid="$1"
    jobs -pr | grep -qx "$pid"
}

watchdog_reap_sentinel_probes() {
    local pid
    local active=()
    for pid in "${WATCHDOG_ABANDONED_SENTINEL_PIDS[@]:-}"; do
        if watchdog_job_running "$pid"; then
            active+=("$pid")
        else
            wait "$pid" 2>/dev/null || true
        fi
    done
    WATCHDOG_ABANDONED_SENTINEL_PIDS=("${active[@]}")
}

watchdog_sentinel_probe() {
    local sentinel="$1"
    [[ -e "$sentinel" ]]
}

watchdog_sentinel_ok() {
    local sentinel pid deadline probe_timeout probe_interval max_abandoned
    watchdog_reap_sentinel_probes

    storage_sentinel_is_under_mountpoint || return 1
    sentinel="$(storage_sentinel_path)"
    probe_timeout="${STORAGE_SENTINEL_PROBE_TIMEOUT:-5}"
    probe_interval="${STORAGE_SENTINEL_PROBE_INTERVAL:-0.2}"
    max_abandoned="${STORAGE_SENTINEL_MAX_ABANDONED:-3}"
    if [[ ! "$probe_timeout" =~ ^[0-9]+$ ]] || ((probe_timeout < 1)); then
        probe_timeout=5
    fi
    if [[ ! "$max_abandoned" =~ ^[0-9]+$ ]] || ((max_abandoned < 1)); then
        max_abandoned=3
    fi
    case "$probe_interval" in
        '' | . | *[!0-9.]* | *.*.*) probe_interval=0.2 ;;
    esac
    if ((${#WATCHDOG_ABANDONED_SENTINEL_PIDS[@]} >= max_abandoned)); then
        log "sentinel probe backlog reached ${max_abandoned}; treating NAS storage as unavailable"
        return 1
    fi

    (watchdog_sentinel_probe "$sentinel") &
    pid=$!
    deadline=$(($(date +%s) + probe_timeout))
    while watchdog_job_running "$pid"; do
        if (($(date +%s) >= deadline)); then
            kill "$pid" >/dev/null 2>&1 || true
            WATCHDOG_ABANDONED_SENTINEL_PIDS+=("$pid")
            log "sentinel probe timed out after ${probe_timeout}s; treating NAS storage as unavailable"
            return 1
        fi
        sleep "$probe_interval"
    done
    wait "$pid"
}

watchdog_storage_nas_ok() {
    storage_is_nas || return 0
    storage_mount_matches && watchdog_sentinel_ok
}

compose_running() {
    docker compose ps --filter status=running --format '{{.Name}}' 2>/dev/null || true
}

service_is_running() {
    local svc="$1" running="${2:-}"
    [[ -n "$running" ]] || running="$(compose_running)"
    grep -qx "$svc" <<<"$running"
}

protected_running_count() {
    local running svc count=0
    running="$(compose_running)"
    for svc in $(storage_data_services); do
        if service_is_running "$svc" "$running"; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

managed_service_count() {
    storage_data_services | grep -c .
}

stop_managed_services() {
    local running svc stopped=false
    running="$(compose_running)"

    for svc in $(storage_data_services); do
        if service_is_running "$svc" "$running"; then
            log "stopping $svc because NAS storage is unavailable"
            timeout 30 docker compose stop "$svc" >/dev/null 2>&1 || true
            stopped=true
        fi
    done

    if $stopped || [[ ! -f "$STATE_FILE" ]]; then
        date -Is >"$STATE_FILE"
    fi
}

start_managed_services() {
    local running svc
    running="$(compose_running)"
    log "NAS storage stable; ensuring NAS-dependent services are running"
    for svc in $(storage_data_services); do
        if ! service_is_running "$svc" "$running"; then
            log "starting $svc"
            timeout 60 docker compose up -d "$svc" >/dev/null 2>&1 || true
        fi
    done
    rm -f "$STATE_FILE"
}

repair_mount_if_needed() {
    if storage_mount_matches; then
        return 0
    fi
    if [[ ! -x "$MOUNT_HELPER" ]]; then
        log "mount repair helper is unavailable: $MOUNT_HELPER"
        return 0
    fi
    log "requesting NAS mount repair via root-owned helper"
    timeout 30 sudo -n "$MOUNT_HELPER" repair >/dev/null 2>&1 || true
}

watchdog_main() {
    log "starting: data=${DATA_DIR:-/data} mountpoint=$(storage_mountpoint) source=$(storage_expected_source) sentinel=$(storage_sentinel_path)"

    fail_since=0
    ok_since=0
    stopped_for_failure=false
    boot_recovery_done=false
    if [[ -s "$STATE_FILE" ]]; then
        stopped_for_failure=true
        log "found pending stopped-service state from a previous watchdog run"
    fi

    while true; do
        now=$(date +%s)

        if watchdog_storage_nas_ok; then
            fail_since=0
            ((ok_since == 0)) && ok_since=$now
            ok_for=$((now - ok_since))
            if ((ok_for >= OK_STABLE)); then
                if $stopped_for_failure; then
                    start_managed_services
                    stopped_for_failure=false
                    ok_since=0
                    boot_recovery_done=true
                elif ! $boot_recovery_done; then
                    # One-time reconciliation once NAS is stable. The managed set
                    # is the user's known NAS-dependent services
                    # (storage_data_services), so ensure ALL of them are running
                    # rather than only recovering the all-stopped case. Something
                    # other than the watchdog can leave a subset stopped (e.g. a
                    # setup re-run that stops services but restarts only jellyfin),
                    # and the old all-or-nothing guard skipped recovery forever
                    # whenever even one service was up. start_managed_services is
                    # idempotent — it starts only the members that are not running.
                    if (($(protected_running_count) < $(managed_service_count))); then
                        log "reconciling NAS-dependent services after boot; starting any that are not running"
                        start_managed_services
                    fi
                    ok_since=0
                    boot_recovery_done=true
                fi
            fi
        else
            ok_since=0
            boot_recovery_done=false
            ((fail_since == 0)) && fail_since=$now
            bad_for=$((now - fail_since))
            log "NAS check failed (${bad_for}s/${FAIL_GRACE}s)"

            if ((bad_for >= FAIL_GRACE)); then
                if ! $stopped_for_failure; then
                    stop_managed_services
                    stopped_for_failure=true
                fi
                repair_mount_if_needed
                fail_since=0
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

if [[ "${MEDIASTACK_WATCHDOG_SOURCE_ONLY:-0}" != "1" ]]; then
    watchdog_main
fi

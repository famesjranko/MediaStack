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
source "$SCRIPT_DIR/scripts/lib/service-intent.sh"

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
# The services the watchdog stopped in the current outage, one per line. Kept
# beside STATE_FILE (whose timestamp the launcher shows) so recovery restarts
# only these. Absent next to a STATE_FILE from an older release: recovery then
# falls back to the whole managed set.
STOPPED_SERVICES_FILE="$STATE_DIR/storage-watchdog-stopped-services"
CHECK_INTERVAL="${STORAGE_CHECK_INTERVAL:-15}"
FAIL_GRACE="${STORAGE_FAIL_GRACE:-30}"
OK_STABLE="${STORAGE_OK_STABLE:-60}"
MOUNT_HELPER="${MEDIASTACK_STORAGE_MOUNT_HELPER:-/usr/local/libexec/mediastack/storage-mount-helper}"

mkdir -p "$STATE_DIR"

# A source-only load (tests) is not a running instance, so it takes no lock:
# with a real run holding it, the exit below would end the sourcing shell.
if [[ "${MEDIASTACK_WATCHDOG_SOURCE_ONLY:-0}" != "1" ]]; then
    exec 200>"$LOCKFILE" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        flock -n 200 || {
            echo "$(date '+%F %T') [storage-watchdog] another instance is already running"
            exit 0
        }
    fi
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

# A running service contradicts a recorded user stop (it was started again by
# a path the launcher does not track, such as update.sh or `docker start`), so
# the entry is dropped; otherwise it would block the next recovery.
# Cheap in steady state: Docker is asked only when the intent file has entries.
watchdog_drop_stale_intent() {
    local running="${1:-}" svc stale=()
    local -a intent=()
    mapfile -t intent < <(service_intent_list 2>/dev/null)
    ((${#intent[@]} > 0)) || return 0
    [[ -n "$running" ]] || running="$(compose_running)"
    for svc in "${intent[@]}"; do
        service_is_running "$svc" "$running" && stale+=("$svc")
    done
    if ((${#stale[@]} > 0)); then
        log "dropping user-stop intent for running service(s): ${stale[*]}"
        service_intent_clear "${stale[@]}" >/dev/null 2>&1 || true
    fi
}

# $1 is whether storage has passed a check since this watchdog started. If not
# (true host boot), a service that is not running was never started rather than
# stopped by someone; it is recorded too, so recovery starts it once storage is
# stable.
stop_managed_services() {
    local seen_ok="${1:-true}" running svc stopped=false names=()
    running="$(compose_running)"
    watchdog_drop_stale_intent "$running"

    for svc in $(storage_data_services); do
        if service_is_running "$svc" "$running"; then
            log "stopping $svc because NAS storage is unavailable"
            timeout 30 docker compose stop "$svc" >/dev/null 2>&1 || true
            names+=("$svc")
            stopped=true
        elif [[ "$seen_ok" != true ]]; then
            names+=("$svc")
        fi
    done

    # Union with names from an earlier outage that was not yet recovered.
    [[ -f "$STOPPED_SERVICES_FILE" ]] && mapfile -t -O "${#names[@]}" names <"$STOPPED_SERVICES_FILE"
    printf '%s\n' "${names[@]}" | sort -u | grep . >"$STOPPED_SERVICES_FILE.tmp" || true
    mv -f "$STOPPED_SERVICES_FILE.tmp" "$STOPPED_SERVICES_FILE"

    if $stopped || [[ ! -f "$STATE_FILE" ]]; then
        date -Is >"$STATE_FILE"
    fi
}

# $1=boot: every managed service that is not running and not stopped by the user.
# $1=recover: only the ones this watchdog stopped for the outage, minus the user's.
# Callers reach this only after the mount identity and sentinel checks passed.
# An unreadable intent file means the user's choices are unknown: start nothing,
# keep the pending state and return 1 so the caller tries again later.
start_managed_services() {
    local mode="${1:-boot}" running svc stopped_by_watchdog="" held=""
    running="$(compose_running)"
    if [[ "$mode" == recover && -f "$STOPPED_SERVICES_FILE" ]]; then
        stopped_by_watchdog="$(<"$STOPPED_SERVICES_FILE")"
    else
        mode=boot
    fi
    if ! held="$(service_intent_list)"; then
        log "cannot read $(service_intent_file); starting nothing until it is readable or removed"
        return 1
    fi
    log "NAS storage stable; ensuring NAS-dependent services are running"
    for svc in $(storage_data_services); do
        if [[ "$mode" == recover ]] && ! grep -qx "$svc" <<<"$stopped_by_watchdog"; then
            continue
        fi
        if grep -qx "$svc" <<<"$held"; then
            log "leaving $svc stopped: you stopped it"
        elif ! service_is_running "$svc" "$running"; then
            log "starting $svc"
            timeout 60 docker compose up -d "$svc" >/dev/null 2>&1 || true
        fi
    done
    rm -f "$STOPPED_SERVICES_FILE" "$STATE_FILE"
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

# One poll. State lives in globals so watchdog_main and the tests step it alike.
watchdog_tick() {
    now=$(date +%s)

    if watchdog_storage_nas_ok; then
        fail_since=0
        ((ok_since == 0)) && ok_since=$now
        ok_for=$((now - ok_since))
        watchdog_drop_stale_intent
        if ((ok_for >= OK_STABLE)); then
            storage_seen_ok=true
            if $stopped_for_failure; then
                if start_managed_services recover; then
                    stopped_for_failure=false
                    boot_recovery_done=true
                fi
                ok_since=0
            elif ! $boot_recovery_done; then
                # One-time reconciliation once NAS is stable. The managed set
                # is the user's known NAS-dependent services
                # (storage_data_services), so ensure ALL of them are running
                # rather than only recovering the all-stopped case. Something
                # other than the watchdog can leave a subset stopped (e.g. a
                # setup re-run that stops services but restarts only jellyfin),
                # and the old all-or-nothing guard skipped recovery forever
                # whenever even one service was up. start_managed_services is
                # idempotent - it starts only the members that are not running -
                # and leaves alone the ones the user stopped.
                if (($(protected_running_count) < $(managed_service_count))); then
                    log "reconciling NAS-dependent services after boot; starting any that are not running"
                    start_managed_services boot || {
                        ok_since=0
                        return 0
                    }
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
                stop_managed_services "$storage_seen_ok"
                stopped_for_failure=true
            fi
            repair_mount_if_needed
            fail_since=0
        fi
    fi
}

watchdog_main() {
    log "starting: data=${DATA_DIR:-/data} mountpoint=$(storage_mountpoint) source=$(storage_expected_source) sentinel=$(storage_sentinel_path)"

    fail_since=0
    ok_since=0
    stopped_for_failure=false
    boot_recovery_done=false
    storage_seen_ok=false
    if [[ -s "$STATE_FILE" ]]; then
        stopped_for_failure=true
        log "found pending stopped-service state from a previous watchdog run"
    fi

    while true; do
        watchdog_tick
        sleep "$CHECK_INTERVAL"
    done
}

if [[ "${MEDIASTACK_WATCHDOG_SOURCE_ONLY:-0}" != "1" ]]; then
    watchdog_main
fi

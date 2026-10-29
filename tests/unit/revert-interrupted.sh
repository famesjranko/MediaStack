#!/usr/bin/env bash
# Owns: interrupted Revert recovery with real archives and fresh launcher processes.
# Sources: tests/lib/assert.sh. Docker, readiness, login and presentation are stubbed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO=revert-interrupted
scenario_begin "$CURRENT_SCENARIO"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export REPO_ROOT

cat >"$WORK_DIR/worker.sh" <<'BASH'
set -uo pipefail
source "$REPO_ROOT/mediastack" </dev/null
SCRIPT_DIR="$FIXTURE_ROOT"
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/services/qbittorrent/main.sh"
WORKER_PID=$BASHPID
JELLYFIN_ADMIN_PASSWORD=fixture
_service_profile_flag(){ :; }
_regenerate_override(){ :; }
storage_guard_before_start(){ :; }
_wait_service_running(){ :; }
_verify_service_up(){ _service_is_running qbittorrent; }
_service_is_running(){ [[ -f "$FIXTURE_ROOT/running" ]]; }
_service_login_check(){
    [[ ! -f "$FIXTURE_ROOT/reject-login" ]] && cmp -s "$FIXTURE_ROOT/accepted" "$SCRIPT_DIR/config/qbittorrent/settings"
}
ui_log(){ printf '%s:%s\n' "$1" "$2"; }
ui_confirm(){ return 1; }
interrupt(){
    if [[ "${INTERRUPT_AT:-}" == "$1" ]]; then
        printf '%s\n' "$1" >"$FIXTURE_ROOT/interrupted"
        kill -KILL "$WORKER_PID"
    fi
}
tar(){
    command tar "$@" || return $?
    if [[ "$1" == -czf && "$2" == *qbittorrent.pre-revert.tar.gz.part ]]; then
        interrupt snapshot
    elif [[ "$1" == -xzf ]]; then
        interrupt extracted
    fi
}
mv(){
    command mv "$@" || return $?
    if [[ "$1" == "$SCRIPT_DIR/config/qbittorrent" ]]; then
        interrupt aside
    elif [[ "$2" == "$SCRIPT_DIR/config/qbittorrent" ]]; then
        interrupt installed
    fi
}
docker(){
    printf '%s\n' "$*" >>"$FIXTURE_ROOT/docker.log"
    case "$1 $2" in
        'compose stop') rm -f "$FIXTURE_ROOT/running" ;;
        'compose start') : >"$FIXTURE_ROOT/running" ;;
        'compose up')
            interrupt start
            if [[ -f "$FIXTURE_ROOT/fail-up" ]]; then
                local remaining
                remaining=$(cat "$FIXTURE_ROOT/fail-up")
                if ((remaining > 1)); then
                    printf '%s\n' "$((remaining - 1))" >"$FIXTURE_ROOT/fail-up"
                else
                    rm "$FIXTURE_ROOT/fail-up"
                fi
                return 1
            fi
            _service_policy_raw qbittorrent >"$FIXTURE_ROOT/image"
            if [[ -f "$FIXTURE_ROOT/exit-after-up" ]]; then
                rm "$FIXTURE_ROOT/exit-after-up"
                return 0
            fi
            : >"$FIXTURE_ROOT/running"
            ;;
    esac
    return 0
}
if [[ "$1" == seed ]]; then
    mkdir -p "$SCRIPT_DIR/config/qbittorrent" "$SCRIPT_DIR/config/state"
    printf 'accepted settings\n' >"$FIXTURE_ROOT/accepted"
    cp "$FIXTURE_ROOT/accepted" "$SCRIPT_DIR/config/qbittorrent/settings"
    _take_restore_point qbittorrent
    printf 'migrated settings\n' >"$SCRIPT_DIR/config/qbittorrent/settings"
    printf 'new database journal\n' >"$SCRIPT_DIR/config/qbittorrent/database-wal"
    printf 'untouched media\n' >"$FIXTURE_ROOT/media"
    printf 'qbittorrent\tfixture/qbt:latest\tsha256:%064d\n' 1 >"$SCRIPT_DIR/config/state/image-install.tsv"
    _set_service_policy qbittorrent latest
    : >"$FIXTURE_ROOT/running"
    exit 0
fi
if [[ "$1" == update ]]; then
    _apply_service_update qbittorrent 1
else
    _reset_service_to_default qbittorrent
fi
BASH

run_worker() {
    FIXTURE_ROOT="$1" INTERRUPT_AT="${3:-}" MEDIASTACK_NONINTERACTIVE=1 \
        bash "$WORK_DIR/worker.sh" "$2" >"$1/output" 2>&1
}

check_retry() {
    local boundary="$1" fixture="$WORK_DIR/$1" rc killed_rc killed_at state_mode

    # Given an updated running service has an accepted restore point.
    mkdir -p "$fixture"
    run_worker "$fixture" seed

    # When Revert is killed at a filesystem or container-start boundary and retried in a fresh process.
    run_worker "$fixture" revert "$boundary"
    killed_rc=$?
    killed_at=$(cat "$fixture/interrupted")
    state_mode=$(stat -c %a "$fixture/config/state/revert-qbittorrent.tsv")
    run_worker "$fixture" revert
    rc=$?

    # Then the retry restores the accepted data and image and resumes the running service.
    assert_eq 137 "$killed_rc" "$boundary: the Revert process was killed"
    assert_eq "$boundary" "$killed_at" "$boundary: the intended boundary was reached"
    assert_eq 600 "$state_mode" "$boundary: recovery state is private"
    assert_eq 0 "$rc" "$boundary: retry succeeds"
    assert_eq 'accepted settings' "$(cat "$fixture/config/qbittorrent/settings" 2>/dev/null)" "$boundary: accepted data is restored"
    assert_file_absent "$fixture/config/qbittorrent/database-wal" "$boundary: migrated journal is removed"
    assert_file_contains "$fixture/image" 'fixture/qbt:latest@sha256:' "$boundary: installed image is started"
    assert_file_contains "$fixture/output" 'back up and MediaStack can still log in' "$boundary: retry verifies login"
    assert_eq yes "$([[ -f "$fixture/running" ]] && echo yes || echo no)" "$boundary: service is running"
    assert_file_absent "$fixture/config/state/restore-points/qbittorrent.tar.gz" "$boundary: verified retry consumes the point"
    assert_eq no "$([[ -e "$fixture/config/state/restore-points/qbittorrent.work" ]] && echo yes || echo no)" "$boundary: retry removes its workspace"
    assert_file_absent "$fixture/config/state/revert-qbittorrent.tsv" "$boundary: verified retry clears recovery state"
    assert_eq 'untouched media' "$(cat "$fixture/media")" "$boundary: media is unchanged"
}

check_retry snapshot
check_retry extracted
check_retry aside
check_retry installed
check_retry start

check_fallback() {
    local boundary="$1" fixture="$WORK_DIR/fallback-$1" rc

    # Given Revert was killed during its config swap.
    mkdir -p "$fixture"
    run_worker "$fixture" seed
    run_worker "$fixture" revert "$boundary"
    echo 1 >"$fixture/fail-up"

    # When a fresh retry fails to start the installed image.
    run_worker "$fixture" revert
    rc=$?

    # Then fallback restores the original newer data and policy and resumes the service.
    assert_eq 1 "$rc" "$boundary fallback: retry reports the failed Revert"
    assert_eq 'migrated settings' "$(cat "$fixture/config/qbittorrent/settings" 2>/dev/null)" "$boundary fallback: original safety data is restored"
    assert_file_contains "$fixture/config/qbittorrent/database-wal" 'new database journal' "$boundary fallback: newer journal survives"
    assert_eq latest "$(cat "$fixture/image" 2>/dev/null)" "$boundary fallback: original policy is used for the newer config"
    assert_eq yes "$([[ -f "$fixture/running" ]] && echo yes || echo no)" "$boundary fallback: original service resumes"
    assert_eq yes "$([[ -f "$fixture/config/state/restore-points/qbittorrent.tar.gz" ]] && echo yes || echo no)" "$boundary fallback: point remains for another attempt"
    assert_file_absent "$fixture/config/state/revert-qbittorrent.tsv" "$boundary fallback: completed rollback clears recovery state"
}

check_fallback aside
check_fallback installed

# Given a service has an interrupted Revert with its safety copy saved.
FIXTURE="$WORK_DIR/update"
mkdir -p "$FIXTURE"
run_worker "$FIXTURE" seed
run_worker "$FIXTURE" revert installed
SAFETY_HASH=$(sha256sum "$FIXTURE/config/state/restore-points/qbittorrent.pre-revert.tar.gz")
: >"$FIXTURE/docker.log"

# When an update is requested before recovery finishes.
run_worker "$FIXTURE" update
RC=$?

# Then the update refuses to replace the restore point or change containers.
assert_eq 1 "$RC" 'pending update: recovery blocks the update'
assert_file_contains "$FIXTURE/output" 'Run Revert for qbittorrent again' 'pending update: recovery instruction is explicit'
assert_eq "$SAFETY_HASH" "$(sha256sum "$FIXTURE/config/state/restore-points/qbittorrent.pre-revert.tar.gz")" 'pending update: safety copy is unchanged'
assert_eq 0 "$(wc -c <"$FIXTURE/docker.log")" 'pending update: no Docker operation runs'

# Given a retry of an interrupted Revert cannot authenticate on the installed image.
FIXTURE="$WORK_DIR/login"
mkdir -p "$FIXTURE"
run_worker "$FIXTURE" seed
run_worker "$FIXTURE" revert installed
: >"$FIXTURE/reject-login"

# When recovery reaches the login check.
run_worker "$FIXTURE" revert
RC=$?

# Then it restores the previous image and config and allows a later update.
assert_eq 1 "$RC" 'login failure: Revert fails'
assert_file_contains "$FIXTURE/output" 'can no longer log in' 'login failure: authentication failure is explicit'
assert_eq 'migrated settings' "$(cat "$FIXTURE/config/qbittorrent/settings")" 'login failure: newer config is restored'
assert_eq latest "$(cat "$FIXTURE/image")" 'login failure: newer image policy is restored'
assert_file_absent "$FIXTURE/config/state/revert-qbittorrent.tsv" 'login failure: completed fallback permits later updates'

# Given the installed image and rollback both fail to start after an interrupted Revert.
FIXTURE="$WORK_DIR/failed-rollback"
mkdir -p "$FIXTURE"
run_worker "$FIXTURE" seed
run_worker "$FIXTURE" revert installed
echo 2 >"$FIXTURE/fail-up"

# When recovery fails and is retried again in a fresh process.
run_worker "$FIXTURE" revert
FAILED_RC=$?
RUNNING_AFTER_FAILURE=$([[ -f "$FIXTURE/running" ]] && echo yes || echo no)
PENDING_AFTER_FAILURE=$([[ -f "$FIXTURE/config/state/revert-qbittorrent.tsv" ]] && echo yes || echo no)
run_worker "$FIXTURE" revert
RC=$?

# Then the next retry recovers the accepted data and resumes the original running service.
assert_eq 1 "$FAILED_RC" 'failed rollback: recovery reports failure'
assert_eq no "$RUNNING_AFTER_FAILURE" 'failed rollback: mismatched container is not started'
assert_eq yes "$PENDING_AFTER_FAILURE" 'failed rollback: recovery state is retained'
assert_eq 0 "$RC" 'failed rollback: another retry succeeds'
assert_eq 'accepted settings' "$(cat "$FIXTURE/config/qbittorrent/settings")" 'failed rollback: another retry restores accepted data'
assert_eq yes "$([[ -f "$FIXTURE/running" ]] && echo yes || echo no)" 'failed rollback: another retry resumes the service'

# Given an interrupted Revert resumes a service that exits immediately after Compose starts it.
FIXTURE="$WORK_DIR/exited"
mkdir -p "$FIXTURE"
run_worker "$FIXTURE" seed
run_worker "$FIXTURE" revert installed
: >"$FIXTURE/exit-after-up"

# When Compose reports success but the service is stopped during verification.
run_worker "$FIXTURE" revert
RC=$?

# Then Revert reports failure and restores the previous image and config.
assert_eq 1 "$RC" 'exited: a stopped service fails verification'
assert_eq 'migrated settings' "$(cat "$FIXTURE/config/qbittorrent/settings")" 'exited: previous config is restored'
assert_eq latest "$(cat "$FIXTURE/image")" 'exited: previous image is restored'

# Given an intentionally stopped service is interrupted after restoring its config.
FIXTURE="$WORK_DIR/stopped"
mkdir -p "$FIXTURE"
run_worker "$FIXTURE" seed
rm "$FIXTURE/running"
run_worker "$FIXTURE" revert installed

# When Revert is retried in a fresh process.
run_worker "$FIXTURE" revert
RC=$?

# Then the accepted data is restored while the service stays stopped.
assert_eq 0 "$RC" 'stopped: retry succeeds'
assert_eq 'accepted settings' "$(cat "$FIXTURE/config/qbittorrent/settings" 2>/dev/null)" 'stopped: accepted data is restored'
assert_file_absent "$FIXTURE/running" 'stopped: retry respects the intentional stop'
assert_file_absent "$FIXTURE/image" 'stopped: no image is started'

scenario_end "$CURRENT_SCENARIO"
summary

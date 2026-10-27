#!/usr/bin/env bash
# tests/unit/watchdog-intent.sh
#
# Contract: the NAS watchdog keeps owning storage-safety stop/resume and boot
# recovery, but never restarts a service the user stopped through the launcher
# (scripts/lib/service-intent.sh). It restarts only what it stopped, minus the
# user's, and at boot every data service the user did not stop. Mount checks gate
# every start. A service that depends on a user-stopped one starts with
# --no-deps, without the stopped one. Bad intent files, an unreadable Compose
# configuration, and a stop recorded while the watchdog works have defined outcomes.
# Stepped one poll at a time (watchdog_tick) against a fake Docker; no containers.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="watchdog-intent"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ALL_SERVICES=(unpackerr qbittorrent sonarr radarr seerr jellyfin)
ALL="${ALL_SERVICES[*]}"

# --- Fake Docker: a running-set and a depends_on graph in files, every call logged ---
# Like real Compose, `up -d <svc>` starts <svc>'s dependencies too (`--no-deps` does not), and
# `config --format json` prints the graph (or fails when the file is missing).
# FAKE_UP_HOOK runs after `up -d $FAKE_UP_SVC`; FAKE_PS_HOOK runs after the first `ps`.
FAKE_BIN="$TMP_DIR/bin"
export FAKE_RUNNING="$TMP_DIR/running" FAKE_LOG="$TMP_DIR/docker.log" FAKE_DEPS="$TMP_DIR/deps" FAKE_CONFIG_BROKEN="$TMP_DIR/config-broken"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
[[ "$1" == compose ]] || exit 0
last="${*: -1}"
start() { # $1 = service; starts it and, recursively, what it depends on
    local dep
    grep -qx "$1" "$FAKE_RUNNING" 2>/dev/null || echo "$1" >>"$FAKE_RUNNING"
    for dep in $(awk -v s="$1" '$1 == s { $1 = ""; print }' "$FAKE_DEPS"); do start "$dep"; done
}
case "$*" in
    *" config --format json"*)
        [[ ! -e "$FAKE_CONFIG_BROKEN" ]] || exit 1
        python3 -I -c 'import json,sys; print(json.dumps({"services": {l.split()[0]: {"depends_on": dict.fromkeys(l.split()[1:], {})} for l in sys.stdin}}))' <"$FAKE_DEPS" ;;
    *"ps --filter status=running"*) cat "$FAKE_RUNNING" 2>/dev/null; [[ -z "${FAKE_PS_HOOK:-}" || -e "$FAKE_LOG.ps" ]] || { : >"$FAKE_LOG.ps"; eval "$FAKE_PS_HOOK"; } ;;
    *" stop "*) sed -i "/^${last}\$/d" "$FAKE_RUNNING" ;;
    *" up -d --no-deps "*) grep -qx "$last" "$FAKE_RUNNING" 2>/dev/null || echo "$last" >>"$FAKE_RUNNING"; [[ "$last" != "${FAKE_UP_SVC:-}" ]] || eval "$FAKE_UP_HOOK" ;;
    *" up -d "*) start "$last"; [[ "$last" != "${FAKE_UP_SVC:-}" ]] || eval "$FAKE_UP_HOOK" ;;
esac
exit 0
DOCKER
chmod +x "$FAKE_BIN/docker"
PATH="$FAKE_BIN:$PATH"

# --- Load the real watchdog without running it ---
export MEDIASTACK_WATCHDOG_SOURCE_ONLY=1
STORAGE_MODE=nas
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_MOUNTPOINT="$TMP_DIR/mnt"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_EXPECTED_FSTYPE="nfs4"
# shellcheck disable=SC2034 # consumed by scripts/storage-watchdog.sh, sourced below
STORAGE_SENTINEL="$TMP_DIR/mnt/.mediastack-storage-ready"
# shellcheck disable=SC2034 # consumed by storage_data_services in scripts/setup/storage/core.sh
BAZARR_ENABLED=false
source "$REPO_ROOT/scripts/storage-watchdog.sh"
set +e

# State goes to the temp dir; the real mount check is kept for the gate tests.
SCRIPT_DIR="$TMP_DIR/root"
STATE_DIR="$TMP_DIR/state"
STATE_FILE="$STATE_DIR/storage-watchdog-stopped"
STOPPED_SERVICES_FILE="$STATE_DIR/storage-watchdog-stopped-services"
INTENT_FILE="$SCRIPT_DIR/config/state/user-stopped-services"
OK_STABLE=0
FAIL_GRACE=0
NAS_FLAG="$TMP_DIR/nas"
eval "real_$(declare -f watchdog_storage_nas_ok)"
fake_nas_ok() { [[ "$(<"$NAS_FLAG")" == ok ]]; }
log() { printf '%s\n' "$*" >>"$TMP_DIR/watchdog.log"; }
repair_mount_if_needed() { :; }

# The direct depends_on edges of the data services (and jackett), as in docker-compose.yml.
# Dependencies are listed in sorted order, which the drift check below relies on.
DEPS_GRAPH='bazarr radarr sonarr
radarr jackett qbittorrent
seerr jellyfin radarr sonarr
sonarr jackett qbittorrent
unpackerr radarr sonarr'
fresh() { # $@ = services running at the start; a new watchdog process, intent empty
    rm -rf "$STATE_DIR" "$SCRIPT_DIR" "$FAKE_LOG" "$FAKE_LOG.ps" "$TMP_DIR/watchdog.log"
    printf '%s\n' "$DEPS_GRAPH" >"$FAKE_DEPS"
    rm -f "$FAKE_CONFIG_BROKEN"
    mkdir -p "$STATE_DIR" "$SCRIPT_DIR/config/state"
    : >"$FAKE_LOG"
    printf '%s\n' "$@" | grep . >"$FAKE_RUNNING" || : >"$FAKE_RUNNING"
    fail_since=0 ok_since=0 stopped_for_failure=false boot_recovery_done=false storage_seen_ok=false
    watchdog_storage_nas_ok() { fake_nas_ok; }
}
tick() { # $1 = ok|bad
    printf '%s\n' "$1" >"$NAS_FLAG"
    watchdog_tick >/dev/null 2>&1
}
ups() { grep '^compose up -d ' "$FAKE_LOG" | awk '{print $NF}' | paste -sd' '; }
stops() { grep '^compose stop ' "$FAKE_LOG" | awk '{print $3}' | paste -sd' '; }
recorded() { [[ -f "$STOPPED_SERVICES_FILE" ]] && sort "$STOPPED_SERVICES_FILE" | paste -sd' '; }
running() { sort "$FAKE_RUNNING" | paste -sd' '; }
# Running data services only: starting sonarr also starts jackett, as Compose does.
running_data() { sort "$FAKE_RUNNING" | grep -Fx -f <(printf '%s\n' "${ALL_SERVICES[@]}") | paste -sd' '; }
intent() { service_intent_list | paste -sd' '; }
sorted() { tr ' ' '\n' <<<"$*" | sort | paste -sd' '; }
without() { # $1 = space list, $2.. = names to drop
    local list=" $1 " n
    shift
    for n in "$@"; do list="${list/ $n / }"; done
    echo "$list" | xargs
}
intent_raw() { printf '%b' "$1" >"$INTENT_FILE"; }

# --- 1. Manual stop, then boot reconciliation ---
# Given the host just booted, nothing runs, and the user had stopped jellyfin
# When storage is stable and the watchdog reconciles, and again on the next poll
# Then all but jellyfin start, seerr without it via --no-deps, and the intent entry survives
fresh
service_intent_record jellyfin
tick ok
assert_eq "qbittorrent radarr seerr sonarr unpackerr" "$(running_data)" "boot reconcile: seerr starts without jellyfin, which stays stopped"
assert_contains "$(<"$TMP_DIR/watchdog.log")" "starting seerr without jellyfin, which you stopped" "boot reconcile: logs why the dependent starts alone"
assert_contains "$(<"$FAKE_LOG")" "up -d --no-deps seerr" "boot reconcile: the dependent uses --no-deps"
tick ok
assert_eq "jellyfin" "$(intent)" "boot reconcile: the intent entry survives the next poll"
assert_eq "qbittorrent radarr seerr sonarr unpackerr" "$(running_data)" "boot reconcile: the next poll starts nothing more"
assert_contains "$(grep ' config ' "$FAKE_LOG")" "--profile *" "dependencies: the graph is read with every profile enabled, so bazarr is included"

# Given five services run and the user had stopped jellyfin
# When the watchdog reconciles after its own restart
# Then jellyfin stays stopped
fresh unpackerr qbittorrent sonarr radarr seerr
service_intent_record jellyfin
tick ok
assert_eq "" "$(ups)" "boot reconcile: a partial set with the user's stop is left alone"
assert_eq "" "$(running | grep -o jellyfin)" "boot reconcile: the user-stopped service is still stopped"

# --- 2. Manual stop, then outage and recovery ---
# Given storage was healthy, the user stopped jellyfin, the rest run
# When NAS fails (watchdog stops the rest) and then recovers
# Then the rest are restarted and jellyfin stays stopped
fresh unpackerr qbittorrent sonarr radarr seerr
service_intent_record jellyfin
tick ok
tick bad
assert_eq "$(sorted "$(without "$ALL" jellyfin)")" "$(sorted "$(stops)")" "outage: stops the running services only"
tick ok
assert_eq "$(sorted "$(without "$ALL" jellyfin)")" "$(running_data)" "recovery: restarts what the watchdog stopped, including seerr, not the user's stop"
assert_eq "" "$(running | grep -o jellyfin)" "recovery: the user-stopped service is still stopped"

# --- 3. Watchdog stop, then recovery ---
# Given every service runs and the user stopped nothing
# When NAS fails and recovers
# Then the watchdog records what it stopped, restarts all of it, and clears its state
fresh "${ALL_SERVICES[@]}"
tick ok
tick bad
assert_eq "$(sorted "$ALL")" "$(recorded)" "outage: records the service names the watchdog stopped"
assert_eq "yes" "$([[ -s "$STATE_FILE" ]] && echo yes)" "outage: writes the stopped timestamp the launcher shows"
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "recovery: restarts every service the watchdog stopped, so the stack is running again"
assert_eq "no" "$([[ -e $STATE_FILE || -e $STOPPED_SERVICES_FILE ]] && echo yes || echo no)" "recovery: clears the stopped state"

# --- 4. Partial outage ---
# Given storage was verified, then four services were stopped by direct Docker commands
# When NAS fails and recovers
# Then only the two that ran are stopped and restarted
fresh "${ALL_SERVICES[@]}"
tick ok
printf '%s\n' sonarr jellyfin >"$FAKE_RUNNING"
tick bad
assert_eq "jellyfin sonarr" "$(recorded)" "partial outage: records only the services that were running"
tick ok
assert_eq "sonarr jellyfin" "$(ups)" "partial outage: restarts only the services the watchdog stopped"

# --- 5. Host boots while the NAS is down ---
# Given the host booted with nothing running and the user had stopped jellyfin
# When NAS stays down, then comes up
# Then nothing starts while it is down, and afterwards all but jellyfin start
fresh
service_intent_record jellyfin
tick bad
tick bad
assert_eq "" "$(ups)" "boot with NAS down: starts nothing while storage is unavailable"
tick ok
assert_eq "$(sorted "$(without "$ALL" jellyfin)")" "$(running_data)" "boot with NAS down: starts the data services but not the user's stop once NAS is stable"

# --- 6. Intent file edge cases (cold boot, storage stable) ---
# Given the file is missing / empty
fresh
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "intent missing: starts every data service"
fresh
: >"$INTENT_FILE"
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "intent empty: starts every data service"

# Given a file with damaged lines around one valid name
# Then the damaged lines are ignored and only the valid name is honoured
MALFORMED='  jellyfin\nJELLYFIN\n../etc/passwd\na b\n\n$(touch /tmp/x)\nradarr\n'"$(printf 'x%.0s' {1..100})"'\n'
fresh
intent_raw "$MALFORMED"
assert_eq "radarr" "$(service_intent_list)" "intent malformed: reading the file returns only valid names"
tick ok
assert_eq "$(sorted "$(without "$ALL" radarr)")" "$(running_data)" "intent malformed: damaged lines are ignored, valid names are honoured"

# Given names that are not data services of this install (unknown, or disabled bazarr)
# Then they are ignored and the real entry still applies
fresh
intent_raw 'notaservice\nbazarr\nsonarr\n'
tick ok
assert_eq "$(sorted "$(without "$ALL" sonarr)")" "$(running_data)" "intent unknown names: ignored, no error, other entries honoured"

# Given the intent file cannot be read as a file (a directory in its place)
# When storage is stable
# Then nothing starts and the pending recovery is kept; once readable it completes
fresh "${ALL_SERVICES[@]}"
tick ok
tick bad
rm -f "$INTENT_FILE"
mkdir "$INTENT_FILE"
: >"$FAKE_LOG"
tick ok
assert_eq "" "$(ups)" "intent unreadable: starts nothing after an outage"
assert_eq "yes" "$([[ -s $STATE_FILE ]] && echo yes)" "intent unreadable: keeps the pending recovery state"
rmdir "$INTENT_FILE"
tick ok
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "intent unreadable: recovery completes once the file is readable"
fresh
mkdir "$INTENT_FILE"
tick ok
assert_eq "" "$(ups)" "intent unreadable: starts nothing at boot reconciliation"

# --- 6b. A service that depends on a stopped one starts without it ---
# Given the user stopped qbittorrent, and nothing runs
# When storage is stable
# Then everything but qbittorrent starts, each dependent with --no-deps, and qbittorrent stays stopped
fresh
service_intent_record qbittorrent
tick ok
assert_eq "jellyfin radarr seerr sonarr unpackerr" "$(running)" "dependency: dependents start and the user's stop is not started as a side effect"
assert_contains "$(<"$TMP_DIR/watchdog.log")" "starting unpackerr without qbittorrent, which you stopped" "dependency: a transitive dependent is started and named"

# Given the user stopped sonarr while the rest ran, then NAS fails and recovers
# Then unpackerr and seerr (dependents of sonarr) run again, sonarr stays stopped, the intent is intact
fresh unpackerr qbittorrent radarr seerr jellyfin
service_intent_record sonarr
tick ok
tick bad
tick ok
tick ok
assert_eq "jellyfin qbittorrent radarr seerr unpackerr" "$(running_data)" "dependency, outage: unpackerr and seerr return while sonarr stays stopped"
assert_eq "sonarr" "$(intent)" "dependency, outage: the intent still names sonarr after later polls"

# Given the user stopped jellyfin and the Compose configuration cannot be read, after an outage
# Then nothing starts and the pending recovery is kept; once readable it completes
fresh "${ALL_SERVICES[@]}"
tick ok
tick bad
service_intent_record jellyfin
touch "$FAKE_CONFIG_BROKEN"
: >"$FAKE_LOG"
tick ok
assert_eq "" "$(ups)" "config unreadable: starts nothing"
assert_eq "yes" "$([[ -s $STATE_FILE ]] && echo yes)" "config unreadable: keeps the pending recovery state"
assert_contains "$(<"$TMP_DIR/watchdog.log")" "cannot read the Compose configuration" "config unreadable: logs why nothing started"
rm -f "$FAKE_CONFIG_BROKEN"
tick ok
tick ok
assert_eq "$(sorted "$(without "$ALL" jellyfin)")" "$(running_data)" "config unreadable: recovery completes once it is readable"

# Given the user stopped nothing, the graph is not needed: every service starts without it
fresh
touch "$FAKE_CONFIG_BROKEN"
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "config unreadable, no user stop: starts every data service"

# Given the fake graph, then it equals the direct depends_on edges in docker-compose.yml
real_graph=$(python3 -I -c '
import sys, yaml
with open(sys.argv[1]) as f:
    services = yaml.safe_load(f)["services"]
for name in sys.argv[2:]:
    print(name, *sorted(services[name].get("depends_on") or []))
' "$REPO_ROOT/docker-compose.yml" bazarr radarr seerr sonarr unpackerr)
assert_eq "$DEPS_GRAPH" "$real_graph" "dependencies: the fake graph matches docker-compose.yml"

# --- 7. Storage checks gate every start, whatever the intent file holds ---
for variant in missing empty malformed unreadable; do
    fresh
    case "$variant" in empty) : >"$INTENT_FILE" ;; malformed) intent_raw "$MALFORMED" ;; unreadable) mkdir "$INTENT_FILE" ;; esac
    tick bad
    tick bad
    assert_eq "" "$(ups)" "storage down: intent $variant never starts a service"
done

# Given the real mount check and a mount that is not the expected export
# When the watchdog polls
# Then it never starts a service
fresh
watchdog_storage_nas_ok() { real_watchdog_storage_nas_ok; }
MOUNT_SOURCE="198.51.100.9:/exports/other"
findmnt() { case "$*" in *"-o SOURCE"*) echo "$MOUNT_SOURCE" ;; *"-o FSTYPE"*) echo nfs4 ;; esac }
mkdir -p "$TMP_DIR/mnt"
touch "$STORAGE_SENTINEL"
tick ok
assert_eq "" "$(ups)" "mount identity: a wrong live mount starts nothing"

# Given the expected mount but no sentinel
rm -f "$STORAGE_SENTINEL"
MOUNT_SOURCE="$STORAGE_EXPECTED_SOURCE"
tick ok
assert_eq "" "$(ups)" "sentinel: a missing sentinel starts nothing"

# Given the expected mount and the sentinel (positive control)
touch "$STORAGE_SENTINEL"
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "mount identity and sentinel: both passing starts the data services"
unset -f findmnt

# --- 8. A running service outranks a stale intent entry ---
# Given the user stopped jellyfin, then something else (update, docker start) started it
# When the watchdog polls, and NAS later fails and recovers
# Then the stale entry is dropped and jellyfin is restarted with the others
fresh "${ALL_SERVICES[@]}"
service_intent_record jellyfin
tick ok
assert_eq "" "$(intent)" "stale intent: dropped once the service is seen running"
tick bad
tick ok
assert_eq "$(sorted "$ALL")" "$(running_data)" "stale intent: the service is restarted after the outage"

# --- 9. Launcher hooks ---
launcher() { # $1 = action, env: CHOICE DOCKER_RC GUARD_RC; prints nothing
    T="$LTMP" STORAGE_MODE="${MODE:-nas}" CHOICE="${CHOICE:-jellyfin}" DOCKER_RC="${DOCKER_RC:-0}" GUARD_RC="${GUARD_RC:-0}" \
        MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" ACTION="$1" bash -c '
        source "$REPO_ROOT/mediastack" </dev/null
        SCRIPT_DIR="$T"
        launcher_pause_for_menu() { :; }; ui_log() { :; }; _show_action_result() { :; }
        profiles_build_args() { :; }; ui_confirm() { return 0; }; _compose_project_name() { echo ""; }
        ui_choose() { echo "$CHOICE"; }; storage_guard_before_start() { return "$GUARD_RC"; }
        docker() { case "$*" in *"ps --filter status="*) echo "$CHOICE" ;; *"ps -aq"*) echo c1 ;; *) return "$DOCKER_RC" ;; esac; }
        "$ACTION"
    ' >/dev/null 2>&1
}
LTMP="$TMP_DIR/launcher"
LINTENT="$LTMP/config/state/user-stopped-services"
launcher_intent() { SCRIPT_DIR="$LTMP" service_intent_list | paste -sd' '; }
launcher_reset() {
    rm -rf "$LTMP"
    mkdir -p "$LTMP/config/state"
    [[ -z "${1:-}" ]] || printf '%s\n' "$@" >"$LINTENT"
}

# Given the user stops jellyfin from the menu
# Then the stop is recorded; a failed stop records nothing
launcher_reset
CHOICE=jellyfin launcher action_service_stop
assert_eq "jellyfin" "$(launcher_intent)" "launcher: Stop a service records the service"
launcher_reset
CHOICE=jellyfin DOCKER_RC=1 launcher action_service_stop
assert_eq "" "$(launcher_intent)" "launcher: a failed Stop a service records nothing"

# Given a local-storage install, which has no watchdog
# When the user stops a service
# Then no intent file is written
launcher_reset
MODE=local CHOICE=jellyfin launcher action_service_stop
assert_eq "no" "$([[ -e $LINTENT ]] && echo yes || echo no)" "launcher: a local install keeps no intent file"

# Given jellyfin and radarr are recorded as stopped
# When the user starts jellyfin
# Then only jellyfin is cleared; a refused or failed start clears nothing
launcher_reset jellyfin radarr
CHOICE=jellyfin launcher action_service_start
assert_eq "radarr" "$(launcher_intent)" "launcher: Start a service clears that service only"
launcher_reset jellyfin radarr
CHOICE=jellyfin GUARD_RC=1 launcher action_service_start
assert_eq "jellyfin radarr" "$(launcher_intent)" "launcher: a start refused by the NAS guard keeps the intent"
CHOICE=jellyfin DOCKER_RC=1 launcher action_service_start
assert_eq "jellyfin radarr" "$(launcher_intent)" "launcher: a failed start keeps the intent"

# Given Stop all, then Start all
# Then Stop all records the whole data-service set and Start all clears it
launcher_reset
launcher action_stack_stop
assert_eq "$(sorted "$ALL")" "$(launcher_intent)" "launcher: Stop all records the whole data-service set"
launcher action_stack_start
assert_eq "" "$(launcher_intent)" "launcher: Start all clears every entry"

# --- 10. The file is replaced atomically and writers do not lose each other's entries ---
export SCRIPT_DIR="$TMP_DIR/atomic"
rm -rf "$SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/config/state"
# Given 24 writers record different services at once
# Then every entry survives and no temp file is left behind
for i in $(seq -w 1 24); do service_intent_record "svc$i" & done
wait
assert_eq "24" "$(service_intent_list | wc -l | tr -d ' ')" "intent file: concurrent writers lose no entries"
assert_eq "0" "$(find "$SCRIPT_DIR/config/state" -name '.user-stopped-services.*' | wc -l | tr -d ' ')" "intent file: no temp file is left behind"

# Given a reader polls while a writer adds 60 entries
# Then the reader only ever sees a complete file that never loses entries
rm -f "$(service_intent_file)"
(
    for i in $(seq 1 60); do service_intent_record "grow$(printf '%02d' "$i")"; done
    touch "$TMP_DIR/writer-done"
) &
rm -f "$TMP_DIR/writer-done"
seen_max=0 shrank=no torn=no
while [[ ! -e "$TMP_DIR/writer-done" ]]; do
    f="$(service_intent_file)"
    [[ -f "$f" ]] || continue
    content="$(cat "$f" 2>/dev/null)"
    n=$(grep -c . <<<"$content")
    ((n < seen_max)) && shrank=yes
    ((n > seen_max)) && seen_max=$n
    grep -Evq '^grow[0-9]{2}$' <<<"$content" && [[ -n "$content" ]] && torn=yes
done
wait
assert_eq "no" "$shrank" "intent file: a concurrent reader never sees entries disappear"
assert_eq "no" "$torn" "intent file: a concurrent reader never sees a partial line"
assert_eq "60" "$(service_intent_list | wc -l | tr -d ' ')" "intent file: all entries from the writer are present"

# --- 11. Uninstall removes the intent file with the rest of config/ ---
# Given an intent file under config/state and a config/examples directory
# When the uninstall wipe of config/ runs
# Then the intent file is gone and examples/ is kept
wipe_out=$(REPO_ROOT="$REPO_ROOT" TMP_DIR="$TMP_DIR" bash -c '
    source "$REPO_ROOT/setup.sh"
    set +eu
    log_ok() { :; }; sudo() { "$@"; }
    SCRIPT_DIR="$TMP_DIR/wipe"
    mkdir -p "$SCRIPT_DIR/config/state" "$SCRIPT_DIR/config/examples"
    printf "jellyfin\n" >"$SCRIPT_DIR/config/state/user-stopped-services"
    wipe_config_runtime
    [[ -e "$SCRIPT_DIR/config/state/user-stopped-services" ]] && echo INTENT_KEPT || echo INTENT_GONE
    [[ -d "$SCRIPT_DIR/config/examples" ]] && echo EXAMPLES_KEPT
' 2>&1)
assert_contains "$wipe_out" "INTENT_GONE" "uninstall: config wipe removes the intent file"
assert_contains "$wipe_out" "EXAMPLES_KEPT" "uninstall: config wipe keeps config/examples"

# --- 12. NAS data services keep restart "no" in the generated override ---
# Given a NAS install
# When the compose override is generated
# Then every data service has restart "no", so Docker cannot start it before the watchdog checks storage
restart_out=$(REPO_ROOT="$REPO_ROOT" bash -c '
    set -uo pipefail
    tmp=$(mktemp -d); mkdir -p "$tmp/docs/operations" "$tmp/config/state"
    SCRIPT_DIR="$tmp"; HOST_MEMORY_MB=8192; STORAGE_MODE=nas; IMAGE_CHANNEL=latest
    log_warn() { :; }; log_ok() { :; }; log_error() { echo "ERR $*"; }
    source "$REPO_ROOT/scripts/setup/override.sh"
    generate_override none
    awk "/^  [a-z0-9-]+:\$/ {svc=\$1} /^    restart: \"no\"\$/ {print svc}" "$tmp/docker-compose.override.yml" | tr -d ":" | sort | paste -sd" "
    rm -rf "$tmp"
' 2>&1)
assert_eq "$(sorted "$ALL bazarr")" "$restart_out" "NAS override: every data service has restart \"no\""

# --- 13. A stop the user records while the watchdog works is not overridden (hooks run inside the fake docker) ---
STOP_JELLYFIN='docker compose stop jellyfin; bash -c "source \$REPO_ROOT/scripts/lib/service-intent.sh; service_intent_record jellyfin"'
SCRIPT_DIR="$TMP_DIR/root"
export REPO_ROOT SCRIPT_DIR
# Given an outage recovery in progress
# When the user stops jellyfin after the unpackerr start, before jellyfin's and seerr's
# Then jellyfin stays stopped, seerr starts without it, and the entry survives
fresh "${ALL_SERVICES[@]}"
tick ok
tick bad
export FAKE_UP_SVC=unpackerr FAKE_UP_HOOK="$STOP_JELLYFIN"
tick ok
unset FAKE_UP_SVC FAKE_UP_HOOK
assert_eq "$(sorted "$(without "$ALL" jellyfin)")" "$(running_data)" "stop during start loop: the service stays stopped and its dependent starts without it"
tick ok
assert_eq "jellyfin" "$(intent)" "stop during start loop: the intent entry survives the next poll"

# Given jellyfin runs with a stale intent entry
# When the user stops it again between the running snapshot and the clearing
# Then the entry is kept
fresh "${ALL_SERVICES[@]}"
service_intent_record jellyfin
export FAKE_PS_HOOK="$STOP_JELLYFIN"
tick ok
unset FAKE_PS_HOOK
assert_eq "jellyfin" "$(intent)" "stop after the snapshot: the intent entry is kept"

echo -e "${CYAN}◀ watchdog-intent done${NC}"
summary

#!/usr/bin/env bash
# tests/unit/beszel-system.sh
# How MediaStack's own Beszel system entry follows the agent from a TCP port to
# a unix socket: new installs register the socket, an existing install's exact
# old entry is moved, and any other entry is the user's and is left alone.
set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="beszel-system"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
WRITES="$TMP_DIR/writes.log"

CONFIG_FILE=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/services/beszel/main.sh"

LOGGED=""
log_ok() { LOGGED+="OK: $1"$'\n'; }
log_skip() { LOGGED+="SKIP: $1"$'\n'; }
log_warn() { LOGGED+="WARN: $1"$'\n'; }
log_drift() { LOGGED+="DRIFT: $1"$'\n'; }
service_local_url() { printf 'http://localhost:8090'; }
sleep() { :; }

# Fake hub. Login succeeds; GET systems returns SYSTEMS_JSON; every write is
# logged as "<method> <url> <body>" and answers HTTP WRITE_CODE.
SYSTEMS_JSON='{"items":[]}'
WRITE_CODE=200
curl_data_stdin() { printf '{"token":"tok","record":{"id":"user1"}}\n200'; }
curl_header_stdin() { printf '%s' "$SYSTEMS_JSON"; }
curl_header_data_stdin() {
    local data="$3" method="" url="" prev=""
    shift 3
    local arg
    for arg in "$@"; do
        [[ "$prev" == "-X" ]] && method="$arg"
        [[ "$arg" == http* ]] && url="$arg"
        prev="$arg"
    done
    printf '%s %s %s\n' "$method" "$url" "$data" >>"$WRITES"
    printf '{}\n%s' "$WRITE_CODE"
}

run_sync() {
    : >"$WRITES"
    LOGGED=""
    BESZEL_TOKEN=tok BESZEL_USER_ID=user1 beszel_sync_local_system http://localhost:8090
    SYNC_RC=$?
}

SOCKET="/beszel_data/socket/beszel.sock"

# Given a hub with no MediaStack system
# When the local system is synced
# Then it is registered on the agent's unix socket
SYSTEMS_JSON='{"items":[]}'
run_sync
assert_contains "$(cat "$WRITES")" "POST http://localhost:8090/api/collections/systems/records" "new install: the system is created"
assert_contains "$(cat "$WRITES")" "\"host\": \"$SOCKET\"" "new install: the host is the socket path"
assert_not_contains "$(cat "$WRITES")" "45876" "new install: no TCP port is registered"

# Given a hub holding MediaStack's old entry, exactly host.docker.internal:45876
# When the local system is synced
# Then that record's host is moved to the socket
SYSTEMS_JSON='{"items":[{"id":"rec1","name":"MediaStack","host":"host.docker.internal","port":"45876"}]}'
run_sync
assert_contains "$(cat "$WRITES")" "PATCH http://localhost:8090/api/collections/systems/records/rec1 {\"host\": \"$SOCKET\"}" "existing install: the old entry is patched to the socket"
assert_contains "$LOGGED" "OK: Beszel system 'MediaStack' moved" "existing install: the move is reported"
assert_eq "0" "$SYNC_RC" "existing install: a successful move returns 0"

# Given a hub whose MediaStack entry points somewhere else (a different port)
# When the local system is synced
# Then nothing is written and the drift is reported
SYSTEMS_JSON='{"items":[{"id":"rec2","name":"MediaStack","host":"host.docker.internal","port":"45999"}]}'
run_sync
assert_eq "" "$(cat "$WRITES")" "foreign entry: nothing is written"
assert_contains "$LOGGED" "DRIFT: Beszel system 'MediaStack' was changed outside MediaStack" "foreign entry: reported as drift"

# Given a hub whose MediaStack entry has the right port on another host
# When the local system is synced
# Then it is not an exact match: nothing is written
SYSTEMS_JSON='{"items":[{"id":"rec3","name":"MediaStack","host":"192.168.1.9","port":"45876"}]}'
run_sync
assert_eq "" "$(cat "$WRITES")" "other host on 45876: nothing is written"
assert_contains "$LOGGED" "DRIFT:" "other host on 45876: reported as drift"

# Given a hub whose MediaStack entry already uses the socket
# When the local system is synced
# Then nothing is written
SYSTEMS_JSON="{\"items\":[{\"id\":\"rec4\",\"name\":\"MediaStack\",\"host\":\"$SOCKET\",\"port\":\"\"}]}"
run_sync
assert_eq "" "$(cat "$WRITES")" "migrated entry: a re-run writes nothing"
assert_contains "$LOGGED" "SKIP: Beszel system 'MediaStack' already registered" "migrated entry: a re-run skips"

# Given the hub rejects the move
# When the local system is synced
# Then the failure is reported and the sync fails
SYSTEMS_JSON='{"items":[{"id":"rec1","name":"MediaStack","host":"host.docker.internal","port":"45876"}]}'
WRITE_CODE=400
run_sync
assert_contains "$LOGGED" "WARN: Beszel system migration returned HTTP 400" "rejected move: warned"
assert_eq "1" "$SYNC_RC" "rejected move: the sync fails"
WRITE_CODE=200

# ---------------------------------------------------------------------------
# Converge wiring: scripts/launcher/converge.sh runs the Beszel step on update.
# ---------------------------------------------------------------------------
# Given an existing install whose hub holds the old entry
# When the day-2 converge step for Beszel runs
# Then the old entry is moved
DOCKER_RESTARTS=""
DOCKER_RESTART_RC=0
docker() {
    case "$*" in
        "inspect beszel") return 0 ;;
        "restart beszel")
            DOCKER_RESTARTS+="${DOCKER_RESTARTS:+;}restart beszel"
            return "$DOCKER_RESTART_RC"
            ;;
        *"State.Health"*) echo healthy ;;
    esac
}
SYSTEMS_JSON='{"items":[{"id":"rec1","name":"MediaStack","host":"host.docker.internal","port":"45876"}]}'
: >"$WRITES"
LOGGED=""
NPM_ADMIN_EMAIL=admin@example.com JELLYFIN_ADMIN_PASSWORD=pw beszel_converge_local_system
assert_contains "$(cat "$WRITES")" "PATCH" "converge: the old entry is moved"
assert_eq "restart beszel" "$DOCKER_RESTARTS" "converge: the moved entry restarts the hub exactly once"

# Given the entry already points at the socket
# When the day-2 converge step runs
# Then the hub is not restarted
SYSTEMS_JSON='{"items":[{"id":"rec1","name":"MediaStack","host":"/beszel_data/socket/beszel.sock","port":""}]}'
DOCKER_RESTARTS=""
NPM_ADMIN_EMAIL=admin@example.com JELLYFIN_ADMIN_PASSWORD=pw beszel_converge_local_system
assert_eq "" "$DOCKER_RESTARTS" "converge: an entry already on the socket leaves the hub running"

# Given the entry is moved but the restart fails
# When the day-2 converge step runs
# Then it returns non-zero with a message
SYSTEMS_JSON='{"items":[{"id":"rec1","name":"MediaStack","host":"host.docker.internal","port":"45876"}]}'
DOCKER_RESTART_RC=1
LOGGED=""
NPM_ADMIN_EMAIL=admin@example.com JELLYFIN_ADMIN_PASSWORD=pw beszel_converge_local_system
assert_eq "1" "$?" "converge: a failed hub restart fails the step"
assert_contains "$LOGGED" "WARN: Could not restart the Beszel hub" "converge: a failed hub restart is reported"
DOCKER_RESTART_RC=0

# Given the converge action
# When the admin-port filter and qBittorrent steps have run
# Then the Beszel step runs too
SCRIPT_DIR="$REPO_ROOT"
# converge_mediastack_state sources hardening.sh unless it is already loaded, and that would
# replace the stubs below with the real functions, which install files and run sudo. Load it first.
# shellcheck source=../../scripts/setup/hardening.sh
source "$REPO_ROOT/scripts/setup/hardening.sh"
# shellcheck source=../../scripts/launcher/converge.sh
source "$REPO_ROOT/scripts/launcher/converge.sh"
setup_admin_filter() { return 0; }
ufw_remove_legacy_beszel_rule() { return 0; }
setup_ufw_wireguard_clients() { return 0; }
converge_storage_watchdog() { return 0; }
qbt_narrow_legacy_whitelist() { return 0; }
BESZEL_STEP_CALLS=0
beszel_converge_local_system() {
    BESZEL_STEP_CALLS=$((BESZEL_STEP_CALLS + 1))
    return 0
}
converge_mediastack_state
assert_eq "1" "$BESZEL_STEP_CALLS" "converge_mediastack_state: runs the Beszel step"

# Given the Beszel step fails
# When the converge action runs
# Then it returns non-zero
beszel_converge_local_system() { return 1; }
converge_mediastack_state
assert_eq "1" "$?" "converge_mediastack_state: a failed Beszel step fails the action"

scenario_end "$CURRENT_SCENARIO"
summary

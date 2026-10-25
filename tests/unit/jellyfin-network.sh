#!/usr/bin/env bash
# tests/unit/jellyfin-network.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="jellyfin-network"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
REAL_PORT_FILE="$TMP_DIR/port"
REAL_MODE_FILE="$TMP_DIR/mode"
REAL_MARKER_FILE="$TMP_DIR/marker"
REAL_REQUEST_FILE="$TMP_DIR/requests"
REAL_BARRIER_FILE="$TMP_DIR/barrier"
REAL_SERVER_PID=""
REAL_BARRIER_PID=""
_JELLYFIN_SERVICE_DIR="$REPO_ROOT/scripts/services/jellyfin"
SCRIPT_DIR="$TMP_DIR"

cleanup_fixture() {
    if [[ -n "$REAL_BARRIER_PID" ]]; then
        kill "$REAL_BARRIER_PID" 2>/dev/null || true
        wait "$REAL_BARRIER_PID" 2>/dev/null || true
        REAL_BARRIER_PID=""
    fi
    if [[ -n "$REAL_SERVER_PID" ]]; then
        kill "$REAL_SERVER_PID" 2>/dev/null || true
        wait "$REAL_SERVER_PID" 2>/dev/null || true
        REAL_SERVER_PID=""
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup_fixture EXIT

source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/services/jellyfin/network.sh"
REAL_CURL_HEADER_STDIN=$(declare -f curl_header_stdin)
REAL_NETWORK_NOW=$(declare -f configure_jellyfin_network_now)

log_info() { :; }
log_ok() { :; }
log_skip() { :; }
log_warn() { WARNINGS+=("$1"); }
log_drift() { :; }
docker() { return 0; }
env_save_api_key() { :; }
api_fetch_auth() {
    if [[ " $* " == *" -X POST "* ]]; then
        return 0
    fi
    printf '%s\n' "$NETWORK_CONFIG"
}

# Observe retry entry without changing real sleep or fixture scheduling.
READY_SLEEP_COUNT=0
sleep() {
    if [[ "${RECORD_READY_SLEEP:-}" == "1" ]]; then
        READY_SLEEP_COUNT=$((READY_SLEEP_COUNT + 1))
    fi
    command sleep "$@"
}

WARNINGS=()
NETWORK_CONFIG='{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'

start_real_server() {
    printf 'loading' >"$REAL_MODE_FILE"
    printf '0' >"$REAL_REQUEST_FILE"
    rm -f "$REAL_PORT_FILE" "$REAL_MARKER_FILE" "$REAL_BARRIER_FILE"
    python3 - "$REAL_PORT_FILE" "$REAL_MODE_FILE" "$REAL_MARKER_FILE" "$REAL_REQUEST_FILE" <<'PY' >/dev/null 2>&1 &
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, mode_file, marker_file, request_file = map(pathlib.Path, sys.argv[1:])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Degraded")
            return
        if self.path != "/System/Configuration/network":
            self.send_error(404)
            return
        request_file.write_text(str(int(request_file.read_text()) + 1))
        if self.headers.get("Authorization", "") != 'MediaBrowser Client="MediaStack", Device="Setup", DeviceId="mediastack-setup", Version="1.0", Token="token"':
            self.send_error(401)
            return
        mode = mode_file.read_text()
        if mode == "loading":
            marker_file.write_text("observed")
            self.send_error(503)
            return
        if mode == "forbidden":
            self.send_error(403)
            return
        if mode == "malformed":
            body = b"{"
        elif mode == "missing":
            body = b'{"KnownProxies":[]}'
        elif mode == "wrong-type":
            body = b'{"KnownProxies":"bad","PublishedServerUriBySubnet":[]}'
        elif mode == "non-object":
            body = b"[]"
        elif mode == "slow":
            body = b'{"KnownProxies":[],"PublishedServerUriBySubnet":[]}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body[:10])
            self.wfile.flush()
            time.sleep(2)
            self.wfile.write(body[10:])
            return
        else:
            body = b'{"KnownProxies":[],"PublishedServerUriBySubnet":[]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
PY
    REAL_SERVER_PID=$!
    for _ in $(seq 1 50); do
        [[ -s "$REAL_PORT_FILE" ]] && return 0
        sleep 0.02
    done
    return 1
}

stop_real_server() {
    [[ -n "$REAL_SERVER_PID" ]] || return 0
    kill "$REAL_SERVER_PID" 2>/dev/null || true
    wait "$REAL_SERVER_PID" 2>/dev/null || true
    REAL_SERVER_PID=""
}

real_url() { printf 'http://127.0.0.1:%s' "$(<"$REAL_PORT_FILE")"; }
real_elapsed_ms() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }

start_ready_barrier() {
    (
        for _ in $(seq 1 50); do
            if [[ -e "$REAL_MARKER_FILE" ]]; then
                sleep 0.05
                printf 'ready' >"$REAL_MODE_FILE"
                printf 'observed' >"$REAL_BARRIER_FILE"
                exit 0
            fi
            sleep 0.02
        done
        printf 'timeout' >"$REAL_BARRIER_FILE"
        exit 1
    ) &
    REAL_BARRIER_PID=$!
}

wait_ready_barrier() {
    wait "$REAL_BARRIER_PID"
    local rc=$?
    REAL_BARRIER_PID=""
    return "$rc"
}

if [[ -n "${JELLYFIN_NETWORK_SOURCE:-}" ]]; then
    source "$JELLYFIN_NETWORK_SOURCE"
fi

if [[ "${JELLYFIN_NETWORK_CLEANUP_PROBE:-}" == "1" ]]; then
    start_real_server
    start_ready_barrier
    curl -sS -H 'Authorization: MediaBrowser Client="MediaStack", Device="Setup", DeviceId="mediastack-setup", Version="1.0", Token="token"' \
        "$(real_url)/System/Configuration/network" >/dev/null
    exit 0
fi

# Given a child fixture that exits after its barrier observes a request.

# When the child runs and its cleanup kills and waits for that barrier.
cleanup_output=$(JELLYFIN_NETWORK_CLEANUP_PROBE=1 bash "$0" 2>&1)
cleanup_rc=$?

# Then cleanup succeeds and the reaped barrier cannot write into its removed directory.
assert_eq "0" "$cleanup_rc" "Jellyfin networking readiness fixture cleanup exits successfully"
assert_not_contains "$cleanup_output" "No such file or directory" "Jellyfin networking readiness fixture cleanup reaps the barrier"

# Given a real server with degraded health while the typed API is still loading.
printf 'JELLYFIN_PUBLISHED_URL=https://jellyfin.fresh.test\n' >"$TMP_DIR/.env"
WARNINGS=()
start_real_server
start_ready_barrier

# When the skipped-policy recreate caller runs.
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 \
    configure_jellyfin_networking "$(real_url)" "token"
caller_mode=$(<"$REAL_MODE_FILE")
wait_ready_barrier
barrier_rc=$?

# Then it waits for the authenticated typed read and its barrier observed that read.
assert_eq "ready" "$caller_mode" "Jellyfin networking real caller waits past degraded health"
assert_eq "0" "$barrier_rc" "Jellyfin networking readiness barrier completes"
assert_eq "observed" "$(<"$REAL_BARRIER_FILE")" "Jellyfin networking readiness barrier observes a request"
assert_eq "" "${WARNINGS[*]:-}" "Jellyfin networking real caller does not warn after typed readiness"
stop_real_server

if [[ -n "${JELLYFIN_NETWORK_SOURCE:-}" ]]; then
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit "$FAIL_COUNT"
fi

# Given a barrier that observes no network request.
start_real_server
start_ready_barrier

# When its bounded observation period expires.
wait_ready_barrier
barrier_rc=$?

# Then it records the timeout and does not release readiness.
assert_eq "1" "$barrier_rc" "Jellyfin networking readiness barrier fails without a request"
assert_eq "timeout" "$(<"$REAL_BARRIER_FILE")" "Jellyfin networking readiness barrier records its timeout"
assert_eq "loading" "$(<"$REAL_MODE_FILE")" "Jellyfin networking readiness barrier never writes ready after timeout"
stop_real_server

# Given a valid typed response that completes after the absolute deadline.
READY_CLOCK_FILE="$TMP_DIR/readiness-clock"
READY_CLOCK_VALUES=(0 0 1001)
printf '0' >"$READY_CLOCK_FILE"
configure_jellyfin_network_now() {
    local index
    index=$(<"$READY_CLOCK_FILE")
    printf '%s' "${READY_CLOCK_VALUES[$index]}"
    printf '%s' "$((index + 1))" >"$READY_CLOCK_FILE"
}
curl_header_stdin() {
    local arg out_file="" next=false
    for arg in "$@"; do
        if [[ "$next" == "true" ]]; then
            out_file="$arg"
            next=false
        elif [[ "$arg" == "-o" ]]; then
            next=true
        fi
    done
    printf '%s' '{"KnownProxies":[],"PublishedServerUriBySubnet":[]}' >"$out_file"
    printf '200'
}

# When readiness validates the response under a one-second budget.
configure_jellyfin_network_ready "http://localhost:8096" "token" 1
rc=$?

# Then it rejects the late success.
assert_eq "1" "$rc" "Jellyfin network readiness rejects late typed success"
eval "$REAL_CURL_HEADER_STDIN"
eval "$REAL_NETWORK_NOW"

# Given a valid empty typed policy.
start_real_server
printf 'ready' >"$REAL_MODE_FILE"

# When readiness checks it.
configure_jellyfin_network_ready "$(real_url)" "token" 1
rc=$?

# Then it succeeds with one request.
assert_eq "0" "$rc" "Jellyfin network readiness accepts valid empty arrays"
assert_eq "1" "$(<"$REAL_REQUEST_FILE")" "Jellyfin network readiness requests valid policy once"
stop_real_server

# Given permanent HTTP and invalid typed responses.
for mode in forbidden malformed missing wrong-type non-object; do
    start_real_server
    printf '%s' "$mode" >"$REAL_MODE_FILE"
    READY_SLEEP_COUNT=0

    # When readiness checks the response.
    RECORD_READY_SLEEP=1 configure_jellyfin_network_ready "$(real_url)" "token" 1
    rc=$?

    # Then it fails after exactly one network request without entering retry sleep.
    assert_eq "1" "$rc" "Jellyfin network readiness rejects real $mode response"
    assert_eq "1" "$(<"$REAL_REQUEST_FILE")" "Jellyfin network readiness does not retry real $mode response"
    assert_eq "0" "$READY_SLEEP_COUNT" "Jellyfin network readiness does not sleep after real $mode response"
    stop_real_server
done

# Given a real API that rejects the supplied credential.
start_real_server
READY_SLEEP_COUNT=0

# When readiness checks it under the suite's outer watchdog.
RECORD_READY_SLEEP=1 configure_jellyfin_network_ready "$(real_url)" "wrong" 1
rc=$?

# Then it makes exactly one request and fails without entering retry sleep.
assert_eq "1" "$rc" "Jellyfin network readiness rejects real unauthorized response"
assert_eq "1" "$(<"$REAL_REQUEST_FILE")" "Jellyfin network readiness does not retry real unauthorized response"
assert_eq "0" "$READY_SLEEP_COUNT" "Jellyfin network readiness does not sleep after real unauthorized response"
stop_real_server

# Given a real API that remains unavailable.
start_real_server

# When readiness exhausts its one-second budget.
start_ms=$(real_elapsed_ms)
configure_jellyfin_network_ready "$(real_url)" "token" 1
rc=$?
elapsed_ms=$(($(real_elapsed_ms) - start_ms))

# Then it fails within the absolute deadline plus scheduling margin.
assert_eq "1" "$rc" "Jellyfin network readiness fails persistent HTTP 503"
if ((elapsed_ms < 1500)); then pass "Jellyfin network readiness bounds persistent HTTP 503"; else fail "Jellyfin network readiness bounds persistent HTTP 503" "elapsed=${elapsed_ms}ms"; fi
if (($(<"$REAL_REQUEST_FILE") >= 1)); then pass "Jellyfin network readiness requests persistent HTTP 503"; else fail "Jellyfin network readiness requests persistent HTTP 503"; fi
stop_real_server

# Given a slow whole-transfer response.
start_real_server
printf 'slow' >"$REAL_MODE_FILE"

# When readiness applies its per-request deadline.
start_ms=$(real_elapsed_ms)
configure_jellyfin_network_ready "$(real_url)" "token" 1
rc=$?
elapsed_ms=$(($(real_elapsed_ms) - start_ms))

# Then the slow transfer cannot extend the absolute deadline.
assert_eq "1" "$rc" "Jellyfin network readiness rejects slow whole transfer"
if ((elapsed_ms < 1500)); then pass "Jellyfin network readiness bounds slow whole transfer"; else fail "Jellyfin network readiness bounds slow whole transfer" "elapsed=${elapsed_ms}ms"; fi
stop_real_server

if [[ "${JELLYFIN_NETWORK_OPTIMIZED:-}" != "1" ]]; then
    # Given the same readiness unit and typed responses for optimized Python.

    # When the child validates those responses with optimization enabled.
    optimized_output=$(PYTHONOPTIMIZE=1 JELLYFIN_NETWORK_OPTIMIZED=1 bash "$0" 2>&1)
    optimized_rc=$?

    # Then the child succeeds and optimized Python still rejects wrong typed data.
    assert_eq "0" "$optimized_rc" "Jellyfin network readiness passes under optimized Python"
    assert_contains "$optimized_output" "Jellyfin network readiness rejects real wrong-type response" \
        "Jellyfin network readiness keeps schema validation under optimized Python"
fi

scenario_end "$CURRENT_SCENARIO"
summary

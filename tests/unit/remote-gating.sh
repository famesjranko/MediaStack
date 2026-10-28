#!/usr/bin/env bash
# Focused coverage for the Jellyfin network reader used by remote-gating tests.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="remote-gating"
scenario_begin "$CURRENT_SCENARIO"

unit_pass() { PASS_COUNT=$((PASS_COUNT + 1)); }
unit_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$1")
}
unit_assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$expected" == "$actual" ]]; then
        unit_pass
    else
        unit_fail "$name"
    fi
}

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup_fixture() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup_fixture EXIT
MODE_FILE="$TMP_DIR/mode"
PORT_FILE="$TMP_DIR/port"

# Given a localhost Jellyfin fixture that rejects the legacy API-key header.
python3 -c '
import http.server
import json
import pathlib
import sys

mode_file = pathlib.Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/System/Configuration/network":
            self.send_error(404)
            return
        mode = mode_file.read_text().strip()
        if self.headers.get("X-Emby-Token"):
            self.send_error(401)
            return
        if self.headers.get("Authorization") != "MediaBrowser Token=\"dummy-api-key\"":
            self.send_error(403)
            return
        if mode in ("401", "403"):
            self.send_error(int(mode))
            return
        if mode == "invalid-json":
            body = b"not json"
        elif mode == "wrong-types":
            body = b"{\"KnownProxies\":{},\"PublishedServerUriBySubnet\":[1]}"
        elif mode == "missing-fields":
            body = b"{}"
        elif mode == "missing-uri":
            body = b"{\"KnownProxies\":[],\"PublishedServerUriBySubnet\":[]}"
        else:
            body = json.dumps({
                "KnownProxies": [],
                "PublishedServerUriBySubnet": ["internal=http://127.0.0.1:8096"],
            }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
' "$MODE_FILE" >"$PORT_FILE" 2>"$TMP_DIR/server.err" &
SERVER_PID=$!

for _ in $(seq 1 50); do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.05
done
if [[ ! -s "$PORT_FILE" ]]; then
    unit_fail "remote gating fixture becomes ready"
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit 1
fi
PORT="$(<"$PORT_FILE")"
DIND_NAME="test-dind"
JELLYFIN_API_KEY="dummy-api-key"

# The remote-gating scenario's .env: the LAN checks read DOMAIN to name the
# external URL they forbid.
env_get() {
    case "$1" in
        JELLYFIN_API_KEY) printf '%s\n' "${JELLYFIN_API_KEY:-}" ;;
        DOMAIN) printf 'gate.test\n' ;;
    esac
}

# The adapter preserves docker exec's stdin boundary while executing the
# command locally, so the real reader talks to the localhost HTTP fixture.
docker() {
    [[ "$1" == "exec" ]] || return 1
    shift
    [[ "$1" == "-i" ]] && shift
    [[ "$1" == "-w" ]] && shift 2
    [[ "$1" == "test-dind" ]] || return 1
    shift
    if [[ "$1" == "sh" && "$2" == "-c" ]]; then
        sh -c "${3//localhost:8096/127.0.0.1:$PORT}"
        return
    fi
    "$@"
}

dind_exec() {
    local command="$1"
    local published_url_query="docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' jellyfin | sed -n 's/^JELLYFIN_PublishedServerUrl=//p'"

    if [[ "$command" == "$published_url_query" ]]; then
        printf '%s\n' 'http://127.0.0.1:8096'
        return
    fi

    printf 'remote gating unit: rejected unexpected dind_exec command\n' >&2
    return 1
}

DOCKER_TRAP_DIR="$TMP_DIR/docker-trap"
DOCKER_TRAP_LOG="$TMP_DIR/docker-trap.log"
mkdir -p "$DOCKER_TRAP_DIR"
: >"$DOCKER_TRAP_LOG"
printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"%s"\nexit 1\n' \
    'external docker invocation blocked:' "$DOCKER_TRAP_LOG" >"$DOCKER_TRAP_DIR/docker"
chmod 700 "$DOCKER_TRAP_DIR/docker"
PATH="$DOCKER_TRAP_DIR:$PATH"

# Given an expected container published-URL query and a docker PATH trap.
published_url_query="docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' jellyfin | sed -n 's/^JELLYFIN_PublishedServerUrl=//p'"

# When the unit adapter handles the query.
published_container="$(dind_exec "$published_url_query")"
docker_trap_calls="$(wc -l <"$DOCKER_TRAP_LOG")"

# Then it supplies the fixture value without invoking external docker.
unit_assert_eq "http://127.0.0.1:8096" "$published_container" \
    "remote gating unit adapter returns the container published URL"
unit_assert_eq "0" "${docker_trap_calls//[[:space:]]/}" \
    "remote gating unit adapter does not invoke external docker"

SLEEP_SWITCH_MODE=""
sleep() {
    if [[ -n "$SLEEP_SWITCH_MODE" ]]; then
        printf '%s\n' "$SLEEP_SWITCH_MODE" >"$MODE_FILE"
        SLEEP_SWITCH_MODE=""
        return
    fi
    command sleep "$@"
}

CALLER_EVENTS=()
pass() { CALLER_EVENTS+=("pass:$1"); }
fail() { CALLER_EVENTS+=("fail:$1"); }

assert_caller_events() {
    local expected="$1" name="$2" actual
    actual="$(printf '%s\n' "${CALLER_EVENTS[@]}")"
    unit_assert_eq "$expected" "$actual" "$name"
}

source "$REPO_ROOT/tests/assertions/remote-gating.sh"
source "$REPO_ROOT/tests/scenarios/stage2-skip.sh"

fetch_network() {
    local output
    output="$(remote_gating_fetch_jellyfin_network)"
    RC=$?
    OUT="$output"
}

# Given valid configuration with an intentionally empty KnownProxies list.
printf 'valid\n' >"$MODE_FILE"

# When the shared reader uses the supported Authorization header.
fetch_network

# Then it returns the configured internal URI.
unit_assert_eq "0" "$RC" "remote gating reader accepts supported Authorization response"
unit_assert_eq "internal=http://127.0.0.1:8096" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PublishedServerUriBySubnet"][0])')" \
    "remote gating reader preserves the configured internal URI"

for mode in 401 403 invalid-json missing-fields wrong-types; do
    # Given an invalid reader response class.
    printf '%s\n' "$mode" >"$MODE_FILE"

    # When the reader fetches it through the docker-exec adapter.
    fetch_network

    # Then it returns a nonzero status instead of an empty object.
    if [[ "$RC" -ne 0 ]]; then
        unit_pass
    else
        unit_fail "remote gating reader rejects $mode response"
    fi
done

# Given no API key is available from either supported source.
JELLYFIN_API_KEY=""

# When the reader is called.
fetch_network

# Then it returns a nonzero status.
if [[ "$RC" -ne 0 ]]; then
    unit_pass
else
    unit_fail "remote gating reader rejects a missing API key"
fi
JELLYFIN_API_KEY="dummy-api-key"

# Given the first reader call returns HTTP 401.
printf '401\n' >"$MODE_FILE"
CALLER_EVENTS=()

# When the LAN-only caller runs.
if remote_gating_assert_jellyfin_lan_only skipped; then
    unit_fail "remote gating LAN caller returns nonzero on its initial read error"
else
    unit_pass
fi

# Then it stops with only the readable-error assertion.
assert_caller_events "fail:remote gating: skipped Jellyfin network configuration is readable" \
    "remote gating LAN initial read error has no later policy assertions"

# Given the first reader response has no internal URI and its retry returns 401.
printf 'missing-uri\n' >"$MODE_FILE"
SLEEP_SWITCH_MODE="401"
CALLER_EVENTS=()

# When the LAN-only caller retries the read.
if remote_gating_assert_jellyfin_lan_only skipped; then
    unit_fail "remote gating LAN caller returns nonzero on its retry read error"
else
    unit_pass
fi

# Then the two pre-retry policy assertions precede only the retry readable error.
assert_caller_events $'pass:remote gating: skipped Jellyfin does not trust npm proxy\npass:remote gating: skipped Jellyfin omits external HTTPS URL\nfail:remote gating: skipped Jellyfin network configuration remains readable' \
    "remote gating LAN retry stops before later policy assertions"

# Given the shared reader returns HTTP 401 before stage-2 policy checks.
CALLER_EVENTS=()

# When the stage-2 skipped caller runs.
if stage2_skip_assert_test03_postconditions; then
    unit_fail "stage2 skip caller returns nonzero on its read error"
else
    unit_pass
fi

# Then it stops with only its readable-error assertion.
assert_caller_events "fail:TEST-03 skipped-state LAN-only: Jellyfin network configuration is readable" \
    "stage2 skip read error has no later policy assertions"

scenario_end "$CURRENT_SCENARIO"
summary

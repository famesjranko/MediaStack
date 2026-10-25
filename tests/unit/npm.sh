#!/usr/bin/env bash
# Focused unit coverage for NPM administrator setup and repeat-run authentication.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="npm"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
MODE_FILE="$TMP_DIR/mode"
READY_FILE="$TMP_DIR/ready"
REQUEST_LOG="$TMP_DIR/requests.log"
FIXTURE_PID=""

cleanup() {
    if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
        kill -TERM "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

python3 - "$READY_FILE" "$MODE_FILE" "$REQUEST_LOG" <<'PY' &
import http.server
import json
import pathlib
import sys

ready_file = pathlib.Path(sys.argv[1])
mode_file = pathlib.Path(sys.argv[2])
request_log = pathlib.Path(sys.argv[3])
EXPECTED_EMAIL = "fixture@example.test"
EXPECTED_SECRET = 'dummy"\\password'


class NpmFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def _mode(self):
        return mode_file.read_text().strip()

    def _reply(self, status, body=""):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def _body(self):
        return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

    def do_POST(self):
        mode = self._mode()
        body = self._body()
        status, reply = 404, ""
        if self.path == "/api/users":
            status = {
                "create-201": 201,
                "existing-403": 403,
                "bad-auth-403": 403,
                "existing-404": 404,
                "existing-409": 409,
                "existing-422": 422,
                "unexpected-500": 500,
                "rotation-failure": 409,
            }[mode]
            if mode == "create-201" and (
                body.get("email") != EXPECTED_EMAIL
                or body.get("auth", {}).get("secret") != EXPECTED_SECRET
            ):
                status = 400
        elif self.path == "/api/tokens":
            if (
                body.get("identity") == "admin@example.com"
                and body.get("secret") == "changeme"
            ):
                if mode == "rotation-failure":
                    status, reply = 201, '{"token":"default-token"}'
                else:
                    status = 401
            elif (
                body.get("identity") == EXPECTED_EMAIL
                and body.get("secret") == EXPECTED_SECRET
            ):
                status, reply = 201, '{"token":"saved-token"}'
            else:
                status = 401
        request_log.write_text(
            request_log.read_text() + f"POST {self.path} {status}\n"
        )
        self._reply(status, reply)

    def do_PUT(self):
        status = 500 if self._mode() == "rotation-failure" and self.path.endswith("/auth") else 200
        request_log.write_text(
            request_log.read_text() + f"PUT {self.path} {status}\n"
        )
        self._reply(status)

    def do_GET(self):
        status, reply = 404, ""
        if self.path == "/api/settings" and self.headers.get("Authorization") == "Bearer saved-token":
            status, reply = 200, "[]"
        request_log.write_text(
            request_log.read_text() + f"GET {self.path} {status}\n"
        )
        self._reply(status, reply)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NpmFixture)
ready_file.write_text(str(server.server_port))
server.serve_forever()
PY
FIXTURE_PID=$!

for _ in {1..50}; do
    [[ -s "$READY_FILE" ]] && break
    sleep 0.1
done
if [[ ! -s "$READY_FILE" ]] || ! kill -0 "$FIXTURE_PID" 2>/dev/null; then
    printf '%s\n' "NPM HTTP fixture did not become ready within 5 seconds" >&2
    exit 1
fi
FIXTURE_PORT="$(cat "$READY_FILE")"

source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/lib/http.sh"
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/services/npm/main.sh"

BOLD=""
NC=""
NPM_ADMIN_EMAIL="fixture@example.test"
VALID_PASSWORD='dummy"\password'
PUBLICATION_COUNT=0
FINISH_COUNT=0

service_local_url() { printf 'http://127.0.0.1:%s' "$FIXTURE_PORT"; }
_npm_ensure_healthy() { return 0; }
cfg_field() { printf 'false'; }
_npm_configure_publication() { PUBLICATION_COUNT=$((PUBLICATION_COUNT + 1)); }
_npm_finish_configuration() { FINISH_COUNT=$((FINISH_COUNT + 1)); }

given_case() {
    local mode="$1" password="${2:-$VALID_PASSWORD}"
    printf '%s' "$mode" >"$MODE_FILE"
    : >"$REQUEST_LOG"
    PUBLICATION_COUNT=0
    FINISH_COUNT=0
    JELLYFIN_ADMIN_PASSWORD="$password"
}

when_configuring_npm() {
    configure_npm >/dev/null 2>&1
    CASE_RC=$?
}

# Given NPM rejects repeat first-user creation but saved credentials are valid.
given_case existing-403

# When configure_npm handles the existing-user response.
when_configuring_npm

# Then it authenticates, hardens, publishes, and finishes.
assert_eq "0" "$CASE_RC" "403 existing user authenticates with saved credentials"
assert_eq "1" "$PUBLICATION_COUNT" "403 existing user reaches publication"
assert_eq "1" "$FINISH_COUNT" "403 existing user reaches finish"
assert_file_contains "$REQUEST_LOG" "GET /api/settings 200" "403 existing user reaches default-site hardening"

# Given the same 403 response but invalid saved credentials.
given_case bad-auth-403 'wrong-password'

# When configure_npm cannot authenticate them.
when_configuring_npm

# Then it fails before hardening or publication.
assert_eq "1" "$CASE_RC" "403 invalid saved credentials fails"
assert_eq "0" "$PUBLICATION_COUNT" "403 invalid saved credentials does not publish"
assert_eq "0" "$FINISH_COUNT" "403 invalid saved credentials does not finish"
assert_file_not_contains "$REQUEST_LOG" "GET /api/settings" "403 invalid saved credentials has no hardening request"

# Given each established successful create or existing-user outcome.
for mode in create-201 existing-404 existing-409 existing-422; do
    given_case "$mode"

    # When configure_npm uses the established path.
    when_configuring_npm

    # Then it still authenticates and publishes.
    assert_eq "0" "$CASE_RC" "$mode preserves successful setup"
    assert_eq "1" "$PUBLICATION_COUNT" "$mode reaches publication"
done

# Given an unexpected create-user failure.
given_case unexpected-500

# When configure_npm receives it.
when_configuring_npm

# Then it fails without downstream effects.
assert_eq "1" "$CASE_RC" "unexpected 500 fails"
assert_eq "0" "$PUBLICATION_COUNT" "unexpected 500 does not publish"

# Given default-credential rotation begins but the password update fails.
given_case rotation-failure

# When configure_npm cannot rotate the default credentials.
when_configuring_npm

# Then it fails without publishing.
assert_eq "1" "$CASE_RC" "default credential rotation failure fails"
assert_eq "0" "$PUBLICATION_COUNT" "default credential rotation failure does not publish"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# Strict JSON requests use real curl and a disposable local HTTP fixture.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/scripts/lib/http.sh"
CURRENT_SCENARIO=http-json
scenario_begin "$CURRENT_SCENARIO"
TMP_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || {
        kill "$SERVER_PID"
        wait "$SERVER_PID" 2>/dev/null
    }
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

python3 - "$TMP_DIR" <<'PY' >"$TMP_DIR/server.log" 2>&1 &
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with (root / "requests").open("a") as log:
            log.write(json.dumps({"method": self.command, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        code, response = (root / "reply").read_text().split("\n", 1)
        self.send_response(int(code))
        self.end_headers()
        self.wfile.write(response.encode())
    do_POST = do_GET
    do_PATCH = do_GET
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..50}; do
    [[ -s "$TMP_DIR/port" ]] && break
    sleep 0.02
done
if [[ ! -s "$TMP_DIR/port" ]]; then
    fail "local HTTP fixture starts"
    summary
    exit 1
fi
BASE="http://127.0.0.1:$(cat "$TMP_DIR/port")"
curl() {
    printf '%s\n' "$@" >"$TMP_DIR/argv"
    command curl "$@"
}
request() {
    OUTPUT=$(http_json_request fixture "$METHOD" "$BASE/test" "$BODY" Authorization "$TOKEN" "$@" 2>"$TMP_DIR/error")
    RC=$?
}
TOKEN=fixture-bearer
BODY='{"password":"fixture-password"}'
METHOD=POST

# Given a response with false and zero values and a secret header and payload
printf '200\n%s' '{"ok":false,"count":0,"record":{"id":"one"}}' >"$TMP_DIR/reply"

# When a strict request requires those fields
request ok count record.id:string

# Then the values survive and the secrets arrive at the server through stdin
assert_eq 0 "$RC" "valid false and zero fields are accepted"
assert_eq '{"ok":false,"count":0,"record":{"id":"one"}}' "$OUTPUT" "valid response is preserved"
assert_contains "$(cat "$TMP_DIR/requests")" "$TOKEN" "server receives the secret header"
assert_contains "$(cat "$TMP_DIR/requests")" 'fixture-password' "server receives the secret payload"
assert_not_contains "$(cat "$TMP_DIR/argv")" "$TOKEN" "header stays off curl argv"
assert_not_contains "$(cat "$TMP_DIR/argv")" 'fixture-password' "payload stays off curl argv"
assert_contains "$(cat "$TMP_DIR/argv")" "$(printf '%s\n' --connect-timeout 10 --max-time 45 --retry 0)" "request uses bounded timeouts and no automatic retries"

for CASE in missing null malformed wrong-parent wrong-type; do
    # Given an invalid or incomplete successful response
    case "$CASE" in
        missing) RESPONSE='{"record":{}}' ;;
        null) RESPONSE='{"record":{"id":null}}' ;;
        malformed) RESPONSE='<html>fixture</html>' ;;
        wrong-parent) RESPONSE='{"record":[]}' ;;
        wrong-type) RESPONSE='{"record":{"id":7}}' ;;
    esac
    printf '200\n%s' "$RESPONSE" >"$TMP_DIR/reply"

    # When the request requires a string record id
    request record.id:string

    # Then the helper fails with a diagnostic and returns no usable body
    assert_eq 2 "$RC" "$CASE response fails validation"
    assert_eq "" "$OUTPUT" "$CASE response produces no body"
    assert_contains "$(cat "$TMP_DIR/error")" 'fixture:' "$CASE response reports its request label"
done

# Given a successful response with an explicitly empty systems array
printf '200\n%s' '{"items":[]}' >"$TMP_DIR/reply"

# When a request requires each record id
request 'items[].id:string'

# Then the empty array is accepted
assert_eq 0 "$RC" "an explicitly empty array is accepted"

# Given a systems array with an incomplete record
printf '200\n%s' '{"items":[{"id":"first"},{}]}' >"$TMP_DIR/reply"

# When a request requires every record id
request 'items[].id:string'

# Then a later incomplete record is rejected
assert_eq 2 "$RC" "every array member is validated"
assert_eq "" "$OUTPUT" "invalid array emits no partial body"

# Given an error response carrying an otherwise valid JSON body
printf '503\n%s' '{"record":{"id":"one"}}' >"$TMP_DIR/reply"
: >"$TMP_DIR/requests"

# When a POST request is made
request record.id:string

# Then the failure is reported and the write is attempted only once
assert_eq 1 "$RC" "HTTP rejection fails the request"
assert_contains "$(cat "$TMP_DIR/error")" 'HTTP 503' "HTTP rejection reports the status"
assert_eq "" "$OUTPUT" "HTTP rejection returns no body"
assert_eq 1 "$(wc -l <"$TMP_DIR/requests" | tr -d ' ')" "failed writes are not retried"

# Given a transport timeout
curl() { return 28; }

# When a request is attempted
request record.id:string

# Then no response is accepted and the transport failure is reported
assert_eq 1 "$RC" "transport timeout fails the request"
assert_eq "" "$OUTPUT" "transport timeout returns no body"
assert_contains "$(cat "$TMP_DIR/error")" 'connection failed' "transport timeout is reported"
scenario_end "$CURRENT_SCENARIO"
summary

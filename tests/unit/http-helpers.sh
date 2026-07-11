#!/usr/bin/env bash
# tests/unit/http-helpers.sh
#
# Unit tests for scripts/lib/http.sh helpers. No DinD, no Docker, no network.
# Mocks curl as a bash function to control HTTP responses. The mock handles
# two calling conventions: _http_request (code appended to stdout) and
# js_post (body to -o file, code to stdout).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="http-helpers"
echo -e "${CYAN}${BOLD}▶ scenario: http-helpers${NC}"

# http.sh must source its own common.sh dependency. The dummy CONFIG_FILE is
# present only for common.sh's cfg_* helpers, which are not called here.
CONFIG_FILE=/dev/null
source "$REPO_ROOT/scripts/lib/http.sh"

set +e
set +u

# ---------------------------------------------------------------------------
# Curl mock — controlled via MOCK_CURL_* globals
# ---------------------------------------------------------------------------
MOCK_CURL_CODE=200
MOCK_CURL_BODY=""
MOCK_CURL_FAIL=0

curl() {
    if [[ "$MOCK_CURL_FAIL" == "1" ]]; then
        return 1
    fi

    local outfile="" has_write_out=0 prev=""
    for arg in "$@"; do
        [[ "$prev" == "-o" ]] && outfile="$arg"
        [[ "$arg" == "-w" ]] && has_write_out=1
        prev="$arg"
    done

    if [[ -n "$outfile" ]]; then
        printf '%s' "$MOCK_CURL_BODY" > "$outfile"
        printf '%s' "$MOCK_CURL_CODE"
    elif [[ "$has_write_out" == "1" ]]; then
        printf '%s\n%s' "$MOCK_CURL_BODY" "$MOCK_CURL_CODE"
    else
        [[ "$MOCK_CURL_CODE" =~ ^[23] ]] && return 0 || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Log capture — record which log function was called and with what message
# ---------------------------------------------------------------------------
LAST_LOG_FN=""
LAST_LOG_MSG=""
log_ok()    { LAST_LOG_FN="log_ok";    LAST_LOG_MSG="$1"; }
log_info()  { LAST_LOG_FN="log_info";  LAST_LOG_MSG="$1"; }
log_warn()  { LAST_LOG_FN="log_warn";  LAST_LOG_MSG="$1"; }
log_error() { LAST_LOG_FN="log_error"; LAST_LOG_MSG="$1"; }

reset_mock() {
    MOCK_CURL_CODE=200
    MOCK_CURL_BODY=""
    MOCK_CURL_FAIL=0
    LAST_LOG_FN=""
    LAST_LOG_MSG=""
}

# ---------------------------------------------------------------------------
# Source guards / dependency sourcing
# ---------------------------------------------------------------------------

if bash -euo pipefail -c "CONFIG_FILE=/dev/null; source '$REPO_ROOT/scripts/lib/http.sh'; declare -F log_warn >/dev/null && declare -F http_check >/dev/null && [[ \${GREEN+x} && \${RED+x} && \${NC+x} ]]"; then
    pass "http.sh: sources common.sh in isolation"
else
    fail "http.sh: sources common.sh in isolation"
fi

_LOG_COUNTS_WARN=7
source "$REPO_ROOT/scripts/lib/common.sh"
assert_eq "7" "$_LOG_COUNTS_WARN" "common.sh: include guard preserves existing state on repeat source"

source "$REPO_ROOT/scripts/lib/http.sh"
assert_eq "function" "$(type -t http_check)" "http.sh: include guard keeps functions available on repeat source"

# ---------------------------------------------------------------------------
# json_body
# ---------------------------------------------------------------------------

result=$(json_body user admin pass secret)
assert_eq '{"user": "admin", "pass": "secret"}' "$result" \
    "json_body: basic key-value"

result=$(json_body msg 'He said "hello" & back\\slash')
expected=$(python3 -c 'import json; print(json.dumps({"msg": "He said \"hello\" & back\\\\slash"}))')
assert_eq "$expected" "$result" \
    "json_body: JSON-special characters escaped"

if json_body one 2>/dev/null; then
    fail "json_body: odd arg count exits non-zero"
else
    pass "json_body: odd arg count exits non-zero"
fi

# ---------------------------------------------------------------------------
# json_obj — typed key/type/value triples
# ---------------------------------------------------------------------------

assert_eq '{"Role": 1}' "$(json_obj Role int 1)" "json_obj: int type"
assert_eq '{"trustProxy": true}' "$(json_obj trustProxy bool true)" "json_obj: bool true"
# The trap: bool('false') is truthy in Python; must map "false" -> JSON false.
assert_eq '{"trustProxy": false}' "$(json_obj trustProxy bool false)" "json_obj: bool false is not truthy"
assert_eq '{"value": "404", "meta": {}}' "$(json_obj value str 404 meta json '{}')" "json_obj: str + nested json literal"
assert_eq '{"user": "admin", "role": 1}' "$(json_obj user str admin role int 1)" "json_obj: multiple triples preserve order"

result=$(json_obj pw str 'He said "hi" \ end')
expected=$(python3 -c 'import json; print(json.dumps({"pw": "He said \"hi\" \\ end"}))')
assert_eq "$expected" "$result" "json_obj: str value JSON-escaped"

if json_obj a b 2>/dev/null; then
    fail "json_obj: non-triple arg count exits non-zero"
else
    pass "json_obj: non-triple arg count exits non-zero"
fi

if json_obj k bogus v 2>/dev/null; then
    fail "json_obj: unknown type exits non-zero"
else
    pass "json_obj: unknown type exits non-zero"
fi

# ---------------------------------------------------------------------------
# _http_request — 2xx returns body and rc=0
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=200; MOCK_CURL_BODY='{"ok":true}'
result=$(_http_request log_error "test-label" http://fake)
rc=$?
assert_eq '{"ok":true}' "$result" "_http_request: 2xx returns body"
assert_eq "0" "$rc" "_http_request: 2xx rc=0"

# ---------------------------------------------------------------------------
# _http_request — 4xx returns 1 and logs HTTP code
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=404; MOCK_CURL_BODY='not found'
_http_request log_error "test-label" http://fake >/dev/null
rc=$?
assert_eq "1" "$rc" "_http_request: 4xx returns 1"
assert_contains "$LAST_LOG_MSG" "HTTP 404" "_http_request: 4xx logs HTTP code"

# ---------------------------------------------------------------------------
# _http_request — 5xx returns 1
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=500; MOCK_CURL_BODY='server error'
_http_request log_error "test-label" http://fake >/dev/null
rc=$?
assert_eq "1" "$rc" "_http_request: 5xx returns 1"

# ---------------------------------------------------------------------------
# _http_request — connection failure returns 1
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_FAIL=1
_http_request log_error "test-label" http://fake >/dev/null
rc=$?
assert_eq "1" "$rc" "_http_request: connection failure returns 1"
assert_contains "$LAST_LOG_MSG" "connection failed" "_http_request: connection failure logged"

# ---------------------------------------------------------------------------
# _http_request — truncates body to 300 chars on error
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=400
MOCK_CURL_BODY=$(python3 -c "print('x' * 500)")
_http_request log_error "trunc" http://fake >/dev/null
body_in_msg="${LAST_LOG_MSG#*HTTP 400 }"
assert_eq "300" "${#body_in_msg}" "_http_request: error body truncated to 300 chars"

# ---------------------------------------------------------------------------
# http_check uses log_error, api_fetch uses log_warn
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=500; MOCK_CURL_BODY='err'
http_check "check-label" http://fake >/dev/null
assert_eq "log_error" "$LAST_LOG_FN" "http_check: uses log_error on failure"

reset_mock; MOCK_CURL_CODE=500; MOCK_CURL_BODY='err'
api_fetch "fetch-label" http://fake >/dev/null
assert_eq "log_warn" "$LAST_LOG_FN" "api_fetch: uses log_warn on failure"

# ---------------------------------------------------------------------------
# wait_for_service — immediate success
# ---------------------------------------------------------------------------

sleep() { :; }
reset_mock; MOCK_CURL_CODE=200
wait_for_service "test-svc" "http://fake" >/dev/null
rc=$?
assert_eq "0" "$rc" "wait_for_service: immediate success returns 0"
unset -f sleep

# ---------------------------------------------------------------------------
# wait_for_service — timeout
# ---------------------------------------------------------------------------

sleep() { :; }
reset_mock; MOCK_CURL_CODE=500
wait_for_service "test-svc" "http://fake" >/dev/null
rc=$?
assert_eq "1" "$rc" "wait_for_service: timeout returns 1"
unset -f sleep

# ---------------------------------------------------------------------------
# post_restart_wait — immediate success and timeout, no logging side effects
# ---------------------------------------------------------------------------

sleep() { :; }
reset_mock; MOCK_CURL_CODE=200
post_restart_wait "http://fake/health" 4 2 >/dev/null
rc=$?
assert_eq "0" "$rc" "post_restart_wait: immediate success returns 0"
assert_eq "" "$LAST_LOG_FN" "post_restart_wait: success does not log"
unset -f sleep

sleep() { :; }
reset_mock; MOCK_CURL_CODE=500
post_restart_wait "http://fake/health" 4 2 >/dev/null
rc=$?
assert_eq "1" "$rc" "post_restart_wait: timeout returns 1"
assert_eq "" "$LAST_LOG_FN" "post_restart_wait: timeout does not log"
unset -f sleep

# ---------------------------------------------------------------------------
# js_post — 200 and 201 return 0
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=200; MOCK_CURL_BODY='{"id":1}'
js_post "test-svc" "http://fake/ep" '{"k":"v"}' "/tmp/test-cookie" >/dev/null
rc=$?
assert_eq "0" "$rc" "js_post: 200 returns 0"
assert_eq "log_ok" "$LAST_LOG_FN" "js_post: 200 calls log_ok"

reset_mock; MOCK_CURL_CODE=201; MOCK_CURL_BODY='{"id":2}'
js_post "test-svc" "http://fake/ep" '{"k":"v"}' "/tmp/test-cookie" >/dev/null
rc=$?
assert_eq "0" "$rc" "js_post: 201 returns 0"

# ---------------------------------------------------------------------------
# js_post — 4xx returns 1 with body in warning
# ---------------------------------------------------------------------------

reset_mock; MOCK_CURL_CODE=422; MOCK_CURL_BODY='validation failed'
js_post "test-svc" "http://fake/ep" '{"k":"v"}' "/tmp/test-cookie" >/dev/null
rc=$?
assert_eq "1" "$rc" "js_post: 4xx returns 1"
assert_eq "log_warn" "$LAST_LOG_FN" "js_post: 4xx calls log_warn"
assert_contains "$LAST_LOG_MSG" "validation failed" "js_post: 4xx includes response body"

echo -e "${CYAN}◀ http-helpers done${NC}"
summary

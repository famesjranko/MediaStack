#!/usr/bin/env bash
# tests/unit/stage2-dynu.sh
#
# Contract tests for Dynu IP Update Protocol response mapping. Inputs are raw
# fixture response tokens, not live Dynu credentials.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-dynu"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/setup/stages/stage2.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage2.sh"
[[ -f "$REPO_ROOT/scripts/lib/network.sh" ]] && source "$REPO_ROOT/scripts/lib/network.sh"

set +e
set +u

if ! type stage2_dynu_validate_response >/dev/null 2>&1; then
    stage2_dynu_validate_response() { printf '__not_implemented__'; }
fi
if ! type stage2_dynu_preflight >/dev/null 2>&1; then
    stage2_dynu_preflight() { printf '__not_implemented__'; }
fi

assert_eq "ok" "$(stage2_dynu_validate_response "good 203.0.113.10")" "S2-07: Dynu good maps to ok"
assert_eq "ok" "$(stage2_dynu_validate_response "nochg 203.0.113.10")" "S2-07: Dynu nochg maps to ok"

for token in badauth nohost abuse notfqdn numhost dnserr 911; do
    assert_eq "$token" "$(stage2_dynu_validate_response "$token")" "S2-07: Dynu $token maps to $token"
done

badauth_copy="$(stage2_dynu_validate_response "badauth" "message" 2>/dev/null)"
# #94: the badauth message must name BOTH valid options (account password and the
# Dynu 'IP Update Password') and must NOT contradict the credential prompt by
# asserting the account password is wrong (the old 'not your account password').
assert_contains "$badauth_copy" "account password" "S2-07: Dynu badauth copy accepts the account password as valid"
assert_contains "$badauth_copy" "IP Update Password" "S2-07: Dynu badauth copy names the IP Update Password alternative"
if [[ "$badauth_copy" == *"not your account password"* ]]; then
    fail "S2-07: Dynu badauth copy must not contradict the prompt (no 'not your account password')"
else
    pass "S2-07: Dynu badauth copy does not contradict the credential prompt"
fi

curl() {
    printf '%s\n' "$*" >"$TMP_CURL_ARGS"
    printf 'good 203.0.113.10\n'
}
TMP_CURL_ARGS="$(mktemp)"
trap 'rm -f "$TMP_CURL_ARGS"' EXIT
assert_eq "ok" "$(stage2_dynu_preflight "media.example.com" "dynu-user" 'secret with spaces')" "S2-07: Dynu preflight parses live protocol response"
dynu_curl_args="$(cat "$TMP_CURL_ARGS")"
assert_contains "$dynu_curl_args" "-fsS --max-time 15 --get https://api.dynu.com/nic/update" "S2-07: Dynu preflight uses IP Update endpoint"
assert_contains "$dynu_curl_args" "--data-urlencode hostname=media.example.com" "S2-07: Dynu preflight URL-encodes hostname"
assert_contains "$dynu_curl_args" "--data-urlencode username=dynu-user" "S2-07: Dynu preflight URL-encodes username"
assert_contains "$dynu_curl_args" "--data-urlencode password=secret with spaces" "S2-07: Dynu preflight URL-encodes password"

scenario_end "$CURRENT_SCENARIO"
summary

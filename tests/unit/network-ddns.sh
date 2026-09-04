#!/usr/bin/env bash
# tests/unit/network-ddns.sh
#
# Unit coverage for scripts/lib/network/ddns.sh — the disposable credential
# verification container. The reject/degrade split is the whole point of the
# helper: reject re-prompts, degrade KEEPS the credential. Getting that wrong in
# the degrade direction persists a credential the updater already refused, and
# the real ddns-updater then dies at install.
#
# Docker and curl are stubbed so each decision is exercised deterministically —
# the live behaviour this covers reproduced on roughly one run in ten.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="network-ddns"
scenario_begin "$CURRENT_SCENARIO"

set +e
set +u

# Shrink the bounded loops before the module pins them readonly, so a degrade
# path costs a few polls rather than half a minute.
export DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS=3
export DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS=0
export DDNS_VERIFY_UPDATE_POLL_ATTEMPTS=2
export DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS=0
export DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS=1
export DDNS_VERIFY_PULL_TIMEOUT_SECONDS=1

source "$REPO_ROOT/scripts/lib/network.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
CONFIG="$TMP_ROOT/config.json"
printf '{"settings":[]}\n' >"$CONFIG"

VALIDATION_LOG='2026-09-05 ERROR settings: validating provider specific settings: token is not valid: bad shape'

# Stub state, reset per case:
#   STUB_PORT           what `docker port` answers (empty = not published yet)
#   STUB_RUNNING        what `.State.Running` answers
#   STUB_LOGS           what `docker logs` answers
#   STUB_HTTP_CODE      what curl reports
#   STUB_HTTP_BODY      what curl writes to -o
#   STUB_RUNNING_AFTER_PORT  "no" = the container is gone once a port was handed
#                            out (the flip is recorded in a file: the helper reads
#                            `docker port` through a command substitution, whose
#                            subshell would discard a variable assignment)
docker() {
    case "$1 ${2:-}" in
        "image inspect") return 0 ;;
        "run -d")
            printf 'stub-cid\n'
            return 0
            ;;
        "port stub-cid")
            if [[ -n "$STUB_PORT" ]]; then
                printf '127.0.0.1:%s\n' "$STUB_PORT"
                [[ "$STUB_RUNNING_AFTER_PORT" == "no" ]] && : >"$PORT_HANDED"
            fi
            return 0
            ;;
        "inspect -f")
            case "$*" in
                *State.Running*)
                    if [[ -f "$PORT_HANDED" ]]; then
                        printf 'false\n'
                    else
                        printf '%s\n' "$STUB_RUNNING"
                    fi
                    ;;
            esac
            return 0
            ;;
        "logs stub-cid")
            printf '%s\n' "$STUB_LOGS"
            return 0
            ;;
        "rm -f") return 0 ;;
    esac
    return 0
}

curl() {
    local out=""
    while (($#)); do
        [[ "$1" == "-o" ]] && out="$2"
        shift
    done
    [[ -n "$out" ]] && printf '%s' "$STUB_HTTP_BODY" >"$out"
    printf '%s' "$STUB_HTTP_CODE"
}

reset_stubs() {
    STUB_PORT=""
    STUB_RUNNING=true
    STUB_LOGS=""
    STUB_HTTP_CODE="000"
    STUB_HTTP_BODY=""
    STUB_RUNNING_AFTER_PORT=yes
    PORT_HANDED="$TMP_ROOT/port-handed"
    rm -f "$PORT_HANDED"
    BODY="$TMP_ROOT/body"
    : >"$BODY"
}

verify_rc() {
    ddns_verify_via_container "$CONFIG" "$BODY" >/dev/null 2>&1
    printf '%s' "$?"
}

# --- The regression: a published port is not proof the server is up ----------
# Docker assigns the port mapping when the container is CREATED, so `docker port`
# keeps answering for a container that has already fail-fasted on the config.
# Honouring the port here skips the validation exit entirely, and the dead
# container then answers nothing — landing on degrade, which keeps the very
# credential the updater refused.
reset_stubs
STUB_PORT=32768
STUB_RUNNING=false
STUB_LOGS="$VALIDATION_LOG"
assert_eq "1" "$(verify_rc)" "published port with an exited container is still a reject"
assert_contains "$(cat "$BODY")" "is not valid" "reject through a published port reports the validation error"

# The same race one step later: the port is live and the container is up when the
# loop breaks, then it dies during the HTTP poll. No answer must not become a
# degrade when the exit says the credential was refused.
reset_stubs
STUB_PORT=32768
STUB_RUNNING=true
STUB_RUNNING_AFTER_PORT=no
STUB_LOGS="$VALIDATION_LOG"
assert_eq "1" "$(verify_rc)" "container that dies during the poll is a reject, not a degrade"
assert_contains "$(cat "$BODY")" "is not valid" "late reject reports the validation error"

# --- Existing decisions must not move ----------------------------------------
reset_stubs
STUB_RUNNING=false
STUB_LOGS="$VALIDATION_LOG"
assert_eq "1" "$(verify_rc)" "fail-fast before the port is published is a reject"

reset_stubs
STUB_RUNNING=false
STUB_LOGS='panic: some unrelated startup crash'
assert_eq "2" "$(verify_rc)" "exit without validation wording degrades"
assert_eq "" "$(cat "$BODY")" "unrelated exit writes no rejection body"

reset_stubs
STUB_RUNNING=true
assert_eq "2" "$(verify_rc)" "a container that never publishes its port degrades"

reset_stubs
STUB_PORT=32768
STUB_HTTP_CODE=202
assert_eq "0" "$(verify_rc)" "202 accepts the credential"

reset_stubs
STUB_PORT=32768
STUB_HTTP_CODE=500
STUB_HTTP_BODY='{"errors":["obtaining ipv4 address: connection refused"]}'
assert_eq "2" "$(verify_rc)" "500 in ddns-updater's own infrastructure vocabulary degrades"

reset_stubs
STUB_PORT=32768
STUB_HTTP_CODE=500
STUB_HTTP_BODY='{"errors":["badauth"]}'
assert_eq "1" "$(verify_rc)" "500 from a provider auth error rejects"

reset_stubs
STUB_PORT=32768
STUB_HTTP_CODE=000
assert_eq "2" "$(verify_rc)" "a live container that never answers degrades"

scenario_end "$CURRENT_SCENARIO"
summary

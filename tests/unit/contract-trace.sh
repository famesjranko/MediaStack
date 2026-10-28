#!/usr/bin/env bash
# Unit test - tests/lib/contract-trace.sh, the DinD side of contract capture.
#
# A stub docker records every call and plays the DinD: it accepts the shim,
# answers the reducer and returns its contracts.json. The hooks are the real
# ones, sourced as tests/run.sh sources them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contract-trace"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
DOCKER_LOG="$TMP_DIR/docker.log"
OUT="$TMP_DIR/contracts.json"
CANDIDATES="sonarr=lscr.io/linuxserver/sonarr@sha256:$(printf '1%.0s' {1..64})"
OVERRIDES="$CANDIDATES,radarr=lscr.io/linuxserver/radarr@sha256:$(printf '2%.0s' {1..64})"
REDUCED='{"schema": 1, "entries": {}}'
DIND_NAME=ms-unit-dind
RECEIPTS_EVENTS=/tmp/ms-receipt-events.jsonl

# One line per call, each argument shell-quoted, so the tests read exact argv.
docker() {
    printf '%q ' "$@" >>"$DOCKER_LOG"
    printf '\n' >>"$DOCKER_LOG"
    case "$*" in
        *observe.py*) return "$REDUCER_RC" ;;
        "exec $DIND_NAME cat /tmp/ms-contracts.json") printf '%s' "$REDUCED" ;;
        *"cat >'/usr/local/bin/docker'"*)
            cat >/dev/null
            return "$FAIL_DOCKER_SHIM"
            ;;
        *"cat >"*) cat >/dev/null ;;
    esac
}
_rcpt_sync() { return "$SYNC_RC"; }

source "$REPO_ROOT/tests/lib/contract-trace.sh"

reset_case() {
    : >"$DOCKER_LOG"
    rm -f "$OUT"
    MS_CONTRACTS_FILE=$OUT
    MS_CONTRACT_CANDIDATES=$CANDIDATES
    MS_TEST_IMAGE_OVERRIDES=$OVERRIDES
    RECEIPTS_ACTIVE=1
    SYNC_RC=0
    REDUCER_RC=0
    FAIL_DOCKER_SHIM=0
}

# Given no MS_CONTRACTS_FILE and an active event recorder.
reset_case
MS_CONTRACTS_FILE=

# When a scenario begins and ends.
contract_trace_begin
contract_trace_end fresh-install

# Then the hooks make no docker call, so no shim enters DinD.
assert_eq "" "$(cat "$DOCKER_LOG")" "contract trace: no shim and no reducer without MS_CONTRACTS_FILE"

# Given MS_CONTRACTS_FILE and an active event recorder.
reset_case

# When a scenario begins.
contract_trace_begin

# Then the curl and docker shims are installed in DinD and tracing is active.
assert_contains "$(cat "$DOCKER_LOG")" "chmod\ 755\ \'/usr/local/bin/curl\'" "contract trace: begin installs the curl shim"
assert_contains "$(cat "$DOCKER_LOG")" "chmod\ 755\ \'/usr/local/bin/docker\'" "contract trace: begin installs the docker shim"
assert_eq "1" "$CONTRACT_TRACE_ACTIVE" "contract trace: begin activates tracing"

# Given a stale contracts.json from an earlier run, and no event recorder.
reset_case
printf '{"stale": true}' >"$OUT"
RECEIPTS_ACTIVE=0

# When a scenario begins.
contract_trace_begin

# Then the stale file is gone, so the job cannot upload old evidence.
assert_eq "absent" "$([[ -e "$OUT" ]] && echo present || echo absent)" "contract trace: begin removes a stale contracts.json"

# Given a traced scenario whose candidates are a subset of the image overrides.
reset_case
contract_trace_begin
: >"$DOCKER_LOG"

# When the scenario ends.
contract_trace_end fresh-install
reducer=$(grep 'observe.py' "$DOCKER_LOG")

# Then the reducer receives MS_CONTRACT_CANDIDATES, not every override.
assert_contains "$reducer" " $CANDIDATES " "contract trace: the reducer gets MS_CONTRACT_CANDIDATES"
assert_not_contains "$reducer" "$OVERRIDES" "contract trace: the reducer does not get the accepted companions"
# And contracts.json holds exactly the reducer's output.
assert_eq "$REDUCED" "$(cat "$OUT")" "contract trace: contracts.json is the reducer's output"
# And no call besides the reducer and the removal names the raw traces.
leaks=$(grep -F 'ms-contract-traces' "$DOCKER_LOG" | grep -v -e 'observe.py' -e "^exec $DIND_NAME rm -rf ")
assert_eq "" "$leaks" "contract trace: only contracts.json leaves DinD, never the raw traces"
assert_eq "0" "$(grep -c '^cp ' "$DOCKER_LOG")" "contract trace: nothing is copied out of DinD with docker cp"
# And the last call removes both shims, the raw traces and exec records, and the DinD output.
assert_eq "exec $DIND_NAME rm -rf /usr/local/bin/curl /usr/local/bin/docker /tmp/ms-contract-traces /tmp/ms-contracts.json " \
    "$(tail -1 "$DOCKER_LOG")" "contract trace: end removes both shims and the raw records"

# Given a traced scenario whose event log does not catch up.
reset_case
contract_trace_begin
: >"$DOCKER_LOG"
SYNC_RC=1

# When the scenario ends.
contract_trace_end fresh-install

# Then no contracts.json is written and the reducer never runs.
assert_eq "absent" "$([[ -e "$OUT" ]] && echo present || echo absent)" "contract trace: a failed event-log sync writes no contracts.json"
assert_not_contains "$(cat "$DOCKER_LOG")" "observe.py" "contract trace: a failed event-log sync runs no reducer"
# And the shim and raw traces are still removed.
assert_contains "$(tail -1 "$DOCKER_LOG")" "rm -rf /usr/local/bin/curl /usr/local/bin/docker /tmp/ms-contract-traces" \
    "contract trace: a failed event-log sync still removes both shims and the raw records"

# Given MS_CONTRACTS_FILE, an active event recorder, and a DinD that refuses the docker shim.
reset_case
FAIL_DOCKER_SHIM=1

# When a scenario begins.
contract_trace_begin

# Then tracing stays off and the curl shim already copied in is removed again.
assert_eq "0" "$CONTRACT_TRACE_ACTIVE" "contract trace: a failed docker shim install leaves tracing off"
assert_contains "$(tail -1 "$DOCKER_LOG")" "rm -rf /usr/local/bin/curl /usr/local/bin/docker" \
    "contract trace: a failed docker shim install removes the shims"

scenario_end "$CURRENT_SCENARIO"
summary

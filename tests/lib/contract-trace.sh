# tests/lib/contract-trace.sh — contract-coverage capture inside DinD.
# Sourced by tests/run.sh after receipts.sh. No side effects at source time.
#
# With MS_CONTRACTS_FILE set to a host path, each scenario installs
# tests/lib/contract-trace-curl.sh as /usr/local/bin/curl and
# tests/lib/contract-trace-docker.sh as /usr/local/bin/docker in DinD. Scenarios
# set MS_CONTRACT_TRACE=$CONTRACT_TRACE_DIR only on the commands that start
# product code, so assertion curls and docker execs are never traced. At
# scenario end, tests/contracts/observe.py reduces the traces and exec records
# inside DinD and only its contracts.json leaves; the raw traces hold keys and
# response bodies and the exec records hold argv, so they are deleted there. With several scenarios in one run, each one replaces the
# file: hosted preflight runs one scenario per job.
#
# The evidence binds requests to the candidate images through the receipts'
# event log, so capture needs an active recorder (a digest override). A capture
# problem never changes the run's exit status; it withholds contracts.json, and
# the hosted verifier refuses a job without one.
#
# MS_CONTRACT_CANDIDATES (svc=ref pairs) names the candidates when they are a
# subset of MS_TEST_IMAGE_OVERRIDES; the hosted runner passes the job's
# combination. MS_TEST_RUN_ID, or the receipts' run id, is the evidence's run id.

: "${MS_CONTRACTS_FILE:=}"
CONTRACT_TRACE_DIR=/tmp/ms-contract-traces  # inside DinD; scenarios pass it to product code
_CONTRACT_SHIM=/usr/local/bin/curl          # inside DinD, ahead of /usr/bin in PATH and secure_path
_CONTRACT_DOCKER_SHIM=/usr/local/bin/docker # inside DinD, likewise ahead of /usr/bin/docker
_CONTRACT_OUTPUT=/tmp/ms-contracts.json     # inside DinD
CONTRACT_TRACE_ACTIVE=0

_contract_say() { echo -e "${BLUE:-}[contracts]${NC:-} $*" >&2; }

# Remove the shims and every raw trace, so later scenarios and the hosted
# artifact see neither.
_contract_clear() {
    docker exec "$DIND_NAME" rm -rf "$_CONTRACT_SHIM" "$_CONTRACT_DOCKER_SHIM" \
        "$CONTRACT_TRACE_DIR" "$_CONTRACT_OUTPUT" >/dev/null 2>&1
}

# Copy one shim from stdin to its path in DinD.
_contract_install() {
    docker exec -i "$DIND_NAME" sh -c "cat >'$1' && chmod 755 '$1'" <"$2"
}

# Install the shims and an empty, world-writable trace directory: install-e2e
# runs product code as an unprivileged user.
contract_trace_begin() {
    CONTRACT_TRACE_ACTIVE=0
    [[ -n "$MS_CONTRACTS_FILE" ]] || return 0
    rm -f "$MS_CONTRACTS_FILE"
    if ((!${RECEIPTS_ACTIVE:-0})); then
        _contract_say "no event recorder (it needs a digest override); no contracts.json"
        return 0
    fi
    if _contract_clear \
        && _contract_install "$_CONTRACT_SHIM" "$REPO_ROOT/tests/lib/contract-trace-curl.sh" \
        && _contract_install "$_CONTRACT_DOCKER_SHIM" "$REPO_ROOT/tests/lib/contract-trace-docker.sh" \
        && docker exec "$DIND_NAME" mkdir -m 1777 "$CONTRACT_TRACE_DIR"; then
        CONTRACT_TRACE_ACTIVE=1
    else
        _contract_clear
        _contract_say "cannot install the curl and docker trace shims; no contracts.json"
    fi
    return 0
}

# Reduce this scenario's traces to contracts.json and copy only that file out.
contract_trace_end() {
    local scn="$1" candidates="${MS_CONTRACT_CANDIDATES-${MS_TEST_IMAGE_OVERRIDES:-}}"
    local run_id="${MS_TEST_RUN_ID:-${RECEIPTS_RUN_ID:-}}"
    ((CONTRACT_TRACE_ACTIVE)) || return 0
    CONTRACT_TRACE_ACTIVE=0
    # Every start event before the last traced request must be in the log.
    if ! _rcpt_sync; then
        _contract_say "$scn: event log did not catch up; no contracts.json"
    elif ! docker exec -w /root/MediaStack "$DIND_NAME" bash -c '
            ports=$(source scripts/lib/common.sh && service_http_ports_json) || exit 1
            exec python3 -I tests/contracts/observe.py --traces "$1" --events "$2" --ports "$ports" \
                --candidates "$3" --scenario "$4" --run-id "$5" --output "$6"' \
        _ "$CONTRACT_TRACE_DIR" "$RECEIPTS_EVENTS" "$candidates" "$scn" "$run_id" "$_CONTRACT_OUTPUT"; then
        _contract_say "$scn: the trace reducer failed; no contracts.json"
    elif ! docker exec "$DIND_NAME" cat "$_CONTRACT_OUTPUT" >"$MS_CONTRACTS_FILE"; then
        _contract_say "$scn: cannot copy contracts.json out of DinD"
        rm -f "$MS_CONTRACTS_FILE"
    else
        _contract_say "$scn: contracts.json written to $MS_CONTRACTS_FILE"
    fi
    _contract_clear || _contract_say "$scn: cannot remove the trace shims and raw traces"
    return 0
}

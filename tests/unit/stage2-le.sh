#!/usr/bin/env bash
# tests/unit/stage2-le.sh
#
# Contract tests for Stage 2 Let's Encrypt failure classification and copy.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-le"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/network.sh"
source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT_DIR="$TMP_ROOT"
mkdir -p "$SCRIPT_DIR/config/state" "$SCRIPT_DIR/config/npm/data/logs"

docker() { return "${STAGE2_LE_DOCKER_RC:-0}"; }
net_detect_public_ip() {
    _NET_PUBLIC_IP="203.0.113.10"
    return 0
}
net_dns_classify() {
    printf '%s' "${STAGE2_LE_DNS:-ok}"
    [[ "${STAGE2_LE_DNS:-ok}" == "ok" ]]
}
net_check_http_ports() { printf '%s' "${STAGE2_LE_PORTS:-ok}"; }
_stage2_probe_https_ready() { return 0; }
_stage2_le_ready_hosts() { printf '%s\n' ${STAGE2_LE_READY_HOSTS_FIXTURE:-}; }
_stage2_le_log_text() { printf '%s\n' "${STAGE2_LE_LOG_FIXTURE:-}"; }
_stage2_le_request_log_text() { printf '%s\n' "${STAGE2_LE_REQ_FIXTURE:-}"; }

reset_le_fixtures() {
    STAGE2_LE_DOCKER_RC=0
    STAGE2_LE_DNS=ok
    STAGE2_LE_PORTS=ok
    STAGE2_LE_READY_HOSTS_FIXTURE=""
    STAGE2_LE_LOG_FIXTURE=""
    STAGE2_LE_REQ_FIXTURE=""
    STAGE2_LE_CLASSIFICATION=""
    STAGE2_LE_READY_HOSTS=""
    STAGE2_LE_FAILED_HOSTS=""
}

for class in partial transient config-dns config-port rate-limited npm-unhealthy unknown; do
    reset_le_fixtures
    [[ "$class" == "partial" ]] && {
        STAGE2_LE_READY_HOSTS="jellyfin.gate.test"
        STAGE2_LE_FAILED_HOSTS="seerr.gate.test"
    }
    copy="$(stage2_le_failure_copy "$class")"
    assert_contains "$copy" "Add remote access" "$class copy points to remote retry"
done

reset_le_fixtures
STAGE2_LE_DOCKER_RC=1
stage2_le_classify gate.test >/dev/null
rc=$?
assert_eq "npm-unhealthy" "$STAGE2_LE_CLASSIFICATION" "nginx failure classifies as npm-unhealthy"
assert_eq "1" "$rc" "npm-unhealthy classification returns non-zero"

reset_le_fixtures
STAGE2_LE_READY_HOSTS_FIXTURE="jellyfin.gate.test"
stage2_le_classify gate.test >/dev/null
assert_eq "partial" "$STAGE2_LE_CLASSIFICATION" "one ready host classifies as partial"
assert_contains "$STAGE2_LE_READY_HOSTS" "jellyfin.gate.test" "partial tracks ready host"
assert_contains "$STAGE2_LE_FAILED_HOSTS" "seerr.gate.test" "partial tracks failed host"

reset_le_fixtures
STAGE2_LE_DNS=no-a
stage2_le_classify gate.test >/dev/null
assert_eq "config-dns" "$STAGE2_LE_CLASSIFICATION" "failed DNS gate classifies as config-dns"

reset_le_fixtures
STAGE2_LE_PORTS=closed:80
stage2_le_classify gate.test >/dev/null
assert_eq "config-port" "$STAGE2_LE_CLASSIFICATION" "closed port 80 classifies as config-port"

reset_le_fixtures
STAGE2_LE_LOG_FIXTURE='urn:ietf:params:acme:error:rateLimited'
stage2_le_classify gate.test >/dev/null
assert_eq "rate-limited" "$STAGE2_LE_CLASSIFICATION" "ACME rate limit classifies as rate-limited"

reset_le_fixtures
STAGE2_LE_LOG_FIXTURE='Timeout during connect (likely firewall problem)'
STAGE2_LE_REQ_FIXTURE='GET /.well-known/acme-challenge/token [Client 66.133.109.36]'
stage2_le_classify gate.test >/dev/null
assert_eq "transient" "$STAGE2_LE_CLASSIFICATION" "connection error with challenge hit classifies as transient"

reset_le_fixtures
STAGE2_LE_LOG_FIXTURE='Timeout during connect (likely firewall problem)'
stage2_le_classify gate.test >/dev/null
assert_eq "config-port" "$STAGE2_LE_CLASSIFICATION" "connection error without challenge hit classifies as config-port"

scenario_end "$CURRENT_SCENARIO"
summary

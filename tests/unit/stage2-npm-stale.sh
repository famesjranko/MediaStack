#!/usr/bin/env bash
# tests/unit/stage2-npm-stale.sh
#
# Contract tests for warning-only NPM stale-host handling. Fixture files must
# remain byte-identical after the helper runs.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-npm-stale"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"

source "$REPO_ROOT/scripts/lib/npm-remote.sh"
source "$REPO_ROOT/scripts/services/npm/main.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

WARN_COUNT=0
LAST_WARN=""
log_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    LAST_WARN="$*"
}
log_info() { :; }
log_ok() { :; }
log_skip() { :; }
log_error() { :; }

DOCKER_INSPECT_ARGS_FILE="$TMP_ROOT/docker-inspect-args"
DOCKER_INSPECT_RESULT=true
docker() {
    if [[ "$1" == "inspect" ]]; then
        printf '%s\n' "$*" >"$DOCKER_INSPECT_ARGS_FILE"
        printf '%s\n' "$DOCKER_INSPECT_RESULT"
        return 0
    fi
    return 1
}
npm_remote_container_running
running_rc=$?
assert_eq "0" "$running_rc" "npm_remote_container_running: returns true for running npm"
assert_eq "inspect --format {{.State.Running}} npm" "$(cat "$DOCKER_INSPECT_ARGS_FILE")" "npm_remote_container_running: checks exact npm running state"
DOCKER_INSPECT_RESULT=false
npm_remote_container_running
stopped_rc=$?
assert_eq "1" "$stopped_rc" "npm_remote_container_running: returns false for stopped npm"
source "$REPO_ROOT/scripts/lib/npm-remote.sh"
assert_eq "function" "$(type -t container_running)" "npm-remote.sh: sources common.sh and is repeat-source safe"

FAKE_HOSTS='[
  {"id": 1, "domain_names": ["jellyfin.old.test"], "forward_host": "jellyfin", "forward_port": 8096, "enabled": true},
  {"id": 2, "domain_names": ["jellyfin.gate.test"], "forward_host": "jellyfin", "forward_port": 8096, "enabled": true},
  {"id": 3, "domain_names": ["seerr.gate.test"], "forward_host": "seerr", "forward_port": 5055, "enabled": true}
]'

_npm_warn_stale_managed_hosts "token" "http://npm.test/api" "gate.test" "$FAKE_HOSTS"
rc=$?

assert_eq "0" "$rc" "stale-host check is non-fatal"
assert_eq "1" "$WARN_COUNT" "stale-host check emits one warning"
assert_contains "$LAST_WARN" "NPM has proxy hosts for a different domain" "stale-host warning names NPM domain drift"

MUTATION_CALLS=0
curl() {
    case "$*" in
        *"-X POST"*"/api/nginx/certificates"* | *"-X PUT"*"/api/nginx/proxy-hosts"* | *"-X POST"*"/api/nginx/proxy-hosts"* | *"-X DELETE"*"/api/nginx/proxy-hosts"*)
            MUTATION_CALLS=$((MUTATION_CALLS + 1))
            return 22
            ;;
        *"/api/tokens"*)
            printf '{"token":"ready-token"}\n'
            ;;
        *"/api/nginx/certificates"*)
            printf '[{"id":11,"is_deleted":false,"domain_names":["jellyfin.gate.test"]},{"id":12,"is_deleted":false,"domain_names":["seerr.gate.test"]}]\n'
            ;;
        *"/api/nginx/proxy-hosts"*)
            printf '[{"id":2,"domain_names":["jellyfin.gate.test"],"certificate_id":11,"enabled":true},{"id":3,"domain_names":["seerr.gate.test"],"certificate_id":12,"enabled":true}]\n'
            ;;
        *)
            return 22
            ;;
    esac
}

docker() {
    if [[ "$1" == "inspect" ]]; then
        printf 'false\n'
        return 0
    fi
    return 1
}

export NPM_ADMIN_EMAIL="admin@gate.test"
export JELLYFIN_ADMIN_PASSWORD="password"
SCRIPT_DIR="$TMP_ROOT"
mkdir -p "$TMP_ROOT/config/npm/letsencrypt/live/npm-11" \
    "$TMP_ROOT/config/npm/letsencrypt/live/npm-12" \
    "$TMP_ROOT/config/npm/data/nginx/proxy_host"
touch "$TMP_ROOT/config/npm/letsencrypt/live/npm-11/fullchain.pem" \
    "$TMP_ROOT/config/npm/letsencrypt/live/npm-11/privkey.pem" \
    "$TMP_ROOT/config/npm/letsencrypt/live/npm-12/fullchain.pem" \
    "$TMP_ROOT/config/npm/letsencrypt/live/npm-12/privkey.pem"
cat >"$TMP_ROOT/config/npm/data/nginx/proxy_host/2.conf" <<'EOF'
server_name jellyfin.gate.test;
ssl_certificate /etc/letsencrypt/live/npm-11/fullchain.pem;
EOF
cat >"$TMP_ROOT/config/npm/data/nginx/proxy_host/3.conf" <<'EOF'
server_name seerr.gate.test;
ssl_certificate /etc/letsencrypt/live/npm-12/fullchain.pem;
EOF

npm_remote_hosts_ready "gate.test"
ready_rc=$?
assert_eq "0" "$ready_rc" "npm_remote_hosts_ready accepts cert files plus rendered proxy hosts"
assert_eq "0" "$MUTATION_CALLS" "readiness and stale scans do not call mutation endpoints"

rm -f "$TMP_ROOT/config/npm/data/nginx/proxy_host/3.conf"
npm_remote_hosts_ready "gate.test"
missing_rc=$?
assert_eq "1" "$missing_rc" "npm_remote_hosts_ready rejects missing rendered proxy config"

npm_source="$(cat "$REPO_ROOT/scripts/services/npm/main.sh" "$REPO_ROOT/scripts/services/npm/publication.sh")"
assert_contains "$npm_source" "MEDIASTACK_NPM_ATTEMPT_REMOTE" "NPM has scoped Stage 2 attempt flag"
assert_contains "$npm_source" "remote_attempt_allowed" "NPM separates remote attempt allowance from global ready state"
assert_contains "$npm_source" "Disabled non-ready proxy host" "non-ready current-domain host disable path remains"

if grep -q "MEDIASTACK_NPM_ATTEMPT_REMOTE" "$REPO_ROOT/.env.example"; then
    fail "process-scoped attempt flag is not persisted to .env.example"
else
    pass "process-scoped attempt flag is not persisted to .env.example"
fi

scenario_end "$CURRENT_SCENARIO"
summary

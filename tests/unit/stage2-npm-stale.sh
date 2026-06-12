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

[[ -f "$REPO_ROOT/scripts/lib/npm_remote.sh" ]] && source "$REPO_ROOT/scripts/lib/npm_remote.sh"
[[ -f "$REPO_ROOT/scripts/services/npm/main.sh" ]] && source "$REPO_ROOT/scripts/services/npm/main.sh"

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

if ! type npm_remote_hosts_ready >/dev/null 2>&1; then
    npm_remote_hosts_ready() { return 127; }
fi
if ! type _npm_warn_stale_managed_hosts >/dev/null 2>&1; then
    _npm_warn_stale_managed_hosts() { return 127; }
fi

FAKE_HOSTS='[
  {"id": 1, "domain_names": ["jellyfin.old.test"], "forward_host": "jellyfin", "forward_port": 8096, "enabled": true},
  {"id": 2, "domain_names": ["jellyfin.gate.test"], "forward_host": "jellyfin", "forward_port": 8096, "enabled": true},
  {"id": 3, "domain_names": ["seerr.gate.test"], "forward_host": "seerr", "forward_port": 5055, "enabled": true}
]'

_npm_warn_stale_managed_hosts "token" "http://npm.test/api" "gate.test" "$FAKE_HOSTS"; rc=$?

assert_eq "0" "$rc" "S2-17: stale-host check is non-fatal"
assert_eq "1" "$WARN_COUNT" "S2-17: stale-host check emits one warning"
assert_contains "$LAST_WARN" "NPM has proxy hosts for a different domain" "S2-17: stale-host warning names NPM domain drift"

MUTATION_CALLS=0
curl() {
    case "$*" in
        *"-X POST"*"/api/nginx/certificates"*|*"-X PUT"*"/api/nginx/proxy-hosts"*|*"-X POST"*"/api/nginx/proxy-hosts"*|*"-X DELETE"*"/api/nginx/proxy-hosts"*)
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

npm_remote_hosts_ready "gate.test"; ready_rc=$?
assert_eq "0" "$ready_rc" "S2-15: npm_remote_hosts_ready accepts cert files plus rendered proxy hosts"
assert_eq "0" "$MUTATION_CALLS" "S2-14/S2-17: readiness and stale scans do not call mutation endpoints"

rm -f "$TMP_ROOT/config/npm/data/nginx/proxy_host/3.conf"
npm_remote_hosts_ready "gate.test"; missing_rc=$?
assert_eq "1" "$missing_rc" "S2-15: npm_remote_hosts_ready rejects missing rendered proxy config"

npm_source="$(cat "$REPO_ROOT/scripts/services/npm/main.sh")"
assert_contains "$npm_source" "MEDIASTACK_NPM_ATTEMPT_REMOTE" "S2-13: NPM has scoped Stage 2 attempt flag"
assert_contains "$npm_source" "remote_attempt_allowed" "S2-13: NPM separates remote attempt allowance from global ready state"
assert_contains "$npm_source" "Disabled non-ready proxy host" "GATE-03: non-ready current-domain host disable path remains"

if grep -q "MEDIASTACK_NPM_ATTEMPT_REMOTE" "$REPO_ROOT/.env.example"; then
    fail "S2-13: process-scoped attempt flag is not persisted to .env.example"
else
    pass "S2-13: process-scoped attempt flag is not persisted to .env.example"
fi

scenario_end "$CURRENT_SCENARIO"
summary

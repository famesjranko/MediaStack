# Accepted NPM proxy, admin and certificate state must survive the real update.

npm_upgrade_state() { dind_exec "python3 -I tests/fixtures/npm_state.py $1"; }

npm_upgrade_certbot_probe() {
    dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} python3 -I tests/fixtures/npm_certbot_lock.py"
}

npm_upgrade_disable_user_proxy() {
    docker exec -i -e "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-}" -w /root/MediaStack "$DIND_NAME" bash -s <<'BASH'
set -euo pipefail
SCRIPT_DIR=$PWD
CONFIG_FILE=$SCRIPT_DIR/config.yml
set -a
source .env
set +a
source scripts/lib/common.sh
source scripts/services/npm/main.sh
api="$(service_local_url npm)/api"
token=$(npm_remote_token "$api")
host_id=$(python3 -c 'import json; print(next(h["id"] for h in json.load(open("/tmp/ms-npm-before.json"))["hosts"] if h["domain_names"] == ["upgrade-fixture.invalid"]))')
status=$(_npm_disable_host "$token" "$api" "$host_id")
[[ "$status" =~ ^2 ]]
BASH
}

run_scenario() {
    local accepted candidate actual
    accepted=$(awk -F '\t' '$1 == "npm" {print $2 "@" $3}' "$REPO_ROOT/docs/operations/image-digests.lock")
    candidate=$(ms_test_image npm "$accepted") || return 1
    if [[ "$candidate" != *@sha256:* || (-n "${MS_TEST_IMAGE_OVERRIDES:-}" && "$candidate" == "$accepted") ]]; then
        fail 'npm-upgrade requires a changed exact NPM candidate digest'
        return 1
    fi
    dind_exec 'cp docs/operations/image-digests.lock /tmp/npm-target.lock' || return 1
    dind_write_file docs/operations/image-digests.lock <"$REPO_ROOT/docs/operations/image-digests.lock" || return 1
    dind_exec 'cp .env.example .env; cp config/examples/config.yml config.yml' || return 1
    env_set IMAGE_CHANNEL stable
    env_set NPM_ADMIN_EMAIL migration@example.test
    env_set JELLYFIN_ADMIN_PASSWORD 'npm-migration-password'
    env_set DOMAIN migration.test
    env_set REMOTE_WEB_STATE ready
    env_set NPM_LE_SERVER https://pebble:14000/dir
    env_set ADMIN_PORT_FILTER false
    env_set HARDENING_ENABLED false
    env_set UFW_ENABLED false
    env_set DATA_DIR /tmp/ms-data
    env_set JELLYFIN_GPU none
    create_config_dirs_in_dind || return 1
    # Keep the real NPM definition; no companion application is needed for a
    # TLS handshake or a database comparison. Fresh-install proves forwarding.
    dind_python <<'PY' || return 1
import pathlib, yaml
p = pathlib.Path("docker-compose.yml")
compose = yaml.safe_load(p.read_text())
for name, service in compose["services"].items():
    if name != "npm":
        service["profiles"] = ["npm-fixture-unused"]
p.write_text(yaml.safe_dump(compose, sort_keys=False))
PY
    npm_acme_override
    local compose_files=docker-compose.yml:docker-compose.override.yml:docker-compose.acme-test.yml
    dind_exec 'bash -c '\''source setup.sh; detect_host_memory; generate_override none'\''' >/dev/null 2>&1 || return 1
    dind_exec "COMPOSE_FILE=$compose_files docker compose --profile proxy up -d npm" >/dev/null 2>&1 \
        && wait_healthy npm 150 && pebble_up && pebble_setup_dns || {
        fail 'npm-upgrade accepted NPM and local ACME start'
        return 1
    }
    actual=$(dind_exec "docker ps --no-trunc --filter name=^npm\$ --format '{{.Image}}'" | tr -d '\r\n')
    assert_eq "$accepted" "$actual" 'npm-upgrade starts the accepted digest'
    local configure="MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} ./scripts/configure.sh --only npm"
    dind_exec "$configure >/tmp/ms-npm-configure.log 2>&1" \
        && npm_upgrade_state seed && npm_upgrade_state probe && npm_upgrade_state served || {
        fail 'npm-upgrade records accepted state and detects a changed user proxy'
        return 1
    }
    pass 'npm-upgrade records accepted proxy, admin, certificate and private-key state'
    dind_exec 'cp /tmp/npm-target.lock docs/operations/image-digests.lock' || return 1
    dind_exec "COMPOSE_FILE=$compose_files MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/update.sh >/tmp/ms-npm-update.log 2>&1" || {
        fail 'npm-upgrade real update.sh succeeds'
        return 1
    }
    if [[ "$candidate" == "$accepted" ]]; then
        dind_exec "COMPOSE_FILE=$compose_files docker compose --profile proxy up -d --force-recreate npm" >/dev/null 2>&1 || return 1
        pass 'npm-upgrade baseline only: recreated accepted image, no candidate evidence'
    fi
    wait_healthy npm 150 && pebble_setup_dns || return 1
    actual=$(dind_exec "docker ps --no-trunc --filter name=^npm\$ --format '{{.Image}}'" | tr -d '\r\n')
    assert_eq "$candidate" "$actual" 'npm-upgrade runs the exact target digest'
    if npm_upgrade_certbot_probe; then
        pass 'npm-upgrade detects a real Certbot lock and its release'
    else
        fail 'npm-upgrade detects a real Certbot lock and its release'
        return 1
    fi
    npm_upgrade_state check && npm_upgrade_state served || {
        fail 'npm-upgrade preserves state and serves the saved certificates before repair'
        return 1
    }
    pass 'npm-upgrade preserves state and serves the saved certificates before repair'
    dind_exec "$configure >/tmp/ms-npm-configure.log 2>&1" \
        && npm_upgrade_state check && npm_upgrade_state served || {
        fail 'npm-upgrade reconfiguration preserves saved state and HTTPS'
        return 1
    }
    pass 'npm-upgrade reconfiguration preserves saved state and HTTPS'
    # The seeded user proxy is already disabled. The real rollback helper must
    # read and rewrite it without losing custom locations or other user fields.
    npm_upgrade_disable_user_proxy && npm_upgrade_state check || {
        fail 'npm-upgrade product rollback preserves a disabled user proxy and its locations'
        return 1
    }
    pass 'npm-upgrade product rollback preserves a disabled user proxy and its locations'
    # Existing default-admin recovery and opt-in rate-zone creation must run
    # through product code on the candidate, so their contracts have evidence.
    npm_upgrade_state legacy || return 1
    env_set DOMAIN ''
    dind_python <<'PY' || return 1
import pathlib, yaml
p = pathlib.Path("config.yml")
config = yaml.safe_load(p.read_text())
config["rate_limiting"]["enabled"] = True
p.write_text(yaml.safe_dump(config, sort_keys=False))
PY
    dind_exec "$configure >/tmp/ms-npm-legacy.log 2>&1" || {
        fail 'npm-upgrade product legacy rotation and rate-zone reload succeed'
        return 1
    }
    env_set DOMAIN migration.test
    npm_upgrade_state check && npm_upgrade_state renew || {
        fail 'npm-upgrade restores legacy credentials and deploys renewed certificates'
        return 1
    }
    pass 'npm-upgrade restores legacy credentials and deploys renewed certificates'
}

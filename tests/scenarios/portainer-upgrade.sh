# Portainer data must survive update.sh before any reconfiguration can repair it.

portainer_upgrade_state() { dind_exec "python3 -I tests/fixtures/portainer_state.py $1"; }

run_scenario() {
    local accepted candidate actual
    accepted=$(awk -F '\t' '$1 == "portainer" {print $2 "@" $3}' "$REPO_ROOT/docs/operations/image-digests.lock")
    candidate=$(ms_test_image portainer "$accepted") || return 1
    if [[ "$candidate" != *@sha256:* || (-n "${MS_TEST_IMAGE_OVERRIDES:-}" && "$candidate" == "$accepted") ]]; then
        fail 'portainer-upgrade requires a changed exact candidate digest'
        return 1
    fi
    dind_exec 'cp docs/operations/image-digests.lock /tmp/portainer-target.lock' || return 1
    dind_write_file docs/operations/image-digests.lock <"$REPO_ROOT/docs/operations/image-digests.lock" || return 1
    dind_exec 'cp .env.example .env; cp config/examples/config.yml config.yml' || return 1
    env_set IMAGE_CHANNEL stable
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD 'portainer-migration-password'
    env_set ADMIN_PORT_FILTER false
    env_set HARDENING_ENABLED false
    env_set UFW_ENABLED false
    env_set DATA_DIR /tmp/ms-data
    env_set JELLYFIN_GPU none
    create_config_dirs_in_dind || return 1
    # Keep the real service definition and update script; other services are
    # inactive in this dedicated database migration fixture.
    dind_python <<'PY' || return 1
import pathlib, yaml
p = pathlib.Path("docker-compose.yml")
compose = yaml.safe_load(p.read_text())
for name, service in compose["services"].items():
    if name != "portainer":
        service["profiles"] = ["portainer-fixture-unused"]
p.write_text(yaml.safe_dump(compose, sort_keys=False))
PY
    dind_exec 'bash -c '\''source setup.sh; detect_host_memory; generate_override none'\''' >/dev/null 2>&1 || return 1
    dind_exec 'docker compose up -d portainer' >/dev/null 2>&1 || {
        fail 'portainer-upgrade accepted image starts'
        return 1
    }
    actual=$(dind_exec "docker inspect --format '{{.Config.Image}}' portainer")
    assert_eq "$accepted" "$actual" 'portainer-upgrade starts the accepted digest'
    local configure="MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} ./scripts/configure.sh --only portainer"
    dind_exec "$configure >/tmp/ms-portainer-configure.log 2>&1" \
        && portainer_upgrade_state seed && portainer_upgrade_state probe \
        && portainer_upgrade_state save && portainer_upgrade_state check || {
        fail 'portainer-upgrade seeds users, token and tagged local endpoint'
        return 1
    }
    pass 'portainer-upgrade records accepted data and detects a persisted change'
    dind_exec 'cp /tmp/portainer-target.lock docs/operations/image-digests.lock' || return 1
    dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/update.sh >/tmp/ms-portainer-update.log 2>&1" || {
        fail 'portainer-upgrade real update.sh succeeds'
        return 1
    }
    pass 'portainer-upgrade real update.sh succeeds'
    if [[ "$candidate" == "$accepted" ]]; then
        dind_exec 'docker compose up -d --force-recreate portainer' >/dev/null 2>&1 || return 1
        pass 'portainer-upgrade baseline only: recreated accepted image, no candidate evidence'
    fi
    actual=$(dind_exec "docker inspect --format '{{.Config.Image}}' portainer")
    assert_eq "$candidate" "$actual" 'portainer-upgrade runs the exact target digest'
    # Portainer has no container healthcheck. Bound readiness with its public
    # status API, and authenticate only after it answers.
    dind_exec 'curl --retry 30 --retry-delay 1 --retry-connrefused --max-time 3 --retry-max-time 60 -fsS http://127.0.0.1:9000/api/status >/dev/null' \
        && portainer_upgrade_state check || {
        fail 'portainer-upgrade preserves data and working logins before reconfiguration'
        return 1
    }
    pass 'portainer-upgrade preserves data and working logins before reconfiguration'
    dind_exec "$configure >/tmp/ms-portainer-configure.log 2>&1" && portainer_upgrade_state check || {
        fail 'portainer-upgrade reconfiguration preserves user data and stored token'
        return 1
    }
    pass 'portainer-upgrade reconfiguration preserves user data and stored token'
    # Exercise the supported legacy-admin rename on the candidate too. Change
    # only the expected username; IDs, roles, token and endpoint data must stay.
    env_set JELLYFIN_ADMIN_USER migration-admin
    dind_python <<'PY' || return 1
import json, pathlib
p = pathlib.Path("/tmp/portainer-state.json")
state = json.loads(p.read_text())
next(u for u in state["users"] if u["Username"] == "admin")["Username"] = "migration-admin"
p.write_text(json.dumps(state))
PY
    dind_exec "$configure >/tmp/ms-portainer-configure.log 2>&1" && portainer_upgrade_state check || {
        fail 'portainer-upgrade legacy admin rename keeps IDs, permissions and stored token'
        return 1
    }
    pass 'portainer-upgrade legacy admin rename keeps IDs, permissions and stored token'
}

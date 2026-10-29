# Accepted wg-easy state must survive update.sh before any repair runs.

wireguard_upgrade_state() { dind_exec "python3 -I tests/fixtures/wireguard_state.py $1"; }

wireguard_upgrade_override() {
    dind_exec 'bash -c '\''set -a; source .env; set +a; SCRIPT_DIR=$PWD; source scripts/lib/common.sh; source scripts/setup/override.sh; detect_host_memory; generate_override none'\'''
}

run_scenario() {
    local accepted candidate
    accepted=$(awk -F '\t' '$1 == "wireguard" {print $2 "@" $3}' "$REPO_ROOT/docs/operations/image-digests.lock")
    candidate=$(ms_test_image wireguard "$accepted") || return 1
    if [[ "$candidate" != *@sha256:* ]]; then
        fail 'wireguard-upgrade requires an exact candidate digest'
        return 1
    fi
    if [[ -n "${MS_TEST_IMAGE_OVERRIDES:-}" && "$candidate" == "$accepted" ]]; then
        fail 'wireguard-upgrade requires a changed WireGuard candidate'
        return 1
    fi
    dind_exec 'cp docs/operations/image-digests.lock /tmp/wireguard-target.lock' || return 1
    dind_write_file docs/operations/image-digests.lock <"$REPO_ROOT/docs/operations/image-digests.lock" || return 1
    dind_exec 'cp .env.example .env; cp config/examples/config.yml config.yml' || return 1
    env_set IMAGE_CHANNEL stable
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD 'wg-migration-password'
    env_set WG_INIT_PASSWORD 'wg-migration-password'
    env_set WG_HOST 192.0.2.10
    env_set WG_PORT 51920
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_ALLOWED_IPS 192.168.50.0/24
    env_set WG_ACCESS_TIER full-lan
    env_set WG_LAN_CIDR 192.168.50.0/24
    env_set WG_PER_CLIENT_FIREWALL true
    env_set ADMIN_PORT_FILTER false
    env_set HARDENING_ENABLED false
    env_set UFW_ENABLED false
    env_set DATA_DIR /tmp/ms-data
    env_set JELLYFIN_GPU none
    create_config_dirs_in_dind || return 1
    # Keep the production service definition. In this dedicated fixture the
    # other services are inactive, including during the unmodified update.sh.
    dind_python <<'PY' || return 1
import pathlib, yaml
p = pathlib.Path("docker-compose.yml")
compose = yaml.safe_load(p.read_text())
for name, service in compose["services"].items():
    if name != "wireguard":
        service["profiles"] = ["wireguard-fixture-unused"]
p.write_text(yaml.safe_dump(compose, sort_keys=False))
PY
    wireguard_upgrade_override >/dev/null 2>&1 || return 1
    dind_exec 'docker compose --profile remote up -d wireguard' >/dev/null 2>&1 && wait_healthy wireguard 150 || {
        fail 'wireguard-upgrade accepted image starts'
        return 1
    }
    local actual
    actual=$(dind_exec "docker ps --no-trunc --filter name=^wireguard\$ --format '{{.Image}}'" | tr -d '\r\n')
    assert_eq "$accepted" "$actual" 'wireguard-upgrade starts the accepted digest'
    dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} ./scripts/configure.sh --only wireguard >/tmp/ms-wireguard-configure.log 2>&1" \
        && wireguard_upgrade_state seed && wireguard_upgrade_state probe && wireguard_upgrade_state save && wireguard_upgrade_state check || {
        fail 'wireguard-upgrade seeds and records existing peers'
        return 1
    }
    pass 'wireguard-upgrade records accepted peers, keys, export and kernel configuration'

    dind_exec 'cp /tmp/wireguard-target.lock docs/operations/image-digests.lock' || return 1
    if dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/update.sh >/tmp/ms-wireguard-update.log 2>&1" \
        && wait_healthy wireguard 150; then
        pass 'wireguard-upgrade real update.sh succeeds'
    else
        fail 'wireguard-upgrade real update.sh succeeds'
        return 1
    fi
    if [[ "$candidate" == "$accepted" ]]; then
        dind_exec 'docker compose --profile remote up -d --force-recreate wireguard' >/dev/null 2>&1 && wait_healthy wireguard 150 || return 1
        pass 'wireguard-upgrade baseline only: recreated accepted image, no candidate evidence'
    fi
    actual=$(dind_exec "docker ps --no-trunc --filter name=^wireguard\$ --format '{{.Image}}'" | tr -d '\r\n')
    assert_eq "$candidate" "$actual" 'wireguard-upgrade runs the exact target digest'
    if wireguard_upgrade_state check; then
        pass 'wireguard-upgrade preserves state before reconfiguration'
    else
        fail 'wireguard-upgrade preserves state before reconfiguration'
        return 1
    fi
    dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} ./scripts/configure.sh --only wireguard >/tmp/ms-wireguard-configure.log 2>&1" \
        && wireguard_upgrade_state check || {
        fail 'wireguard-upgrade reconfiguration preserves existing peers'
        return 1
    }
    pass 'wireguard-upgrade reconfiguration preserves existing peers'
}

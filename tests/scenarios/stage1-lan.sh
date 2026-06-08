# tests/scenarios/stage1-lan.sh — TEST-01 Stage 1 LAN-only install.
#
# This is an in-VM DinD proof only. It proves the Stage 1 install controller
# can build a LAN stack from an explicit no-domain/no-GPU fixture.

stage1_lan_env_is_not_ready() {
    local state
    state="$(env_get REMOTE_WEB_STATE)"
    if [[ -z "$state" || "$state" != "ready" ]]; then
        pass "TEST-01: REMOTE_WEB_STATE is blank or not ready"
    else
        fail "TEST-01: REMOTE_WEB_STATE is blank or not ready" "state=$state"
    fi
}

stage1_lan_run_install() {
    local log_path="/tmp/stage1-lan.out"
    if dind_exec "bash -lc '
set -euo pipefail
SCRIPT_DIR=/root/MediaStack
CONFIG_FILE=/root/MediaStack/config.yml
cd \"\$SCRIPT_DIR\"

sudo() { \"\$@\"; }
source scripts/lib/common.sh
source scripts/lib/ui.sh
source scripts/setup/override.sh
source scripts/setup/env_gen.sh
source scripts/setup/wizard.sh
source scripts/setup/stack.sh

detect_host_memory

log_info \"TEST-01: running focused Stage 1 LAN install path\"
unset DOMAIN REMOTE_WEB_STATE COMPOSE_PROFILES
export DOMAIN= REMOTE_WEB_STATE=
stop_existing_stack
create_data_dirs
create_config_dirs
generate_override none

python3 \"\$SCRIPT_DIR/scripts/setup/wizard_apply.py\" \
    --resolution 1080p \
    --size balanced \
    --languages english \
    --bitrate-limit 0 \
    --config \"\$SCRIPT_DIR/config.yml\"

for image in jellyfin/jellyfin:latest ghcr.io/gethomepage/homepage:latest; do
    for attempt in 1 2 3; do
        if docker image inspect \"\$image\" >/dev/null 2>&1 || docker pull \"\$image\"; then
            break
        fi
        sleep \$((attempt * 5))
    done
    docker image inspect \"\$image\" >/dev/null
done

docker compose up -d --no-build --pull never jellyfin homepage
wait_all_healthy

log_info \"Running Stage 1 LAN auto-configuration...\"
\"\$SCRIPT_DIR/scripts/configure.sh\" --only jellyfin,homepage
sed -i -e s/^DOMAIN=.*/DOMAIN=/ -e s/^REMOTE_WEB_STATE=.*/REMOTE_WEB_STATE=/ .env
docker rm -f npm fail2ban ddns-updater 2>/dev/null || true

for waited in \$(seq 0 3 120); do
    status=\$(docker inspect --format \"{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}\" jellyfin 2>/dev/null || true)
    case \"\$status\" in
        healthy|running) break ;;
    esac
    sleep 3
done
if curl --max-time 10 -fsS \"http://127.0.0.1:8096/health\" >/dev/null 2>&1; then
    sed -i \"s/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/\" \"\$SCRIPT_DIR/.env\"
    log_ok \"Stage 1 complete (STAGE_1_COMPLETE=1)\"
else
    log_error \"Jellyfin did not respond on LAN; Stage 1 marker not set\"
    exit 1
fi
'" >"$log_path" 2>&1; then
        pass "TEST-01: focused Stage 1 LAN install path exits 0"
    else
        fail "TEST-01: focused Stage 1 LAN install path exits 0"
        tail -80 "$log_path"
        return 1
    fi
}

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "docker rm -f jellyfin homepage npm fail2ban ddns-updater 2>/dev/null || true"
    dind_exec "rm -rf config/jellyfin config/homepage config/npm config/ddns-updater docker-compose.override.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind
    dind_exec "cp .env.example .env"

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@lan.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD lan-test-password
    env_set JELLYFIN_GPU none
    env_set DOMAIN ""
    env_set REMOTE_WEB_STATE ""
    env_set WG_HOST ""
    env_set WG_INIT_PASSWORD "''"
    env_set WG_DEFAULT_DNS 1.1.1.1

    assert_eq "" "$(env_get DOMAIN)" "TEST-01: DOMAIN is blank before Stage 1"
    stage1_lan_env_is_not_ready

    stage1_lan_run_install || return 1

    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "TEST-01: STAGE_1_COMPLETE=1 after Stage 1"
    assert_eq "" "$(env_get DOMAIN)" "TEST-01: DOMAIN is blank after Stage 1"
    stage1_lan_env_is_not_ready

    if dind_exec "curl --max-time 10 -fsS http://127.0.0.1:8096/health >/dev/null"; then
        pass "TEST-01: Jellyfin responds on LAN"
    else
        fail "TEST-01: Jellyfin responds on LAN"
    fi

    local npm_id
    npm_id="$(dind_exec "docker compose ps -q npm 2>/dev/null || true" | tr -d '\r\n')"
    if [[ -z "$npm_id" ]]; then
        pass "TEST-01: no public proxy service is running for blank DOMAIN"
    else
        fail "TEST-01: no public proxy service is running for blank DOMAIN" "npm_id=$npm_id"
    fi

    assert_eq "none" "$(env_get JELLYFIN_GPU)" "TEST-01: JELLYFIN_GPU remains none"
    assert_eq "" "$(env_get STAGE_3_GPU_STATE)" "TEST-01: no Stage 3 GPU state is published"

    if dind_exec "python3 - <<'PY'
import sys
import yaml

with open('docker-compose.override.yml') as fh:
    data = yaml.safe_load(fh) or {}
jellyfin = (data.get('services') or {}).get('jellyfin') or {}
bad = []
if jellyfin.get('runtime'):
    bad.append('runtime')
if jellyfin.get('devices'):
    bad.append('devices')
if bad:
    print(','.join(bad))
    sys.exit(1)
PY
" >/tmp/stage1-lan-gpu.out 2>&1; then
        pass "TEST-01: generated override has no Jellyfin GPU runtime/devices"
    else
        fail "TEST-01: generated override has no Jellyfin GPU runtime/devices" "$(cat /tmp/stage1-lan-gpu.out)"
    fi
}

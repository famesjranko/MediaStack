# tests/scenarios/stage2-ready.sh — Stage 2 ready HTTPS postcondition path.
#
# Uses Pebble and fixture DNS only. Production Let's Encrypt and real Dynu
# credentials are intentionally outside this DinD scenario.

source tests/assertions/remote-gating.sh

stage2_ready_assert_fixture_postconditions() {
    local token proxy_hosts ready_check

    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "TEST-02 fixture DNS/Pebble: REMOTE_WEB_STATE=ready after cert/proxy postconditions"

    token="$(remote_gating_npm_token)"
    proxy_hosts="$(remote_gating_fetch_npm_hosts "$token")"
    ready_check="$(echo "$proxy_hosts" | DIND="$DIND_NAME" python3 -c '
import json
import os
import subprocess
import sys

managed = {"jellyfin.gate.test", "seerr.gate.test"}
try:
    hosts = json.load(sys.stdin)
except Exception:
    hosts = []

published = {}
missing = []
for host in hosts:
    domains = set(host.get("domain_names") or [])
    matched = managed.intersection(domains)
    if not matched or not host.get("enabled"):
        continue
    cid = int(host.get("certificate_id") or 0)
    hid = host.get("id")
    for domain in matched:
        published[domain] = cid
    if cid <= 0:
        missing.append(f"cert_id:{sorted(matched)}")
        continue
    for path in (
        f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/fullchain.pem",
        f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/privkey.pem",
        f"/root/MediaStack/config/npm/data/nginx/proxy_host/{hid}.conf",
    ):
        if subprocess.run(["docker", "exec", os.environ["DIND"], "test", "-f", path],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode != 0:
            missing.append(path)

unpublished = sorted(managed - set(published))
if unpublished or missing:
    print(f"unpublished={unpublished} missing={missing}")
else:
    print("OK")
' 2>/dev/null | tr -d '\r')"

    if [[ "$ready_check" == "OK" ]]; then
        pass "TEST-02 fixture DNS/Pebble: NPM has enabled cert-backed Jellyfin/Seerr hosts with disk material"
    else
        fail "TEST-02 fixture DNS/Pebble: NPM has enabled cert-backed Jellyfin/Seerr hosts with disk material" "$ready_check"
    fi
}

stage2_ready_configure() {
    local log_path="/tmp/stage2-ready.out"
    if dind_exec "./scripts/configure.sh --only jellyfin,homepage,npm" >"$log_path" 2>&1; then
        pass "stage2 ready: configure.sh --only jellyfin,homepage,npm exits 0"
    else
        fail "stage2 ready: configure.sh --only jellyfin,homepage,npm exits 0"
        tail -40 "$log_path"
        return 1
    fi
}

stage2_run_install() {
    local log_path="/tmp/stage2-ready-install.out"
    if dind_exec "COMPOSE_FILE=docker-compose.yml:docker-compose.acme-test.yml bash -lc '
set -uo pipefail
SCRIPT_DIR=/root/MediaStack
source scripts/lib/common.sh
source scripts/lib/network.sh
source scripts/lib/validators.sh
source scripts/setup/env-gen.sh
source scripts/setup/stack.sh
source scripts/setup/wizard.sh
source scripts/setup/stages/stage2.sh
set -a
source .env
set +a

eval \"\$(declare -f start_stack | sed \"1s/start_stack/_stage2_original_start_stack/\")\"
start_stack() {
    _stage2_original_start_stack
    local npm_ip challtestsrv_ip
    npm_ip=\$(docker inspect -f \"{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}\" npm)
    challtestsrv_ip=\$(docker inspect -f \"{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}\" pebble-challtestsrv)
    curl -sf -X POST \"http://\${challtestsrv_ip}:8055/set-default-ipv4\" -d \"{\\\"ip\\\":\\\"\${npm_ip}\\\"}\" >/dev/null
    curl -sf -X POST \"http://\${challtestsrv_ip}:8055/set-default-ipv6\" -d \"{\\\"ip\\\":\\\"\\\"}\" >/dev/null
}

_ENV_TZ=Etc/UTC
_ENV_PUID=1000
_ENV_PGID=1000
_ENV_HOST_ADDRESS=127.0.0.1
_WIZ_TZ=Etc/UTC
_WIZ_DATA_DIR=/tmp/ms-data
_WIZ_ADMIN_USER=admin
_WIZ_ADMIN_EMAIL=admin@gate.test
_WIZ_ADMIN_PW=\"\${JELLYFIN_ADMIN_PASSWORD}\"
_WIZ_DOMAIN=gate.test
_WIZ_WG_HOST=gate.test
_WIZ_WG_PORT=51820
_WIZ_WG_DNS=1.1.1.1
_WIZ_WG_ACCESS_TIER=full-lan
_WIZ_WG_LAN_CIDR=\"192.168.1.0/24\"
_WIZ_WG_SERVER_LAN_IP=\"192.168.1.10\"
_WIZ_WG_INIT_ALLOWED_IPS=\"192.168.1.0/24\"
_WIZ_WG_PER_CLIENT_FIREWALL=true
_WIZ_REMOTE_WEB_STATE=unchecked
_WIZ_TORRENT_PORT=6881
_WIZ_DL_LIMIT=0
_WIZ_UL_LIMIT=0
_WIZ_BAZARR_ENABLED=false
_WIZ_SMB_ENABLED=false

_stage2_install
'" >"$log_path" 2>&1; then
        pass "stage2 ready: _stage2_install exits 0"
    else
        fail "stage2 ready: _stage2_install exits 0"
        tail -80 "$log_path"
        return 1
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"
    assert_contains "$log_plain" "Remote access is ready: https://jellyfin.gate.test" "ready summary printed after install"
}

stage2_seed_remote_env() {
    local state="$1"
    local jf_password='Gate!$tack"with\special#chars^&*'

    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@gate.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD "$jf_password"
    env_set JELLYFIN_GPU none
    env_set DOMAIN gate.test
    env_set REMOTE_WEB_STATE "$state"
    env_set WG_HOST gate.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set NPM_LE_SERVER https://pebble:14000/dir
    env_set STAGE_1_COMPLETE 1
}

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin config/ddns-updater docker-compose.acme-test.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"

    stage2_seed_remote_env unchecked
    assert_eq "unchecked" "$(env_get REMOTE_WEB_STATE)" "TEST-02 fixture DNS/Pebble: ready scenario starts from REMOTE_WEB_STATE=unchecked"

    npm_acme_override
    if dind_exec "docker compose --profile proxy -f docker-compose.yml -f docker-compose.acme-test.yml up -d jellyfin seerr homepage npm fail2ban ddns-updater" >/dev/null 2>&1; then
        pass "TEST-02 fixture DNS/Pebble: proxy-profile services start with Pebble override"
    else
        fail "TEST-02 fixture DNS/Pebble: proxy-profile services start with Pebble override"
        dind_exec "docker compose ps"
        return 1
    fi

    local svc ok=true
    for svc in jellyfin seerr homepage npm fail2ban ddns-updater; do
        if wait_healthy "$svc" 360; then
            pass "stage2 ready: $svc healthy"
        else
            fail "stage2 ready: $svc healthy"
            ok=false
        fi
    done
    $ok || {
        dind_exec "docker compose ps"
        return 1
    }

    if pebble_up && pebble_setup_dns; then
        pass "stage2 ready: Pebble ACME server and fixture DNS ready"
    else
        fail "stage2 ready: Pebble ACME server and fixture DNS ready"
        return 1
    fi

    dind_exec "grep -q 'jellyfin.gate.test' /etc/hosts || printf '127.0.0.1 jellyfin.gate.test seerr.gate.test\n' >> /etc/hosts"

    # Stage 2 writes unchecked, makes one Pebble-backed
    # publication attempt, probes HTTPS, then promotes ready.
    stage2_run_install || return 1
    assert_remote_gating_ready /tmp/stage2-ready-install.out
    stage2_ready_assert_fixture_postconditions

    local install_log
    install_log="$(sed -r 's/\x1b\[[0-9;]*m//g' /tmp/stage2-ready-install.out 2>/dev/null || true)"
    assert_contains "$install_log" "Stage 2 remote attempt allowed" "TEST-02 fixture DNS/Pebble: NPM gets one process-scoped remote attempt"
    assert_contains "$install_log" "Cert POST for jellyfin.gate.test" "TEST-02 fixture DNS/Pebble: Jellyfin cert request attempted once through local NPM/Pebble"
}

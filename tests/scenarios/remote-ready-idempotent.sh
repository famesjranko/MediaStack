# tests/scenarios/remote-ready-idempotent.sh — TEST-05 ready remote recovery.
#
# Uses fixture DNS and Pebble ACME inside DinD. This does not prove public WAN,
# real DDNS propagation, or production Let's Encrypt issuance.

source tests/assertions/remote-gating.sh

remote_ready_idempotent_seed_env() {
    local jf_password='Gate!$tack"with\special#chars^&*'

    dind_exec "rm -f .env && cp .env.example .env"
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
    env_set REMOTE_WEB_STATE unchecked
    env_set WG_HOST gate.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"
    env_set NPM_LE_SERVER https://pebble:14000/dir
    env_set STAGE_1_COMPLETE 1
}

remote_ready_idempotent_prepare_public_route_user() {
    if ! dind_exec "id -u mstest >/dev/null 2>&1"; then
        dind_exec "apt-get -o Acquire::Retries=3 update >/dev/null && apt-get -o Acquire::Retries=3 install -y -qq sudo >/dev/null"
        dind_exec "useradd -m -s /bin/bash -G docker mstest"
        dind_exec "printf 'mstest ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-mediastack-mstest && chmod 440 /etc/sudoers.d/90-mediastack-mstest"
    fi

    dind_exec "chmod 755 /root && chown -R mstest:mstest /root/MediaStack /tmp/ms-data"
}

remote_ready_idempotent_start_proxy_fixture() {
    npm_acme_override
    dind_exec "cat >> docker-compose.acme-test.yml <<'EOF'
  flaresolverr:
    healthcheck:
      test: [\"CMD-SHELL\", \"exit 0\"]
      interval: 5s
      timeout: 2s
      retries: 1
      start_period: 1s
  jackett:
    depends_on:
      flaresolverr:
        condition: service_started
EOF"
    if dind_exec "docker compose --profile proxy -f docker-compose.yml -f docker-compose.acme-test.yml up -d jellyfin seerr homepage npm fail2ban ddns-updater" >/dev/null 2>&1; then
        pass "TEST-05 fixture DNS/Pebble: proxy-profile services start"
    else
        fail "TEST-05 fixture DNS/Pebble: proxy-profile services start"
        dind_exec "docker compose ps"
        return 1
    fi

    local svc ok=true
    for svc in jellyfin seerr homepage npm fail2ban ddns-updater; do
        if wait_healthy "$svc" 360; then
            pass "TEST-05 fixture DNS/Pebble: $svc healthy"
        else
            fail "TEST-05 fixture DNS/Pebble: $svc healthy"
            ok=false
        fi
    done
    $ok || {
        dind_exec "docker compose ps"
        return 1
    }

    if pebble_up && pebble_setup_dns; then
        pass "TEST-05 fixture DNS/Pebble: ACME server and fixture DNS ready"
    else
        fail "TEST-05 fixture DNS/Pebble: ACME server and fixture DNS ready"
        return 1
    fi

    dind_exec "grep -q 'jellyfin.gate.test' /etc/hosts || printf '127.0.0.1 jellyfin.gate.test seerr.gate.test\n' >> /etc/hosts"
}

remote_ready_idempotent_watch_fixture_state() {
    dind_exec "nohup sh -c '
for i in \$(seq 1 180); do
    chown -R mstest:mstest config/npm config/jellyfin config/homepage config/ddns-updater config/wireguard 2>/dev/null || true
    sleep 2
done
' >/tmp/remote-ready-idempotent-watch.log 2>&1 &"
}

remote_ready_idempotent_establish_ready() {
    local log_path="/tmp/remote-ready-idempotent-establish.out"
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
        pass "TEST-05: ready state established with fixture DNS/Pebble"
    else
        fail "TEST-05: ready state established with fixture DNS/Pebble"
        tail -100 "$log_path"
        return 1
    fi

    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "TEST-05: ready state exists before idempotency call"
    assert_remote_gating_ready "$log_path"
}

remote_ready_idempotent_assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "'$needle' found" ;;
        *) pass "$name" ;;
    esac
}

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "ids=\$(docker ps -aq); [ -z \"\$ids\" ] || docker rm -f \$ids >/dev/null 2>&1 || true"
    dind_exec "docker rm -f pebble pebble-challtestsrv 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin config/ddns-updater config/wireguard docker-compose.acme-test.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"

    remote_ready_idempotent_seed_env
    remote_ready_idempotent_start_proxy_fixture || return 1
    remote_ready_idempotent_establish_ready || return 1
    remote_ready_idempotent_prepare_public_route_user
    remote_ready_idempotent_watch_fixture_state

    local log_path="/tmp/remote-ready-idempotent.out"
    if dind_exec "su -s /bin/bash mstest -c 'cd /root/MediaStack && printf \"[scenario] running ./setup.sh --remote after ready fixture\n\" && COMPOSE_FILE=docker-compose.yml:docker-compose.acme-test.yml ./setup.sh --remote'" >"$log_path" 2>&1; then
        pass "TEST-05: ./setup.sh --remote exits 0 when already ready"
    else
        fail "TEST-05: ./setup.sh --remote exits 0 when already ready"
        tail -100 "$log_path"
        return 1
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"
    assert_contains "$log_plain" "./setup.sh --remote" "TEST-05: log proves public --remote route was used"
    remote_ready_idempotent_assert_not_contains "$log_plain" "MediaStack - Core Media Server" "TEST-05: ready recovery does not enter full Stage 1 wizard"
    remote_ready_idempotent_assert_not_contains "$log_plain" "Set up remote access now?" "TEST-05: ready recovery does not enter Stage 2 prompt flow"
    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "TEST-05: REMOTE_WEB_STATE remains ready after idempotent --remote"
    assert_remote_gating_ready "$log_path"
}

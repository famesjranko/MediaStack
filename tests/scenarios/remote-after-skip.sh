# tests/scenarios/remote-after-skip.sh — TEST-04 skipped remote recovery.
#
# Uses fixture DNS and Pebble ACME inside DinD. This does not prove public WAN,
# real DDNS propagation, or production Let's Encrypt issuance.

source tests/assertions/remote-gating.sh

remote_after_skip_seed_env() {
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
    env_set REMOTE_WEB_STATE skipped
    env_set WG_HOST gate.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"
    env_set NPM_LE_SERVER https://pebble:14000/dir
    env_set STAGE_1_COMPLETE 1
}

remote_after_skip_prepare_public_route_user() {
    if ! dind_exec "id -u mstest >/dev/null 2>&1"; then
        dind_exec "apt-get -o Acquire::Retries=3 update >/dev/null && apt-get -o Acquire::Retries=3 install -y -qq sudo >/dev/null"
        dind_exec "useradd -m -s /bin/bash -G docker mstest"
        dind_exec "printf 'mstest ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-mediastack-mstest && chmod 440 /etc/sudoers.d/90-mediastack-mstest"
    fi

    dind_exec "chmod 755 /root && chown -R mstest:mstest /root/MediaStack /tmp/ms-data"
}

remote_after_skip_write_fixture_dig() {
    dind_exec "mkdir -p tests/.scenario-bin && cat > tests/.scenario-bin/dig <<'EOF'
#!/usr/bin/env bash
for arg in \"\$@\"; do
    case \"\$arg\" in
        +*|A|AAAA|CNAME|@*)
            continue
            ;;
        jellyfin.gate.test|seerr.gate.test|gate.test)
            printf '203.0.113.42\n'
            exit 0
            ;;
    esac
done
exit 0
EOF
chmod +x tests/.scenario-bin/dig
cp tests/.scenario-bin/dig /usr/local/bin/dig
cp tests/.scenario-bin/dig /usr/bin/dig
chmod +x /usr/local/bin/dig /usr/bin/dig
chown -R mstest:mstest tests/.scenario-bin"
}

remote_after_skip_start_proxy_fixture() {
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
        pass "TEST-04 fixture DNS/Pebble: proxy-profile services start"
    else
        fail "TEST-04 fixture DNS/Pebble: proxy-profile services start"
        dind_exec "docker compose ps"
        return 1
    fi

    local svc ok=true
    for svc in jellyfin seerr homepage npm fail2ban ddns-updater; do
        if wait_healthy "$svc" 360; then
            pass "TEST-04 fixture DNS/Pebble: $svc healthy"
        else
            fail "TEST-04 fixture DNS/Pebble: $svc healthy"
            ok=false
        fi
    done
    $ok || {
        dind_exec "docker compose ps"
        return 1
    }

    if pebble_up && pebble_setup_dns; then
        pass "TEST-04 fixture DNS/Pebble: ACME server and fixture DNS ready"
    else
        fail "TEST-04 fixture DNS/Pebble: ACME server and fixture DNS ready"
        return 1
    fi

    dind_exec "grep -q 'jellyfin.gate.test' /etc/hosts || printf '127.0.0.1 jellyfin.gate.test seerr.gate.test\n' >> /etc/hosts"
}

remote_after_skip_watch_pebble_dns() {
    dind_exec "nohup sh -c '
last=
for i in \$(seq 1 180); do
    npm_ip=\$(docker inspect -f \"{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}\" npm 2>/dev/null || true)
    challtestsrv_ip=\$(docker inspect -f \"{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}\" pebble-challtestsrv 2>/dev/null || true)
    if [ -n \"\$npm_ip\" ] && [ -n \"\$challtestsrv_ip\" ] && [ \"\$npm_ip\" != \"\$last\" ]; then
        curl -sf -X POST \"http://\${challtestsrv_ip}:8055/set-default-ipv4\" -d \"{\\\"ip\\\":\\\"\${npm_ip}\\\"}\" >/dev/null 2>&1 || true
        curl -sf -X POST \"http://\${challtestsrv_ip}:8055/set-default-ipv6\" -d \"{\\\"ip\\\":\\\"\\\"}\" >/dev/null 2>&1 || true
        last=\"\$npm_ip\"
    fi
    chown -R mstest:mstest config/npm config/jellyfin config/homepage config/ddns-updater config/wireguard 2>/dev/null || true
    sleep 2
done
' >/tmp/remote-after-skip-pebble-watch.log 2>&1 &"
}

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "ids=\$(docker ps -aq); [ -z \"\$ids\" ] || docker rm -f \$ids >/dev/null 2>&1 || true"
    dind_exec "docker rm -f pebble pebble-challtestsrv 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin config/ddns-updater config/wireguard docker-compose.acme-test.yml tests/.scenario-bin"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"

    remote_after_skip_seed_env
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "TEST-04: scenario starts from REMOTE_WEB_STATE=skipped"
    remote_after_skip_prepare_public_route_user
    remote_after_skip_write_fixture_dig
    remote_after_skip_start_proxy_fixture || return 1
    dind_exec "chown -R mstest:mstest config/npm config/jellyfin config/homepage config/ddns-updater config/wireguard docker-compose.acme-test.yml"
    remote_after_skip_watch_pebble_dns

    local log_path="/tmp/remote-after-skip.out"
    if dind_exec "su -s /bin/bash mstest -c 'cd /root/MediaStack && printf \"[scenario] running ./setup.sh --remote with fixture DNS/Pebble\n\" && PATH=/root/MediaStack/tests/.scenario-bin:\$PATH UI_DEMO=1 COMPOSE_FILE=docker-compose.yml:docker-compose.acme-test.yml ./setup.sh --remote'" >"$log_path" 2>&1; then
        pass "TEST-04: ./setup.sh --remote exits 0 after skipped state"
    else
        fail "TEST-04: ./setup.sh --remote exits 0 after skipped state"
        tail -100 "$log_path"
        return 1
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"
    assert_contains "$log_plain" "./setup.sh --remote" "TEST-04: log proves public --remote route was used"
    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "TEST-04: REMOTE_WEB_STATE=ready after --remote recovery"
    assert_remote_gating_ready "$log_path"
}

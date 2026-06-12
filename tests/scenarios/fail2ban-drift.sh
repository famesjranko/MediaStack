# tests/scenarios/fail2ban-drift.sh — focused fail2ban regex drift checks.

source tests/assertions/fail2ban.sh

run_scenario() {
    if svc_stripped fail2ban; then
        skip "fail2ban drift: scenario" "stripped via MS_TEST_STRIP_SERVICES"
        return 0
    fi

    dind_exec "docker compose --profile proxy --profile remote --profile subtitles --profile autoheal down -v --remove-orphans 2>/dev/null || true"
    create_config_dirs_in_dind
    dind_exec "rm -rf config/npm/data/logs && mkdir -p config/ddns-updater config/npm/data/logs config/jellyfin/log config/seerr/logs"
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set DOMAIN drift.test
    env_set WG_INIT_PASSWORD "''"

    dind_exec "cat > config/jellyfin/log/fail2ban-drift.log <<'EOF'
[2026-05-02 01:02:03.456 +00:00] [INF] Authentication request for \"admin\" has been denied (IP: \"203.0.113.10\").
EOF
cat > config/seerr/logs/fail2ban-drift.log <<'EOF'
2026-05-02T01:02:04.000Z [warn][API]: Failed sign-in attempt using invalid Seerr password {\"ip\":\"203.0.113.11\",\"email\":\"admin@example.com\"}
2026-05-02T01:02:05.000Z [warn][Auth]: Failed sign-in attempt from user with incorrect Jellyfin credentials {\"account\":{\"ip\":\"203.0.113.12\",\"email\":\"admin@example.com\",\"password\":\"__REDACTED__\"}}
2026-05-02T01:02:06.000Z [warn][API]: Failed password reset attempt using invalid recovery link {\"ip\":\"203.0.113.13\",\"guid\":\"bogus\"}
EOF
cat > config/npm/data/logs/proxy-host-1_fail2ban-drift.log <<'EOF'
[02/May/2026:01:02:06 +0000] - 401 401 - GET https jellyfin.drift.test \"/Users\" [Client 203.0.113.13] [Length 0] [Gzip -] [Sent-to 172.19.0.10] \"-\" \"curl/8.0\"
[02/May/2026:01:02:07 +0000] - - 429 - GET https jellyfin.drift.test \"/health\" [Client 203.0.113.14] [Length 0] [Gzip -] [Sent-to 172.19.0.10] \"-\" \"curl/8.0\"
EOF"

    if dind_exec "docker compose --profile proxy up -d --no-deps fail2ban" >/dev/null 2>&1; then
        pass "fail2ban drift: fail2ban starts"
    else
        fail "fail2ban drift: fail2ban starts"
        dind_exec "docker compose ps"
        dind_exec "docker compose --profile proxy logs --tail 80 npm fail2ban 2>/dev/null || true"
        return 1
    fi

    if wait_healthy fail2ban 120; then
        pass "fail2ban drift: fail2ban healthy"
    else
        fail "fail2ban drift: fail2ban healthy"
        dind_exec "docker logs --tail 80 fail2ban"
        return 1
    fi

    assert_fail2ban_filter_matches jellyfin /var/log/jellyfin/fail2ban-drift.log /data/filter.d/jellyfin.conf
    # Seerr fixture carries all three real failure shapes (local-password API, Jellyfin-credential
    # Auth with the IP nested under "account", and password-reset API). Assert the filter catches
    # every one — a regex that misses any auth type (the pre-widen filter missed password-reset)
    # fails here instead of silently undercounting.
    assert_fail2ban_filter_matches seerr /var/log/seerr/fail2ban-drift.log /data/filter.d/seerr.conf 3
    assert_fail2ban_filter_matches npm /var/log/npm/proxy-host-1_fail2ban-drift.log /data/filter.d/npm.conf
    assert_fail2ban_filter_matches npm-ratelimit /var/log/npm/proxy-host-1_fail2ban-drift.log /data/filter.d/npm-ratelimit.conf
}

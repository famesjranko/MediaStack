# tests/scenarios/remote-gating.sh — remote state publication gates.
#
# This scenario intentionally starts proxy-profile services while
# REMOTE_WEB_STATE is not ready. DOMAIN remains the infrastructure/profile
# switch; REMOTE_WEB_STATE controls HTTPS publication.

source tests/assertions/remote_gating.sh

run_remote_gating_configure() {
    local state="$1"
    local log_path="/tmp/remote-gating-${state}.out"
    if dind_exec "./scripts/configure.sh --only jellyfin,homepage,npm" >"$log_path" 2>&1; then
        pass "remote gating: configure.sh --only jellyfin,homepage,npm exits 0 (${state})"
    else
        fail "remote gating: configure.sh --only jellyfin,homepage,npm exits 0 (${state})"
        tail -40 "$log_path"
        return 1
    fi

    # Access-banner copy is produced by setup.sh::print_access_info, not by
    # configure.sh --only service reconfiguration. The fast unit contract covers
    # those strings; this DinD scenario verifies service publication state.
}

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: isolated state, proxy-profile domain, unchecked by default.
    # ------------------------------------------------------------------
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind

    local jf_password='Gate!$tack"with\special#chars^&*'
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

    # ------------------------------------------------------------------
    # 1. Start proxy-profile services before ready.
    # ------------------------------------------------------------------
    if dind_exec "docker compose --profile proxy up -d jellyfin seerr homepage npm fail2ban ddns-updater" >/dev/null 2>&1; then
        pass "remote gating: docker compose --profile proxy starts non-ready services"
    else
        fail "remote gating: docker compose --profile proxy starts non-ready services"
        dind_exec "docker compose ps"
        return 1
    fi

    local svc ok=true
    for svc in jellyfin seerr homepage npm fail2ban ddns-updater; do
        if wait_healthy "$svc" 360; then
            pass "remote gating: $svc healthy"
        else
            fail "remote gating: $svc healthy"
            ok=false
        fi
    done
    $ok || { dind_exec "docker compose ps"; return 1; }

    # ------------------------------------------------------------------
    # 2. Unchecked: infra runs, but no HTTPS publication.
    # ------------------------------------------------------------------
    env_set REMOTE_WEB_STATE unchecked
    run_remote_gating_configure unchecked || return 1
    assert_remote_gating_unchecked /tmp/remote-gating-unchecked.out

    # ------------------------------------------------------------------
    # 3. Skipped: same LAN-only publication behavior with explicit copy.
    # ------------------------------------------------------------------
    env_set REMOTE_WEB_STATE skipped
    run_remote_gating_configure skipped || return 1
    assert_remote_gating_skipped /tmp/remote-gating-skipped.out

    # ------------------------------------------------------------------
    # 4. Ready: preserve Pebble/NPM_LE_SERVER cert path coverage.
    # Production Let's Encrypt is never used in this contract scenario.
    # ------------------------------------------------------------------
    env_set REMOTE_WEB_STATE ready
    npm_acme_override
    if dind_exec "docker compose --profile proxy -f docker-compose.yml -f docker-compose.acme-test.yml up -d npm" >/dev/null 2>&1; then
        pass "remote gating: NPM restarted with Pebble ACME override"
    else
        fail "remote gating: NPM restarted with Pebble ACME override"
        return 1
    fi
    if ! wait_healthy npm 180; then
        fail "remote gating: npm healthy after Pebble override"
        return 1
    fi
    if pebble_up && pebble_setup_dns; then
        pass "remote gating: Pebble ACME server ready"
    else
        fail "remote gating: Pebble ACME server ready"
        return 1
    fi

    run_remote_gating_configure ready || return 1
    assert_remote_gating_ready /tmp/remote-gating-ready.out
}

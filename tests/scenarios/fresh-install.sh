# tests/scenarios/fresh-install.sh — full default-profile stack inside DinD.
# Brings up the default-profile services, runs configure.sh, and asserts
# per-step evidence (config files, API state, .env back-population).
#
# Wall-time budget: ~25 min cold (~5 GB image pulls), ~15-18 min warm.
# Does not use --profile remote — wireguard is exercised by smoke.sh instead.

source tests/assertions/qbittorrent.sh
source tests/assertions/jackett.sh
source tests/assertions/sonarr.sh
source tests/assertions/radarr.sh
source tests/assertions/jellyfin.sh
source tests/assertions/seerr.sh
source tests/assertions/portainer.sh
source tests/assertions/homepage.sh
source tests/assertions/npm.sh
source tests/assertions/fail2ban.sh
source tests/assertions/ratelimit.sh
source tests/assertions/env.sh
source tests/assertions/jellyfin_encoding.sh
source tests/assertions/port_check.sh
source tests/assertions/uptime_kuma.sh
source tests/assertions/drift.sh
source tests/assertions/beszel.sh
source tests/assertions/install_digest.sh

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: data dirs, config dirs, .env
    # ------------------------------------------------------------------
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind

    dind_exec "cp .env.example .env"

    local jf_password='Fr3sh!$tack"with\special#chars^&*'

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@fresh.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD "$jf_password"
    env_set JELLYFIN_GPU none
    env_set DOMAIN fresh.test
    env_set REMOTE_WEB_STATE ready
    env_set WG_HOST fresh.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"

    local env_jf_pw
    env_jf_pw=$(env_get JELLYFIN_ADMIN_PASSWORD)
    assert_eq "$jf_password" "$env_jf_pw" ".env JELLYFIN_ADMIN_PASSWORD round-trip preserves special chars"

    # ------------------------------------------------------------------
    # 0b. Generate resource-limit override inside DinD.
    # ------------------------------------------------------------------
    dind_exec "bash -c 'source setup.sh && detect_host_memory && generate_override none'"

    # Strip services from the override too — generate_override includes all
    # services unconditionally, but dind_strip_services only edits the base
    # compose file. Without this, stripped services fail validation ("has
    # neither an image nor a build context").
    if [[ -n "${MS_TEST_STRIP_SERVICES:-}" ]]; then
        docker exec -i -w /root/MediaStack "$DIND_NAME" python3 - "$(echo "${MS_TEST_STRIP_SERVICES}" | tr ',' ' ')" <<'PYEOF'
import sys, yaml
strip = set(sys.argv[1].split())
with open('docker-compose.override.yml') as f:
    c = yaml.safe_load(f) or {}
svcs = c.get('services') or {}
for s in list(strip & set(svcs)):
    del svcs[s]
with open('docker-compose.override.yml', 'w') as f:
    yaml.safe_dump(c, f, sort_keys=False)
PYEOF
    fi

    # ------------------------------------------------------------------
    # 1. Bring up the default profile (with Pebble ACME override for NPM).
    # ------------------------------------------------------------------
    local _strip; _strip=" $(echo "${MS_TEST_STRIP_SERVICES:-}" | tr ',' ' ') "
    local compose_cmd="docker compose --profile proxy --profile autoheal up -d"
    if [[ "$_strip" != *" npm "* ]]; then
        npm_acme_override
        compose_cmd="docker compose --profile proxy --profile autoheal -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.acme-test.yml up -d"
    fi
    echo "  starting stack (cold pull can take 5-10 min)…"
    local up_rc
    dind_exec "$compose_cmd" >/dev/null 2>&1
    up_rc=$?
    if (( up_rc != 0 )); then
        fail "docker compose up -d" "exit $up_rc"
        dind_exec "docker compose ps"
        return 1
    fi
    pass "docker compose up -d (default + proxy profiles)"

    # ------------------------------------------------------------------
    # 2. Wait for each service healthy (or running for no-healthcheck ones).
    # ------------------------------------------------------------------
    local svc ok=true
    for svc in flaresolverr jackett qbittorrent jellyfin npm sonarr radarr seerr unpackerr homepage fail2ban uptime-kuma beszel ddns-updater; do
        if svc_stripped "$svc"; then
            skip "$svc healthy" "stripped via MS_TEST_STRIP_SERVICES"
            continue
        fi
        if wait_healthy "$svc" 360; then
            pass "$svc healthy"
        else
            fail "$svc healthy"
            ok=false
        fi
    done
    for svc in portainer autoheal; do
        if svc_stripped "$svc"; then
            skip "$svc running" "stripped via MS_TEST_STRIP_SERVICES"
            continue
        fi
        local status
        status=$(dind_exec "docker inspect --format '{{.State.Status}}' $svc 2>/dev/null" | tr -d '\r\n')
        if [[ "$status" == "running" ]]; then
            pass "$svc running"
        else
            fail "$svc running" "status=$status"
            ok=false
        fi
    done

    $ok || { dind_exec "docker compose ps"; return 1; }

    # ------------------------------------------------------------------
    # 2b. Verify resource limits are applied to running containers.
    # ------------------------------------------------------------------
    for svc in jellyfin sonarr radarr jackett qbittorrent flaresolverr seerr npm unpackerr homepage portainer fail2ban uptime-kuma beszel beszel-agent autoheal; do
        if svc_stripped "$svc"; then
            skip "$svc has memory limit" "stripped via MS_TEST_STRIP_SERVICES"
            continue
        fi
        local mem
        mem=$(dind_exec "docker inspect --format '{{.HostConfig.Memory}}' $svc 2>/dev/null" | tr -d '\r\n')
        if [[ -n "$mem" && "$mem" != "0" ]]; then
            pass "$svc has memory limit"
        else
            fail "$svc has memory limit" "got '$mem' (0 = unlimited)"
        fi
    done

    # ------------------------------------------------------------------
    # 2b. Start Pebble ACME test server.
    # ------------------------------------------------------------------
    if ! svc_stripped npm; then
        if pebble_up && pebble_setup_dns; then
            pass "Pebble ACME server ready"
        else
            fail "Pebble ACME server ready"
        fi
    fi

    # ------------------------------------------------------------------
    # 3. Run configure.sh. Must exit 0.
    # ------------------------------------------------------------------
    local configure_log=/tmp/configure.out
    # UI_ASCII=1 forces ASCII log markers ([OK]/[SKIP]/[WARN]) so the marker-grep
    # assertions (uptime-kuma, beszel, jellyfin encoding, drift) are deterministic
    # regardless of the DinD locale — without it the glyph markers (✓/→/!) added in
    # the terminal-capability work make those greps silently miss. See
    # scripts/lib/term_caps.sh (UI_ASCII).
    if dind_exec "UI_ASCII=1 ./scripts/configure.sh" >"$configure_log" 2>&1; then
        pass "configure.sh exits 0"
    else
        fail "configure.sh exits 0"
        tail -40 "$configure_log"
        return 1
    fi

    echo "  (configure.sh summary)"
    sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" \
        | grep -E '^\[(OK|SKIP|WARN|ERROR)\]' \
        | sed 's/^/    /' \
        | tail -40

    # ------------------------------------------------------------------
    # 4. Per-step evidence assertions
    # ------------------------------------------------------------------
    SONARR_KEY=""
    RADARR_KEY=""
    JF_TOKEN=""
    JF_AUTH_HEADER=""
    NPM_TOKEN=""
    F2B_STATUS=""

    assert_qbittorrent_configured
    assert_jackett_configured
    assert_sonarr_configured "$configure_log"
    assert_radarr_configured "$configure_log"
    assert_jellyfin_configured "$jf_password"
    assert_seerr_configured "$jf_password"
    assert_portainer_configured "$jf_password"
    assert_homepage_configured
    assert_uptime_kuma_configured "$configure_log"
    assert_beszel_configured "$configure_log"
    assert_npm_configured "$jf_password"
    assert_fail2ban_configured
    assert_fail2ban_rotation
    assert_ratelimit_disabled
    assert_env_backpopulation
    assert_jellyfin_encoding
    assert_port_check
    assert_drift_regression
    assert_uptime_kuma_idempotent
    assert_install_digest_recorded
}

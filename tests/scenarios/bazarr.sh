# tests/scenarios/bazarr.sh - focused Bazarr image-drift oracle.
#
# Starts Bazarr's subtitles profile with its dependency chain, runs only the
# Bazarr configurator, then verifies the generated API settings and language
# profile. This keeps the preflight scoped to Bazarr rather than duplicating
# fresh-install.

source tests/assertions/bazarr.sh

bazarr_wait_path() {
    local path="$1" label="$2" timeout="${3:-120}" waited=0
    while (( waited < timeout )); do
        if dind_exec "test -e $path"; then
            pass "$label"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    fail "$label" "$path missing after ${timeout}s"
    return 1
}

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: data dirs, config dirs, .env
    # ------------------------------------------------------------------
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind
    dind_exec "cp .env.example .env"

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set JELLYFIN_GPU none
    env_set BAZARR_ENABLED true

    # Keep resource-limit coverage and compose shape aligned with normal setup.
    dind_exec "bash -c 'source setup.sh && detect_host_memory && generate_override none'"

    # ------------------------------------------------------------------
    # 1. Bring up Bazarr and its dependency chain only.
    # ------------------------------------------------------------------
    local up_log=/tmp/bazarr-compose-up.out
    echo "  starting Bazarr subtitles profile (cold pull can take several minutes)..."
    if dind_exec "docker compose --profile subtitles up -d bazarr" >"$up_log" 2>&1; then
        pass "bazarr: compose up subtitles profile target"
    else
        fail "bazarr: compose up subtitles profile target"
        tail -80 "$up_log"
        return 1
    fi

    local svc ok=true
    for svc in flaresolverr jackett qbittorrent sonarr radarr bazarr; do
        if wait_healthy "$svc" 360; then
            pass "bazarr: $svc healthy"
        else
            fail "bazarr: $svc healthy"
            ok=false
        fi
    done
    $ok || { dind_exec "docker compose ps"; return 1; }

    bazarr_wait_path "config/bazarr/config/config.yaml" "bazarr: config.yaml generated" 120 || return 1
    bazarr_wait_path "config/bazarr/db/bazarr.db" "bazarr: database generated" 120 || return 1

    # ------------------------------------------------------------------
    # 2. Run only the Bazarr configurator.
    # ------------------------------------------------------------------
    local configure_log=/tmp/bazarr-configure.out
    if dind_exec "UI_ASCII=1 ./scripts/configure.sh --only bazarr" >"$configure_log" 2>&1; then
        pass "bazarr: configure.sh --only bazarr exits 0"
    else
        fail "bazarr: configure.sh --only bazarr exits 0"
        tail -80 "$configure_log"
        return 1
    fi

    echo "  (Bazarr configure.sh summary)"
    sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" \
        | grep -E '^\[(OK|SKIP|WARN|ERROR)\]' \
        | sed 's/^/    /' \
        | tail -30

    wait_healthy bazarr 180 \
        && pass "bazarr: healthy after configurator restart" \
        || fail "bazarr: healthy after configurator restart"

    assert_bazarr_configured "$configure_log"
}

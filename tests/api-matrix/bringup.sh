# tests/api-matrix/bringup.sh — shared live bring-up for the API-bearing
# services (sonarr, radarr, qbittorrent, jackett, jellyfin, seerr).
#
# Owns: compose pull/up + health wait + Sonarr/Radarr API key extraction,
# used by BOTH tests/scenarios/api-matrix.sh (behavioral matrix) and
# tests/scenarios/contract-drift.sh (live drift replay) — one bring-up, not
# duplicated, per TARGET.md's "existing tests/api-matrix/ live layer is
# reused, never duplicated."
#
# Sets (after a successful call): API_MATRIX_SONARR_KEY, API_MATRIX_RADARR_KEY
# (empty string if that key could not be read). Returns non-zero only on a
# hard bring-up failure (pull/up); a missing key is reported by the caller.

api_matrix_bring_up() {
    local api_svcs="${1:-sonarr radarr qbittorrent jackett jellyfin seerr}"

    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/media/music /tmp/ms-data/torrents && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind
    dind_exec "cp .env.example .env"

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set JELLYFIN_ADMIN_USER matrix-admin
    env_set JELLYFIN_ADMIN_PASSWORD ApiMatrixQbtPassword123
    env_set JELLYFIN_GPU none
    env_set BAZARR_ENABLED false
    env_set QBT_DL_LIMIT "''"
    env_set QBT_UL_LIMIT "''"

    # `up`'s implicit pull has no retry — a transient registry EOF fails all
    # services, burning multiple 360s health waits. Pull first with retry;
    # fail-fast.
    local pull_ok=0 attempt
    for attempt in 1 2 3; do
        dind_exec "docker compose pull --policy missing $api_svcs" && {
            pull_ok=1
            break
        }
        ((attempt < 3)) && sleep $((attempt * 5))
    done
    if ((!pull_ok)); then
        fail "api-matrix: compose pull $api_svcs" "registry unreachable after 3 attempts"
        return 1
    fi

    if dind_exec "docker compose up -d $api_svcs"; then
        pass "api-matrix: compose up $api_svcs"
    else
        fail "api-matrix: compose up $api_svcs"
        return 1
    fi

    local svc
    for svc in $api_svcs; do
        wait_healthy "$svc" 360 \
            && pass "api-matrix: $svc healthy" \
            || fail "api-matrix: $svc healthy"
    done

    API_MATRIX_SONARR_KEY=$(get_api_key_from_xml "config/sonarr/config.xml")
    API_MATRIX_RADARR_KEY=$(get_api_key_from_xml "config/radarr/config.xml")
    [[ -n "$API_MATRIX_SONARR_KEY" ]] && pass "api-matrix: Sonarr API key" || fail "api-matrix: Sonarr API key"
    [[ -n "$API_MATRIX_RADARR_KEY" ]] && pass "api-matrix: Radarr API key" || fail "api-matrix: Radarr API key"
}

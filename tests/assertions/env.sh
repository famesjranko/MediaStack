assert_env_backpopulation() {
    local env_sonarr env_radarr env_jf
    env_sonarr=$(env_get SONARR_API_KEY)
    env_radarr=$(env_get RADARR_API_KEY)
    env_jf=$(env_get JELLYFIN_API_KEY)
    [[ -n "$env_sonarr" && ${#env_sonarr} -ge 20 ]] && pass ".env SONARR_API_KEY populated" || fail ".env SONARR_API_KEY populated"
    [[ -n "$env_radarr" && ${#env_radarr} -ge 20 ]] && pass ".env RADARR_API_KEY populated" || fail ".env RADARR_API_KEY populated"
    [[ -n "$env_jf" && ${#env_jf} -ge 20 ]] && pass ".env JELLYFIN_API_KEY populated" || fail ".env JELLYFIN_API_KEY populated"

    local env_seerr
    env_seerr=$(env_get SEERR_API_KEY)
    [[ -n "$env_seerr" && ${#env_seerr} -ge 20 ]] && pass ".env SEERR_API_KEY populated" || fail ".env SEERR_API_KEY populated"

    local env_portainer
    env_portainer=$(env_get PORTAINER_API_KEY)
    [[ -n "$env_portainer" && ${#env_portainer} -ge 20 ]] && pass ".env PORTAINER_API_KEY populated" || fail ".env PORTAINER_API_KEY populated"

    local env_beszel_key
    env_beszel_key=$(env_get BESZEL_AGENT_KEY)
    [[ -n "$env_beszel_key" && ${#env_beszel_key} -ge 20 ]] && pass ".env BESZEL_AGENT_KEY populated" || fail ".env BESZEL_AGENT_KEY populated"

    local env_remote_web_state
    env_remote_web_state=$(env_get REMOTE_WEB_STATE)
    assert_eq "ready" "$env_remote_web_state" ".env REMOTE_WEB_STATE populated for ready-state HTTPS"

    local env_jf_pub
    env_jf_pub=$(env_get JELLYFIN_PUBLISHED_URL)
    assert_eq "https://jellyfin.fresh.test" "$env_jf_pub" ".env JELLYFIN_PUBLISHED_URL populated for ready-state HTTPS"

    # Bazarr — only asserted if the subtitles profile is active
    if dind_exec "docker compose ps --format '{{.Names}}' 2>/dev/null" | tr -d '\r' | grep -qx bazarr; then
        local env_bazarr
        env_bazarr=$(env_get BAZARR_API_KEY)
        [[ -n "$env_bazarr" && ${#env_bazarr} -ge 20 ]] && pass ".env BAZARR_API_KEY populated" || fail ".env BAZARR_API_KEY populated"

        local bazarr_sonarr_key
        bazarr_sonarr_key=$(dind_exec "curl -sf -H 'X-API-KEY: $env_bazarr' http://localhost:6767/api/system/settings" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('sonarr',{}).get('apikey',''))" 2>/dev/null | tr -d '\r\n')
        [[ -n "$bazarr_sonarr_key" && "$bazarr_sonarr_key" != "None" ]] \
            && pass "Bazarr: Sonarr connected" || fail "Bazarr: Sonarr connected"

        local bazarr_radarr_key
        bazarr_radarr_key=$(dind_exec "curl -sf -H 'X-API-KEY: $env_bazarr' http://localhost:6767/api/system/settings" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('radarr',{}).get('apikey',''))" 2>/dev/null | tr -d '\r\n')
        [[ -n "$bazarr_radarr_key" && "$bazarr_radarr_key" != "None" ]] \
            && pass "Bazarr: Radarr connected" || fail "Bazarr: Radarr connected"

        local bazarr_profile_count
        bazarr_profile_count=$(dind_exec "python3 -c \"
import sqlite3
conn = sqlite3.connect('config/bazarr/db/bazarr.db')
print(conn.execute('SELECT COUNT(*) FROM table_languages_profiles').fetchone()[0])
conn.close()
\"" | tr -d '\r\n')
        [[ "$bazarr_profile_count" -ge 1 ]] \
            && pass "Bazarr: language profile created" || fail "Bazarr: language profile created"
    fi
}

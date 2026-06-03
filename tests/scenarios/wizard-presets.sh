# tests/scenarios/wizard-presets.sh — verify wizard presets flow through
# configure.sh into Sonarr/Radarr quality profiles, and that the opt-in
# public-indexer preset seeds into Jackett.
#
# Applies the "compact" preset (non-default) to config.yml with the public
# indexer preset enabled (--public-indexers true) before bringing up the
# stack, then checks that Sonarr and Radarr have the expected profile name,
# enabled qualities, and cutoff, and that Jackett seeded the indexers. This
# is the dedicated preset-on test: default scenarios ship indexers: [] and
# skip the Jackett indexer caps assertion.
#
# Recommended strip list for speed (~5 min vs ~15 min):
#   MS_TEST_STRIP_SERVICES=npm,fail2ban,homepage,portainer,jellyseerr,jellyfin,unpackerr
# Note: don't strip bazarr (profile-gated, won't start) or flaresolverr
# (Jackett depends on it). The override references all services so stripping
# one that's in the override causes a "no image" compose error.
#
# Wall-time budget: ~5 min warm, ~10 min cold.

source tests/assertions/jackett.sh

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: data dirs, config dirs, .env (same as fresh-install)
    # ------------------------------------------------------------------
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind

    dind_exec "cp .env.example .env"

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@wizard.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD wizard-test-pw
    env_set JELLYFIN_GPU none
    env_set DOMAIN wizard.test
    env_set WG_HOST wizard.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"
    env_set BAZARR_ENABLED false

    # ------------------------------------------------------------------
    # 1. Apply "compact" preset to config.yml via wizard_apply.py
    # ------------------------------------------------------------------
    dind_exec "python3 scripts/setup/wizard_apply.py --preset compact --languages english,spanish --public-indexers true --config config.yml"

    local applied_name
    applied_name=$(dind_exec "python3 -c \"import yaml; print(yaml.safe_load(open('config.yml'))['quality_profile']['name'])\"")
    assert_eq "WEB-720p/1080p" "$applied_name" "wizard: config.yml profile name set to compact"

    local applied_cutoff
    applied_cutoff=$(dind_exec "python3 -c \"import yaml; print(yaml.safe_load(open('config.yml'))['quality_profile']['cutoff_id'])\"")
    assert_eq "1001" "$applied_cutoff" "wizard: config.yml cutoff set to 1001"

    local applied_langs
    applied_langs=$(dind_exec "python3 -c \"import yaml; print(','.join(yaml.safe_load(open('config.yml'))['bazarr']['languages']))\"")
    assert_eq "english,spanish" "$applied_langs" "wizard: config.yml bazarr languages set"

    # ------------------------------------------------------------------
    # 2. Generate resource override + bring up stack
    # ------------------------------------------------------------------
    dind_exec "bash -c 'source setup.sh && detect_host_memory && generate_override none'"

    # Strip removed services from the override too — generate_override writes
    # limits for all 19 services but stripped ones have no image definition.
    local _strip=" $(echo "${MS_TEST_STRIP_SERVICES:-}" | tr ',' ' ') "
    if [[ "$_strip" != "  " ]]; then
        dind_exec "python3 -c \"
import yaml
with open('docker-compose.override.yml') as f:
    c = yaml.safe_load(f) or {}
strip = set('${MS_TEST_STRIP_SERVICES:-}'.replace(',', ' ').split())
for s in list((c.get('services') or {}).keys()):
    if s in strip:
        del c['services'][s]
with open('docker-compose.override.yml', 'w') as f:
    yaml.safe_dump(c, f, sort_keys=False)
\""
    fi

    local compose_cmd="docker compose up -d"
    dind_exec "$compose_cmd"
    [[ $? -eq 0 ]] && pass "wizard: compose up" || fail "wizard: compose up"

    # Wait for Sonarr, Radarr, qBittorrent, Jackett
    for svc in sonarr radarr qbittorrent jackett; do
        wait_healthy "$svc" 360 \
            && pass "wizard: $svc healthy" \
            || fail "wizard: $svc healthy"
    done

    # ------------------------------------------------------------------
    # 3. Run configure.sh
    # ------------------------------------------------------------------
    local configure_log="/tmp/wizard-configure.log"
    dind_exec "./scripts/configure.sh" | tee "$configure_log"
    [[ ${PIPESTATUS[0]} -eq 0 ]] \
        && pass "wizard: configure.sh exits 0" \
        || fail "wizard: configure.sh exits 0"

    # ------------------------------------------------------------------
    # 3b. Verify the opt-in indexer preset seeded into Jackett
    # ------------------------------------------------------------------
    assert_jackett_configured

    # ------------------------------------------------------------------
    # 4. Verify Sonarr quality profile
    # ------------------------------------------------------------------
    local sonarr_key
    sonarr_key=$(get_api_key_from_xml "config/sonarr/config.xml")
    [[ -n "$sonarr_key" ]] && pass "wizard: Sonarr API key" || fail "wizard: Sonarr API key"

    local sonarr_base="http://localhost:8989/api/v3"

    # 4a. Profile name
    local sonarr_qp_id
    sonarr_qp_id=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualityprofile" \
        | python3 -c "
import sys, json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='WEB-720p/1080p'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$sonarr_qp_id" ]]; then
        pass "wizard: Sonarr WEB-720p/1080p profile created"
    else
        fail "wizard: Sonarr WEB-720p/1080p profile created" "not found in profile list"
    fi

    # 4b. Enabled qualities — only WEB 720p (IDs 5, 14)
    if [[ -n "$sonarr_qp_id" ]]; then
        local sonarr_enabled
        sonarr_enabled=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualityprofile/$sonarr_qp_id" \
            | python3 -c "
import sys, json
p = json.load(sys.stdin)
ids = set()
for item in p.get('items', []):
    if item.get('allowed') and item.get('quality'):
        ids.add(item['quality']['id'])
    for sub in item.get('items', []):
        if sub.get('allowed') and sub.get('quality'):
            ids.add(sub['quality']['id'])
print(','.join(str(i) for i in sorted(ids)))" 2>/dev/null)
        assert_eq "5,14" "$sonarr_enabled" "wizard: Sonarr compact qualities (WEB 720p only)"

        # 4c. Cutoff
        local sonarr_cutoff
        sonarr_cutoff=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualityprofile/$sonarr_qp_id" \
            | python3 -c "import sys, json; print(json.load(sys.stdin).get('cutoff',''))" 2>/dev/null)
        assert_eq "1001" "$sonarr_cutoff" "wizard: Sonarr compact cutoff 1001"
    fi

    # 4d. Quality definitions — WEBDL-720p preferred should be 20.0 (compact, sonarr)
    local sonarr_qd_pref
    sonarr_qd_pref=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualitydefinition" \
        | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        if d.get('quality', {}).get('name') == 'WEBDL-720p':
            print(format(float(d.get('preferredSize', 0)), '.1f')); break
except Exception: pass" 2>/dev/null)
    assert_eq "20.0" "$sonarr_qd_pref" "wizard: Sonarr WEBDL-720p preferred=20.0 (compact)"

    # ------------------------------------------------------------------
    # 5. Verify Radarr quality profile
    # ------------------------------------------------------------------
    local radarr_key
    radarr_key=$(get_api_key_from_xml "config/radarr/config.xml")
    [[ -n "$radarr_key" ]] && pass "wizard: Radarr API key" || fail "wizard: Radarr API key"

    local radarr_base="http://localhost:7878/api/v3"

    local radarr_qp_id
    radarr_qp_id=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualityprofile" \
        | python3 -c "
import sys, json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='WEB-720p/1080p'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$radarr_qp_id" ]]; then
        pass "wizard: Radarr WEB-720p/1080p profile created"
    else
        fail "wizard: Radarr WEB-720p/1080p profile created" "not found in profile list"
    fi

    if [[ -n "$radarr_qp_id" ]]; then
        # 5b. Radarr compact should also have only WEB qualities (no Remux)
        local radarr_enabled
        radarr_enabled=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualityprofile/$radarr_qp_id" \
            | python3 -c "
import sys, json
p = json.load(sys.stdin)
ids = set()
for item in p.get('items', []):
    if item.get('allowed') and item.get('quality'):
        ids.add(item['quality']['id'])
    for sub in item.get('items', []):
        if sub.get('allowed') and sub.get('quality'):
            ids.add(sub['quality']['id'])
print(','.join(str(i) for i in sorted(ids)))" 2>/dev/null)
        assert_eq "5,14" "$radarr_enabled" "wizard: Radarr compact qualities (WEB 720p only)"

        local radarr_cutoff
        radarr_cutoff=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualityprofile/$radarr_qp_id" \
            | python3 -c "import sys, json; print(json.load(sys.stdin).get('cutoff',''))" 2>/dev/null)
        assert_eq "1001" "$radarr_cutoff" "wizard: Radarr compact cutoff 1001"
    fi

    # 5d. Radarr quality definitions — WEBDL-720p preferred should be 22.0 (compact, radarr)
    local radarr_qd_pref
    radarr_qd_pref=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualitydefinition" \
        | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        if d.get('quality', {}).get('name') == 'WEBDL-720p':
            print(format(float(d.get('preferredSize', 0)), '.1f')); break
except Exception: pass" 2>/dev/null)
    assert_eq "22.0" "$radarr_qd_pref" "wizard: Radarr WEBDL-720p preferred=22.0 (compact)"
}

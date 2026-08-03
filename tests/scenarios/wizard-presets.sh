# tests/scenarios/wizard-presets.sh — verify the resolution × size composition
# flows through configure.sh into Sonarr/Radarr quality profiles, and that the
# opt-in public-indexer preset seeds into Jackett.
#
# Composes the "720p Compact" cell (non-default) to config.yml with the public
# indexer preset enabled (--public-indexers true) before bringing up the stack,
# then checks that Sonarr and Radarr have the expected profile name, enabled
# qualities (SD floor → 720p, all sources), and cutoff, that the SD-floor
# quality IDs in presets.yml match the LIVE apps (Sonarr ≠ Radarr), and that
# Jackett seeded the indexers. This is the dedicated preset-on test: default
# scenarios ship indexers: [] and skip the Jackett indexer caps assertion.
#
# Recommended strip list for speed (~5 min vs ~15 min):
#   MS_TEST_STRIP_SERVICES=npm,fail2ban,homepage,portainer,seerr,jellyfin,unpackerr
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
    # 1. Compose the "720p Compact" cell to config.yml via wizard_apply.py
    # ------------------------------------------------------------------
    dind_exec "python3 scripts/setup/wizard_apply.py --resolution 720p --size compact --languages english,spanish --public-indexers true --config config.yml"

    local applied_name
    applied_name=$(dind_exec "python3 -c \"import yaml; print(yaml.safe_load(open('config.yml'))['quality_profile']['name'])\"")
    assert_eq "720p Compact" "$applied_name" "wizard: config.yml profile name set to 720p Compact"

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
    local _strip
    _strip=" $(echo "${MS_TEST_STRIP_SERVICES:-}" | tr ',' ' ') "
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
    # 3c. Confirm the SD-floor quality IDs in presets.yml match the LIVE apps.
    # Sonarr and Radarr assign different numeric IDs to some tiers (Bluray-480p
    # is 13 vs 20); this is the gate that catches a wrong quality_ids value
    # before it ships.
    # ------------------------------------------------------------------
    # name -> id from /api/v3/qualitydefinition for a given app base+key.
    _live_quality_id() {
        local base="$1" key="$2" qname="$3"
        dind_exec "curl -sf -H 'X-Api-Key: $key' $base/qualitydefinition" \
            | python3 -c "
import sys, json
name = '$qname'
try:
    for d in json.load(sys.stdin):
        if d.get('quality', {}).get('name') == name:
            print(d['quality']['id']); break
except Exception: pass" 2>/dev/null
    }

    # ------------------------------------------------------------------
    # 4. Verify Sonarr quality profile
    # ------------------------------------------------------------------
    local sonarr_key
    sonarr_key=$(get_api_key_from_xml "config/sonarr/config.xml")
    [[ -n "$sonarr_key" ]] && pass "wizard: Sonarr API key" || fail "wizard: Sonarr API key"

    local sonarr_base="http://localhost:8989/api/v3"

    # 4-SD. SD-floor name→id confirmation (Sonarr).
    assert_eq "1" "$(_live_quality_id "$sonarr_base" "$sonarr_key" SDTV)" "wizard: Sonarr SDTV id=1"
    assert_eq "2" "$(_live_quality_id "$sonarr_base" "$sonarr_key" DVD)" "wizard: Sonarr DVD id=2"
    assert_eq "8" "$(_live_quality_id "$sonarr_base" "$sonarr_key" WEBDL-480p)" "wizard: Sonarr WEBDL-480p id=8"
    assert_eq "12" "$(_live_quality_id "$sonarr_base" "$sonarr_key" WEBRip-480p)" "wizard: Sonarr WEBRip-480p id=12"
    assert_eq "13" "$(_live_quality_id "$sonarr_base" "$sonarr_key" Bluray-480p)" "wizard: Sonarr Bluray-480p id=13"

    # 4a. Profile name
    local sonarr_qp_id
    sonarr_qp_id=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualityprofile" \
        | python3 -c "
import sys, json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='720p Compact'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$sonarr_qp_id" ]]; then
        pass "wizard: Sonarr 720p Compact profile created"
    else
        fail "wizard: Sonarr 720p Compact profile created" "not found in profile list"
    fi

    # 4b. Enabled qualities — SD floor → 720p, all sources.
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
        assert_eq "1,2,4,5,6,8,12,13,14" "$sonarr_enabled" "wizard: Sonarr 720p compact qualities (SD floor → 720p)"

        # 4c. Cutoff — WEB 720p group; sits ABOVE the SD floor, so SD is a
        # fallback that upgrades away (render preserves the app's worst→best
        # order; it only flips `allowed`).
        local sonarr_cutoff
        sonarr_cutoff=$(dind_exec "curl -sf -H 'X-Api-Key: $sonarr_key' $sonarr_base/qualityprofile/$sonarr_qp_id" \
            | python3 -c "import sys, json; print(json.load(sys.stdin).get('cutoff',''))" 2>/dev/null)
        assert_eq "1001" "$sonarr_cutoff" "wizard: Sonarr 720p compact cutoff 1001 (above SD floor)"
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

    # 5-SD. SD-floor name→id confirmation (Radarr — WEBRip-480p differs from Sonarr).
    assert_eq "1" "$(_live_quality_id "$radarr_base" "$radarr_key" SDTV)" "wizard: Radarr SDTV id=1"
    assert_eq "2" "$(_live_quality_id "$radarr_base" "$radarr_key" DVD)" "wizard: Radarr DVD id=2"
    assert_eq "8" "$(_live_quality_id "$radarr_base" "$radarr_key" WEBDL-480p)" "wizard: Radarr WEBDL-480p id=8"
    assert_eq "12" "$(_live_quality_id "$radarr_base" "$radarr_key" WEBRip-480p)" "wizard: Radarr WEBRip-480p id=12"
    assert_eq "20" "$(_live_quality_id "$radarr_base" "$radarr_key" Bluray-480p)" "wizard: Radarr Bluray-480p id=20"

    local radarr_qp_id
    radarr_qp_id=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualityprofile" \
        | python3 -c "
import sys, json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='720p Compact'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$radarr_qp_id" ]]; then
        pass "wizard: Radarr 720p Compact profile created"
    else
        fail "wizard: Radarr 720p Compact profile created" "not found in profile list"
    fi

    if [[ -n "$radarr_qp_id" ]]; then
        # 5b. Radarr SD floor → 720p, all sources (Bluray-480p=20 not 13).
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
        assert_eq "1,2,4,5,6,8,12,14,20" "$radarr_enabled" "wizard: Radarr 720p compact qualities (SD floor → 720p)"

        local radarr_cutoff
        radarr_cutoff=$(dind_exec "curl -sf -H 'X-Api-Key: $radarr_key' $radarr_base/qualityprofile/$radarr_qp_id" \
            | python3 -c "import sys, json; print(json.load(sys.stdin).get('cutoff',''))" 2>/dev/null)
        assert_eq "1001" "$radarr_cutoff" "wizard: Radarr 720p compact cutoff 1001 (above SD floor)"
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

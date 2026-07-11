# =============================================================================
# Bazarr — connect Sonarr/Radarr, apply general settings, seed language profile
# =============================================================================
# Bazarr v1.5+ stores all settings in config/bazarr/config/config.yaml.
# The /api/system/settings endpoint is read-only for connection details;
# writes must go to the YAML file, then restart the container.

configure_bazarr() {
    echo ""
    echo -e "${BOLD}Configuring Bazarr (subtitles)...${NC}"

    local bazarr_url
    bazarr_url="$(service_local_url bazarr)"
    local bazarr_config="$SCRIPT_DIR/config/bazarr/config/config.yaml"

    if [[ ! -f "$bazarr_config" ]]; then
        log_warn "Bazarr config not found at $bazarr_config - skipping"
        return 0
    fi

    local bazarr_key
    bazarr_key=$(python3 -c "
import yaml
with open('$bazarr_config') as f:
    c = yaml.safe_load(f)
print(c.get('auth', {}).get('apikey', ''))
" 2>/dev/null || echo "")

    if [[ -z "$bazarr_key" ]]; then
        log_warn "Could not read Bazarr API key - skipping"
        return 0
    fi

    save_api_key "BAZARR_API_KEY" "$bazarr_key"

    local sonarr_key radarr_key
    sonarr_key=$(get_api_key "$SCRIPT_DIR/config/sonarr/config.xml")
    radarr_key=$(get_api_key "$SCRIPT_DIR/config/radarr/config.xml")

    # Check current state via API (read works fine)
    local current_settings
    if ! current_settings=$(api_fetch "Bazarr settings" -H "X-API-KEY: $bazarr_key" "$bazarr_url/api/system/settings"); then
        current_settings="{}"
    fi

    local current_sonarr_key current_radarr_key current_use_sonarr
    current_sonarr_key=$(echo "$current_settings" | json_path sonarr.apikey)
    current_radarr_key=$(echo "$current_settings" | json_path radarr.apikey)
    current_use_sonarr=$(echo "$current_settings" | json_path general.use_sonarr False)

    local sonarr_connected=false radarr_connected=false general_applied=false
    [[ -n "$current_sonarr_key" && "$current_sonarr_key" != "None" && "$current_sonarr_key" != "" ]] && sonarr_connected=true
    [[ -n "$current_radarr_key" && "$current_radarr_key" != "None" && "$current_radarr_key" != "" ]] && radarr_connected=true
    [[ "$current_use_sonarr" == "True" ]] && general_applied=true

    if $sonarr_connected && $radarr_connected && $general_applied; then
        log_skip "Sonarr already connected to Bazarr"
        log_skip "Radarr already connected to Bazarr"
        log_skip "General settings already applied"
    else
        # Write settings to config.yaml and restart
        local needs_restart=false

        SONARR_KEY="$sonarr_key" RADARR_KEY="$radarr_key" \
            SONARR_CONNECTED="$sonarr_connected" RADARR_CONNECTED="$radarr_connected" \
            GENERAL_APPLIED="$general_applied" \
            python3 -c "
import os, yaml

config_path = '$bazarr_config'
with open(config_path) as f:
    c = yaml.safe_load(f)

changed = False
sonarr_key = os.environ.get('SONARR_KEY', '')
radarr_key = os.environ.get('RADARR_KEY', '')
sonarr_connected = os.environ.get('SONARR_CONNECTED') == 'true'
radarr_connected = os.environ.get('RADARR_CONNECTED') == 'true'
general_applied = os.environ.get('GENERAL_APPLIED') == 'true'

if sonarr_key and not sonarr_connected:
    c['sonarr']['ip'] = 'sonarr'
    c['sonarr']['port'] = 8989
    c['sonarr']['apikey'] = sonarr_key
    c['sonarr']['base_url'] = ''
    c['sonarr']['full_update'] = 'Daily'
    c['sonarr']['series_sync'] = 60
    c['sonarr']['only_monitored'] = True
    c['sonarr']['exclude_season_zero'] = True
    c['sonarr']['ssl'] = False
    changed = True

if radarr_key and not radarr_connected:
    c['radarr']['ip'] = 'radarr'
    c['radarr']['port'] = 7878
    c['radarr']['apikey'] = radarr_key
    c['radarr']['base_url'] = ''
    c['radarr']['full_update'] = 'Daily'
    c['radarr']['movies_sync'] = 60
    c['radarr']['only_monitored'] = True
    c['radarr']['ssl'] = False
    changed = True

if not general_applied:
    c['general']['use_sonarr'] = True
    c['general']['use_radarr'] = True
    c['general']['serie_default_enabled'] = True
    c['general']['movie_default_enabled'] = True
    c['general']['serie_default_profile'] = 1
    c['general']['movie_default_profile'] = 1
    c['general']['subfolder'] = 'current'
    c['general']['utf8_encode'] = True
    c['general']['use_scenename'] = True
    c['general']['multithreading'] = True
    c['general']['ignore_pgs_subs'] = True
    changed = True

if changed:
    with open(config_path, 'w') as f:
        yaml.safe_dump(c, f, sort_keys=False)
" >/dev/null 2>&1
        local write_result=$?

        if [[ "$write_result" -ne 0 ]]; then
            log_warn "Failed to write Bazarr config - skipping connection/general settings"
            return 0
        fi

        if ! $sonarr_connected && [[ -n "$sonarr_key" ]]; then
            log_ok "Sonarr connected to Bazarr"
            needs_restart=true
        elif [[ -z "$sonarr_key" ]]; then
            log_warn "Sonarr API key not available - skipping Bazarr Sonarr connection"
        else
            log_skip "Sonarr already connected to Bazarr"
        fi

        if ! $radarr_connected && [[ -n "$radarr_key" ]]; then
            log_ok "Radarr connected to Bazarr"
            needs_restart=true
        elif [[ -z "$radarr_key" ]]; then
            log_warn "Radarr API key not available - skipping Bazarr Radarr connection"
        else
            log_skip "Radarr already connected to Bazarr"
        fi

        if ! $general_applied; then
            log_ok "General settings applied"
            needs_restart=true
        else
            log_skip "General settings already applied"
        fi

        if $needs_restart; then
            # Bazarr reads sonarr/radarr + general settings from config.yaml only
            # at startup (no live API for these), so a restart is required — hence
            # the second "Waiting for Bazarr" below.
            log_info "Restarting Bazarr to apply settings..."
            docker compose restart bazarr >/dev/null 2>&1
            wait_for_service "Bazarr" "$bazarr_url"
        fi
    fi

    # --- Enable languages + create profile via SQLite ---
    local bazarr_db="$SCRIPT_DIR/config/bazarr/db/bazarr.db"
    if [[ ! -f "$bazarr_db" ]]; then
        log_warn "Bazarr database not found at $bazarr_db - skipping language setup"
    else
        local profile_exists
        profile_exists=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$bazarr_db')
rows = conn.execute('SELECT COUNT(*) FROM table_languages_profiles').fetchone()[0]
conn.close()
print(rows)
" 2>/dev/null || echo "0")

        if [[ "$profile_exists" -gt 0 ]]; then
            log_skip "Language profile already exists"
        else
            local bazarr_langs
            bazarr_langs=$(cfg_bazarr_languages | paste -sd, -)
            bazarr_langs="${bazarr_langs:-english}"

            BAZARR_LANGS="$bazarr_langs" python3 -c "
import os, sqlite3, json

LANG_MAP = {
    'english':    {'code2': 'en', 'code3': 'eng'},
    'spanish':    {'code2': 'es', 'code3': 'spa'},
    'french':     {'code2': 'fr', 'code3': 'fre'},
    'german':     {'code2': 'de', 'code3': 'ger'},
    'portuguese': {'code2': 'pt', 'code3': 'por'},
    'dutch':      {'code2': 'nl', 'code3': 'dut'},
    'italian':    {'code2': 'it', 'code3': 'ita'},
    'japanese':   {'code2': 'ja', 'code3': 'jpn'},
    'chinese':    {'code2': 'zh', 'code3': 'chi'},
    'korean':     {'code2': 'ko', 'code3': 'kor'},
    'arabic':     {'code2': 'ar', 'code3': 'ara'},
    'russian':    {'code2': 'ru', 'code3': 'rus'},
    'swedish':    {'code2': 'sv', 'code3': 'swe'},
    'norwegian':  {'code2': 'no', 'code3': 'nor'},
    'danish':     {'code2': 'da', 'code3': 'dan'},
    'finnish':    {'code2': 'fi', 'code3': 'fin'},
    'polish':     {'code2': 'pl', 'code3': 'pol'},
    'turkish':    {'code2': 'tr', 'code3': 'tur'},
    'hindi':      {'code2': 'hi', 'code3': 'hin'},
}

langs = [l.strip() for l in os.environ['BAZARR_LANGS'].split(',') if l.strip()]
conn = sqlite3.connect('$bazarr_db')

items = []
item_id = 1
for lang_name in langs:
    info = LANG_MAP.get(lang_name)
    if not info:
        continue
    conn.execute(
        'UPDATE table_settings_languages SET enabled = 1 WHERE code3 = ?',
        (info['code3'],),
    )
    items.append({'id': item_id, 'language': info['code2'],
                  'forced': 'True', 'hi': 'False', 'audio_exclude': 'False'})
    item_id += 1
    items.append({'id': item_id, 'language': info['code2'],
                  'forced': 'False', 'hi': 'False', 'audio_exclude': 'False'})
    item_id += 1

profile_name = ' + '.join(l.title() for l in langs if LANG_MAP.get(l))
conn.execute(
    '''INSERT INTO table_languages_profiles
       (profileId, name, items, cutoff, mustContain, mustNotContain, originalFormat)
       VALUES (1, ?, ?, NULL, '[]', '[]', 'False')''',
    (profile_name, json.dumps(items)),
)
conn.commit()
conn.close()
" 2>/dev/null && log_ok "Language profile created (${bazarr_langs//,/, })" || log_warn "Failed to create language profile"
        fi
    fi

    echo ""
    log_info "Configure subtitle providers at ${bazarr_url}/settings/providers"
}

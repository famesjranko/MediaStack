# =============================================================================
# 4. Radarr — root folder, qBittorrent download client, quality profile, indexers
# =============================================================================

configure_radarr() {
    echo ""
    echo -e "${BOLD}Configuring Radarr...${NC}"

    local radarr_key
    radarr_key=$(get_api_key "$SCRIPT_DIR/config/radarr/config.xml")
    if [[ -z "$radarr_key" ]]; then log_error "Cannot read Radarr API key"; return 1; fi
    log_ok "Radarr API key: ${radarr_key:0:8}..."
    local base="http://localhost:7878/api/v3"

    if declare -F storage_is_manual >/dev/null && storage_is_manual; then
        log_skip "Radarr root folder/download client skipped (manual app wiring)"
    else
        configure_arr_root_folder "radarr" "$base" "$radarr_key"
        configure_arr_disk_threshold "radarr" "$base" "$radarr_key"
        configure_arr_download_client "radarr" "$base" "$radarr_key" "movieCategory"
    fi

    # Quality Profile + per-tier size bounds
    local quality_ids; quality_ids=$(cfg_quality_ids "radarr")
    configure_quality_profile "radarr" "$base" "$radarr_key" "$quality_ids"
    configure_quality_definitions "radarr" "$base" "$radarr_key"

    # Custom Formats + scoring (TRaSH Guides)
    configure_arr_custom_formats "radarr" "$base" "$radarr_key"
    configure_arr_format_scores "radarr" "$base" "$radarr_key"

    # Naming Convention — TRaSH Guides Jellyfin-compatible scheme.
    # Enables renaming + sets folder/movie formats with [imdbid-*] tags
    # so Jellyfin matches metadata reliably without scraping guesswork.
    local naming_config current_rename
    if ! naming_config=$(api_get "$base/config/naming" "$radarr_key"); then
        log_warn "Could not fetch Radarr naming config - skipping"
        naming_config="{}"
    fi
    current_rename=$(echo "$naming_config" | json_get renameMovies False)
    if [[ "$current_rename" == "True" ]]; then
        log_skip "Radarr naming convention already configured"
    else
        local naming_body
        naming_body=$(echo "$naming_config" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config['renameMovies'] = True
config['replaceIllegalCharacters'] = True
config['standardMovieFormat'] = '{Movie CleanTitle} {(Release Year)} [imdbid-{ImdbId}] - {Edition Tags} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}'
config['movieFolderFormat'] = '{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]'
json.dump(config, sys.stdout)
" 2>/dev/null)
        if api_put "$base/config/naming" "$radarr_key" "$naming_body" >/dev/null 2>&1; then
            log_ok "Naming: TRaSH Guides (Jellyfin-compatible, imdbid tags)"
        else
            log_warn "Failed to set Radarr naming convention"
        fi
    fi

    # Indexer add is hoisted to scripts/configure.sh main() so Sonarr and
    # Radarr can run concurrently — see the matching note in sonarr/main.sh.
    save_api_key "RADARR_API_KEY" "$radarr_key"

    configure_arr_auth "radarr" "$base" "$radarr_key"
}

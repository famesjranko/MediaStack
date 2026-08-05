# =============================================================================
# 3. Sonarr — root folder, qBittorrent download client, quality profile, indexers
# =============================================================================

configure_sonarr() {
    echo ""
    echo -e "${BOLD}Configuring Sonarr...${NC}"

    local sonarr_key
    sonarr_key=$(api_get_key "$SCRIPT_DIR/config/sonarr/config.xml")
    if [[ -z "$sonarr_key" ]]; then
        log_error "Cannot read Sonarr API key"
        return 1
    fi
    log_ok "Sonarr API key: ${sonarr_key:0:8}..."
    local base
    base="$(service_local_url sonarr)/api/v3"

    if declare -F storage_is_manual >/dev/null && storage_is_manual; then
        log_skip "Sonarr root folder/download client skipped (manual app wiring)"
    else
        configure_arr_root_folder "sonarr" "$base" "$sonarr_key"
        configure_arr_disk_threshold "sonarr" "$base" "$sonarr_key"
        configure_arr_download_client "sonarr" "$base" "$sonarr_key" "tvCategory"
    fi

    # Quality Profile + per-tier size bounds
    local quality_ids
    quality_ids=$(cfg_quality_ids "sonarr")
    configure_quality_profile "sonarr" "$base" "$sonarr_key" "$quality_ids"
    configure_quality_definitions "sonarr" "$base" "$sonarr_key"

    # Custom Formats + scoring (TRaSH Guides)
    configure_arr_custom_formats "sonarr" "$base" "$sonarr_key"
    configure_arr_format_scores "sonarr" "$base" "$sonarr_key"

    # Naming Convention — TRaSH Guides Jellyfin-compatible scheme.
    # Enables renaming + sets folder/episode formats with [tvdbid-*] tags
    # so Jellyfin matches metadata reliably without scraping guesswork.
    local naming_config current_rename
    if ! naming_config=$(api_get "$base/config/naming" "$sonarr_key"); then
        log_warn "Could not fetch Sonarr naming config - skipping"
        naming_config="{}"
    fi
    current_rename=$(echo "$naming_config" | json_get renameEpisodes False)
    if [[ "$current_rename" == "True" ]]; then
        log_skip "Sonarr naming convention already configured"
    else
        local naming_body
        naming_body=$(echo "$naming_config" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config['renameEpisodes'] = True
config['replaceIllegalCharacters'] = True
config['multiEpisodeStyle'] = 5
config['standardEpisodeFormat'] = '{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}'
config['dailyEpisodeFormat'] = '{Series TitleYear} - {Air-Date} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}'
config['animeEpisodeFormat'] = '{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec }{MediaInfo VideoBitDepth}bit]{-Release Group}'
config['seriesFolderFormat'] = '{Series TitleYear} [tvdbid-{TvdbId}]'
config['seasonFolderFormat'] = 'Season {season:00}'
json.dump(config, sys.stdout)
" 2>/dev/null)
        if api_put "$base/config/naming" "$sonarr_key" "$naming_body" >/dev/null 2>&1; then
            log_ok "Naming: TRaSH Guides (Jellyfin-compatible, tvdbid tags)"
        else
            log_warn "Failed to set Sonarr naming convention"
        fi
    fi

    # Indexer add is hoisted to scripts/configure.sh main() so Sonarr and
    # Radarr can run concurrently — the save-time caps fetch through Jackett to
    # Cloudflare-protected trackers is the wizard's slowest phase, and there's
    # no per-app dependency between them. Save the API key here so the parallel
    # phase has $SONARR_API_KEY exported.
    env_save_api_key "SONARR_API_KEY" "$sonarr_key"

    configure_arr_auth "sonarr" "$base" "$sonarr_key"
}

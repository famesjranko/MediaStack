# =============================================================================
# MediaStack UI — demo mode
# =============================================================================
# Walks through every UI component with fake data. No Docker, no APIs, no file
# writes. Use to review visual presentation.
#
# Usage:
#   ./setup.sh --demo              # auto-advance
#   ./setup.sh --demo interactive  # pause at each section
#   ./setup.sh --demo fast         # minimal delays (CI/screenshots)

export UI_DEMO=1
# The demo is for reviewing presentation and capturing screenshots, often through
# a pipe (non-TTY) or with NO_COLOR set — force the full colour + glyph render so
# it always looks the way a capable terminal would show it.
export UI_FORCE_COLOR=1
export UI_FORCE_GLYPHS=1

_demo_pause() {
    if [[ "${DEMO_MODE:-auto}" == "interactive" ]]; then
        echo ""
        read -rsp "  Press Enter to continue..." -n1
        echo ""
    fi
}

_demo_delay() {
    local duration="${1:-1}"
    if [[ "${DEMO_MODE:-auto}" == "fast" ]]; then
        sleep 0.2
    else
        sleep "$duration"
    fi
}

run_demo() {
    local mode="${1:-auto}"
    export DEMO_MODE="$mode"

    if [[ "$mode" == "fast" ]]; then
        export UI_DEMO_DELAY="0.5"
    else
        export UI_DEMO_DELAY="1.5"
    fi

    ui_box "UI Demo Mode" "Mode: ${mode}"
    _demo_delay 1

    # --- Banner ---
    ui_banner "MediaStack Setup" "Turnkey Media Server for Home Networks"
    _demo_pause

    # --- Log levels ---
    ui_divider "Log Levels"
    ui_log ok "Service configured successfully"
    ui_log warn "Config drift detected on quality profile"
    ui_log error "Failed to connect to Jellyfin API"
    ui_log info "Starting auto-configuration..."
    ui_log skip "Already configured, skipping"
    _demo_pause

    # --- Sections + progress ---
    ui_divider "Step Progress"
    ui_section 1 9 "Configuring qBittorrent"
    ui_log ok "Preferences applied (download limit: 50MB/s)"
    ui_log ok "Categories: tv, movies"
    ui_progress 1 9 "steps complete"

    ui_section 2 9 "Configuring Jackett"
    ui_log ok "1337x added"
    ui_log ok "RARBG added"
    ui_log skip "TorrentGalaxy - already exists"
    ui_progress 2 9 "steps complete"
    _demo_pause

    # --- Spinners ---
    ui_divider "Spinners"
    ui_spin "Waiting for Sonarr to be healthy..." sleep "${UI_DEMO_DELAY}"
    ui_log ok "Sonarr ready"
    ui_spin "Applying quality profiles..." sleep "${UI_DEMO_DELAY}"
    ui_log ok "Quality profiles configured"
    ui_spin "Connecting Seerr to Jellyfin..." sleep "${UI_DEMO_DELAY}"
    ui_log ok "Seerr linked"
    _demo_pause

    # --- Input prompts ---
    ui_divider "Input Prompts"
    echo ""
    local tz data_dir username password
    tz=$(ui_input "Timezone" "America/New_York")
    ui_log info "Selected: $tz"
    data_dir=$(ui_input "Data directory" "/data")
    ui_log info "Selected: $data_dir"
    username=$(ui_input "Admin username" "admin")
    ui_log info "Selected: $username"
    password=$(ui_password "Admin password" "s3cur3P@ss!")
    ui_log info "Password set (${#password} chars)"
    _demo_pause

    # --- Confirmations ---
    ui_divider "Confirmations"
    echo ""
    if ui_confirm "Enable automatic subtitles (Bazarr)?" "no"; then
        ui_log ok "Bazarr enabled"
    else
        ui_log skip "Bazarr skipped"
    fi
    if ui_confirm "Enable remote access (WireGuard)?" "yes"; then
        ui_log ok "WireGuard enabled"
    else
        ui_log skip "WireGuard skipped"
    fi
    _demo_pause

    # --- Status line (in-place) ---
    ui_divider "In-Place Status"
    for i in $(seq 1 8); do
        local services=("sonarr" "radarr" "jackett" "jellyfin" "qbittorrent")
        local remaining=()
        for ((j=i; j<${#services[@]}; j++)); do
            remaining+=("${services[$j]}")
        done
        ui_status "Waiting... ($((i*5))s) Still starting: ${remaining[*]:-none}"
        _demo_delay 0.4
    done
    ui_status_clear
    ui_log ok "All services healthy"
    _demo_pause

    # --- Key-value summary ---
    ui_divider "Service Summary"
    echo ""
    ui_kv "Dashboard" "http://192.168.1.50:5005"
    ui_kv "Jellyfin" "http://192.168.1.50:8096"
    ui_kv "Sonarr" "http://192.168.1.50:8989"
    ui_kv "Radarr" "http://192.168.1.50:7878"
    ui_kv "Jackett" "http://192.168.1.50:9117"
    ui_kv "qBittorrent" "http://192.168.1.50:8080"
    ui_kv "Seerr" "http://192.168.1.50:5055"
    ui_kv "NPM Admin" "http://192.168.1.50:81"
    _demo_pause

    # --- Box ---
    ui_divider "Styled Boxes"
    ui_box "Admin Credentials" \
        "Username:  admin" \
        "Password:  (see .env)" \
        "NPM email: admin@example.com" \
        "" \
        "All services share the same credentials."

    ui_box "Management Commands" \
        "Update all:     ./scripts/update.sh" \
        "Stop all:       docker compose down" \
        "View logs:      docker compose logs -f <service>"
    _demo_pause

    # --- Drift warnings ---
    ui_divider "Drift Detection"
    ui_log warn "Quality profile 'HD-1080p' differs from config.yml"
    ui_log info "  Live: min=5GB, max=15GB"
    ui_log info "  Want: min=3GB, max=12GB"
    ui_log info "  Fix: edit in Sonarr UI or rebuild (docker compose down -v && ./setup.sh --full)"
    echo ""
    ui_log warn "Root folder '/data/media/movies' has extra entry '/mnt/external/movies'"
    ui_log info "  Not in config.yml - added manually?"
    _demo_pause

    # --- Full progress bar sequence ---
    ui_divider "Full Run Simulation"
    local steps=("qBittorrent" "Jackett" "Sonarr" "Radarr" "Jellyfin" "Seerr" "Homepage" "NPM" "DDNS")
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        ui_section "$step_num" 9 "Configuring ${steps[$i]}"
        ui_spin "Waiting for ${steps[$i]}..." sleep "${UI_DEMO_DELAY}"
        ui_log ok "${steps[$i]} configured"
        ui_progress "$step_num" 9 "steps complete"
    done
    _demo_pause

    # --- Setup Wizard ---
    ui_divider "Setup Wizard"
    ui_banner "MediaStack Setup Wizard" "Choose your preferences (5 quick steps)"

    ui_divider "Host Discovery"
    ui_log info "Probing your network to inform setup recommendations..."
    ui_spin "Detecting public IP..." sleep "${UI_DEMO_DELAY}"
    ui_log ok "Public IP: 203.0.113.42"
    ui_spin "Measuring your connection speed (~15s)..." sleep "${UI_DEMO_DELAY}"
    ui_log ok "Download: 120 Mbps | Upload: 40 Mbps"
    ui_log info "Checking default port reachability..."
    ui_log ok "Port 6881: open"
    ui_log ok "Port 80: open"
    ui_log warn "Port 443: closed (needs router forwarding)"
    ui_log info "Port 51820: UDP - cannot verify from inside network"
    ui_log info "Hairpin NAT caveat: ports may appear closed when tested from the same network."
    ui_log ok "Discovery complete"
    _demo_pause

    ui_section 1 5 "Transcoding"
    ui_log info "NVIDIA GPU detected: GeForce RTX 3060"
    local gpu_demo
    gpu_demo=$(ui_choose "Transcoding mode:" \
        "NVIDIA GPU (recommended)" \
        "Intel Quick Sync" \
        "CPU only (software transcoding)")
    ui_log ok "Transcoding: $gpu_demo"

    ui_section 2 5 "Media Quality"
    local resolution_demo size_demo
    resolution_demo=$(UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Choose the maximum video resolution:" \
        "720p  - Smaller library, lower bandwidth." \
        "1080p - Full HD. Recommended for most users.")
    size_demo=$(UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Choose how much storage to spend per movie/show:" \
        "Compact  - Smaller files. ~2-4 GB/movie." \
        "Balanced - Recommended. ~4-8 GB/movie." \
        "Large    - Largest files, best quality. ~6-15 GB/movie.")
    ui_log ok "Media quality: ${resolution_demo%% *} ${size_demo%% *}"

    ui_section 3 5 "Subtitles"
    if ui_confirm "Enable automatic subtitle downloads?" "no"; then
        ui_log ok "Subtitles enabled"
    else
        ui_log skip "Subtitles disabled"
    fi

    ui_section 4 5 "Remote Streaming"
    ui_log ok "Streaming limit: unlimited"

    ui_section 5 5 "Port Forwarding"
    ui_box "Required Port Forwards -> 192.168.1.50" \
        "  TCP 80       Let's Encrypt + HTTP redirect" \
        "  TCP 443      HTTPS (Jellyfin, Seerr)" \
        "  TCP+UDP 6881 qBittorrent peer connections" \
        "  UDP 51820    WireGuard VPN"
    ui_log info "Log into your router and find Port Forwarding (usually under NAT/Firewall)"
    ui_log warn "Do NOT forward: 81, 8096, 8989, 7878, 9117, 8080, 5055, 51821, 8000"

    ui_box "Setup Wizard Summary" \
        "Transcoding     NVIDIA GPU" \
        "Media Quality   Compact" \
        "Subtitles       Disabled" \
        "Streaming       No limit" \
        "Port forwards   TCP 80, 443, 6881 + UDP 6881, 51820" \
        "" \
        "--- Network ---" \
        "Download speed  120 Mbps" \
        "Upload speed    40 Mbps" \
        "Public IP       203.0.113.42" \
        "Port 6881       open" \
        "Port 80         open" \
        "Port 443        closed" \
        "Port 51820      udp-unverifiable"

    if ui_confirm "Apply these settings?" "yes"; then
        ui_log ok "Settings applied to config.yml"
    fi
    _demo_pause

    # --- Final ---
    echo ""
    ui_banner "Setup Complete!" "MediaStack is running"
    ui_log ok "9/9 services configured successfully"
    ui_log info "Access your dashboard at http://192.168.1.50:5005"
    echo ""
}

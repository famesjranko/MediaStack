# =============================================================================
# Jellyfin server identity and remote streaming limit
# =============================================================================

configure_jellyfin_server_name() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local want_name
    want_name=$(cfg_field "jellyfin.server_name" 2>/dev/null || echo "MediaStack")
    want_name="${want_name:-MediaStack}"

    local current_config
    if ! current_config=$(api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin server config - skipping server name"
        return 0
    fi

    local current_name
    current_name=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('ServerName', ''))" 2>/dev/null)

    if [[ "$current_name" == "$want_name" ]]; then
        log_skip "Server name: $want_name"
        return 0
    fi

    # Empty or docker-default hostname → first run, safe to set.
    # Anything else → user changed it in the UI, warn but don't overwrite.
    if [[ -n "$current_name" && "$current_name" != "jellyfin" ]]; then
        log_drift "Jellyfin server name is '$current_name' (expected '$want_name'). Changed in Dashboard? Not overwriting."
        return 0
    fi

    local updated_config
    updated_config=$(echo "$current_config" | WANT="$want_name" python3 -c "
import sys, json, os
c = json.load(sys.stdin)
c['ServerName'] = os.environ['WANT']
print(json.dumps(c))")

    if api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$updated_config" >/dev/null; then
        log_ok "Server name: $want_name"
    else
        log_warn "Failed to set server name - configure manually in Dashboard -> General"
    fi
}

configure_jellyfin_streaming() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local bitrate_mbps
    bitrate_mbps=$(cfg_field "jellyfin.remote_bitrate_limit" 2>/dev/null || echo "0")
    bitrate_mbps="${bitrate_mbps:-0}"
    # Accept decimal Mbps (3.5, 12.5, etc.) — useful for ISPs whose upload
    # doesn't divide neatly across viewer counts. Reject only true garbage.
    if ! [[ "$bitrate_mbps" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "jellyfin.remote_bitrate_limit is not a valid number ('$bitrate_mbps') - skipping"
        return 0
    fi
    # Use python for the Mbps→bps conversion so decimals survive (bash
    # arithmetic is integer-only). int() truncates rather than rounds, which
    # is the right choice — better to cap a hair below the budget than over.
    local bitrate_bps
    bitrate_bps=$(BITRATE_MBPS="$bitrate_mbps" python3 -c 'import os; print(int(float(os.environ["BITRATE_MBPS"]) * 1_000_000))')

    local current_config
    if ! current_config=$(api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin server config - skipping streaming limit"
        return 0
    fi

    local current_limit
    current_limit=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('RemoteClientBitrateLimit', 0))" 2>/dev/null)

    if [[ "$current_limit" == "$bitrate_bps" ]]; then
        if [[ "$bitrate_bps" == "0" ]]; then
            log_skip "Remote streaming limit: unlimited"
        else
            log_skip "Remote streaming limit already set to ${bitrate_mbps} Mbps"
        fi
        return 0
    fi

    local updated_config
    updated_config=$(echo "$current_config" | BITRATE="$bitrate_bps" python3 -c "
import sys, json, os
c = json.load(sys.stdin)
c['RemoteClientBitrateLimit'] = int(os.environ['BITRATE'])
print(json.dumps(c))")

    if api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$updated_config" >/dev/null; then
        if [[ "$bitrate_mbps" == "0" ]]; then
            log_ok "Remote streaming limit: unlimited"
        else
            log_ok "Remote streaming limit: ${bitrate_mbps} Mbps"
            local domain="${DOMAIN:-}"
            if [[ -n "$domain" && "$domain" != "example.com" ]]; then
                log_info "Bitrate limit for proxied users requires KnownProxies - configuring next"
            fi
        fi
    else
        log_warn "Failed to set streaming limit - configure manually in Dashboard -> Playback -> Streaming"
    fi
}

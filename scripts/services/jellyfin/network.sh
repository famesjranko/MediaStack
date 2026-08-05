# Owns: configure_jellyfin_networking — PublishedServerUrl and KnownProxies via the System/Configuration/network API.
# Sources: main.sh (auth/session context), api helpers and log_* from scripts/lib/common.sh.

configure_jellyfin_networking() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local current_config
    if ! current_config=$(api_fetch "Jellyfin network config" \
        "$jf_url/System/Configuration/network" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin network config - skipping"
        return 0
    fi

    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"
    local host_addr="${HOST_ADDRESS:-localhost}"
    local remote_ready=false
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready=true
    fi
    local published_url current_published_url published_url_changed=false
    if [[ "$remote_ready" == "true" ]]; then
        published_url="https://jellyfin.${domain}"
    else
        published_url="http://${host_addr}:8096"
    fi
    current_published_url=$(grep -oP '^JELLYFIN_PUBLISHED_URL=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
    [[ "$current_published_url" != "$published_url" ]] && published_url_changed=true

    local npm_proxy_ip="${MEDIASTACK_NPM_IP:-172.28.0.10}"
    local result
    result=$(printf '%s' "$current_config" \
        | REMOTE_READY="$remote_ready" HOST_ADDR="$host_addr" DOMAIN_VAL="$domain" NPM_PROXY_IP="$npm_proxy_ip" \
            python3 "$_JELLYFIN_SERVICE_DIR/render/network_policy.py" 2>/dev/null)

    local action
    action=$(echo "$result" | head -1)

    case "$action" in
        SKIP)
            log_skip "Jellyfin networking already configured"
            env_save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"
            if [[ "$published_url_changed" == "true" ]]; then
                log_info "Recreating Jellyfin for PublishedServerUrl change..."
                if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                    log_warn "Failed to recreate Jellyfin - view logs from the menu: Manage stack -> Tail logs (live)"
                fi
                if ! post_restart_wait "$jf_url/health"; then
                    log_warn "Jellyfin did not become healthy within 60s after recreate - check 'docker logs jellyfin'"
                fi
            fi
            return 0
            ;;
        DRIFT)
            echo "$result" | tail -n +2 | while IFS= read -r msg; do
                log_drift "Jellyfin networking: $msg - not overwriting (changed in UI?)"
            done
            env_save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"
            if [[ "$published_url_changed" == "true" ]]; then
                log_info "Recreating Jellyfin for PublishedServerUrl change..."
                if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                    log_warn "Failed to recreate Jellyfin - view logs from the menu: Manage stack -> Tail logs (live)"
                fi
                if ! post_restart_wait "$jf_url/health"; then
                    log_warn "Jellyfin did not become healthy within 60s after recreate - check 'docker logs jellyfin'"
                fi
            fi
            return 0
            ;;
        APPLY_WITH_DRIFT)
            local drift_lines body
            drift_lines=$(echo "$result" | sed '1d;/^---$/,$d')
            body=$(echo "$result" | sed '1,/^---$/d')
            echo "$drift_lines" | while IFS= read -r msg; do
                log_drift "Jellyfin networking: $msg - not overwriting (changed in UI?)"
            done
            ;;
        APPLY)
            local body
            body=$(echo "$result" | tail -n +2)
            ;;
        *)
            log_warn "Unexpected result from networking config check - skipping"
            return 0
            ;;
    esac

    if api_fetch "Jellyfin network config" \
        "$jf_url/System/Configuration/network" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null; then

        # Write JELLYFIN_PUBLISHED_URL to .env for docker-compose
        env_save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"

        log_ok "Jellyfin networking configured (AutoDiscovery, KnownProxies, PublishedServerUriBySubnet)"

        # KnownProxies and AutoDiscovery are startup-config — restart required
        if [[ "$published_url_changed" == "true" ]]; then
            # Give Jellyfin a moment to flush the just-POSTed network config
            # before replacing the container to pick up compose env changes.
            sleep 2
            log_info "Recreating Jellyfin for networking and PublishedServerUrl changes to take effect..."
            if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                log_warn "Failed to recreate Jellyfin - view logs from the menu: Manage stack -> Tail logs (live)"
            fi
        else
            log_info "Restarting Jellyfin for networking changes to take effect..."
            if ! docker compose restart jellyfin >/dev/null 2>&1; then
                log_warn "Failed to restart Jellyfin - view logs from the menu: Manage stack -> Tail logs (live)"
            fi
        fi
        if ! post_restart_wait "$jf_url/health"; then
            log_warn "Jellyfin did not become healthy within 60s after restart - check 'docker logs jellyfin'"
        fi
    else
        log_warn "Failed to set Jellyfin networking config - configure manually in Dashboard -> Networking"
    fi
}

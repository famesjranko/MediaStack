# Owns: configure_* — configure_jellyfin_networking — PublishedServerUrl and KnownProxies via the System/Configuration/network API.
# Sources: main.sh (auth/session context), api helpers and log_* from scripts/lib/common.sh.

configure_jellyfin_network_now() {
    python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

configure_jellyfin_network_ready() {
    local jf_url="$1" jf_token="$2" budget="${3:-30}"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local start deadline now remaining request_ms sleep_ms request_seconds sleep_seconds code rc body
    start=$(configure_jellyfin_network_now) || return 1
    deadline=$((start + budget * 1000))
    body=$(mktemp) || return 1

    while :; do
        now=$(configure_jellyfin_network_now) || break
        remaining=$((deadline - now))
        ((remaining > 0)) || break
        request_ms=$((remaining < 3000 ? remaining : 3000))
        printf -v request_seconds '%d.%03d' "$((request_ms / 1000))" "$((request_ms % 1000))"
        code=$(curl_header_stdin "Authorization" "$auth" -sS --max-time "$request_seconds" --max-filesize 65536 \
            -o "$body" -w '%{http_code}' "$jf_url/System/Configuration/network" 2>/dev/null)
        rc=$?
        if [[ "$rc" == "0" && "$code" == "200" ]] \
            && (($(wc -c <"$body") <= 65536)) \
            && python3 -c '
import json
import sys

try:
    value = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    sys.exit(1)

if not isinstance(value, dict):
    sys.exit(1)
for key in ("KnownProxies", "PublishedServerUriBySubnet"):
    items = value.get(key)
    if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
        sys.exit(1)
' "$body" 2>/dev/null; then
            now=$(configure_jellyfin_network_now) || break
            if ((now < deadline)); then
                rm -f "$body"
                return 0
            fi
        fi
        case "$rc:$code" in
            0:503 | 7:* | 28:* | 56:*) ;;
            *)
                rm -f "$body"
                return 1
                ;;
        esac
        now=$(configure_jellyfin_network_now) || break
        remaining=$((deadline - now))
        ((remaining > 0)) || break
        sleep_ms=$((remaining < 1000 ? remaining : 1000))
        printf -v sleep_seconds '%d.%03d' "$((sleep_ms / 1000))" "$((sleep_ms % 1000))"
        sleep "$sleep_seconds"
    done
    rm -f "$body"
    return 1
}

configure_jellyfin_networking() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local current_config
    if ! current_config=$(api_fetch_auth "Jellyfin network config" "Authorization" "$auth" \
        "$jf_url/System/Configuration/network"); then
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
                if ! configure_jellyfin_network_ready "$jf_url" "$jf_token"; then
                    log_warn "Jellyfin network API did not become ready within 30s after recreate - check 'docker logs jellyfin'"
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
                if ! configure_jellyfin_network_ready "$jf_url" "$jf_token"; then
                    log_warn "Jellyfin network API did not become ready within 30s after recreate - check 'docker logs jellyfin'"
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

    if api_fetch_auth "Jellyfin network config" "Authorization" "$auth" \
        "$jf_url/System/Configuration/network" \
        -X POST \
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
        if ! configure_jellyfin_network_ready "$jf_url" "$jf_token"; then
            log_warn "Jellyfin network API did not become ready within 30s after restart - check 'docker logs jellyfin'"
        fi
    else
        log_warn "Failed to set Jellyfin networking config - configure manually in Dashboard -> Networking"
    fi
}

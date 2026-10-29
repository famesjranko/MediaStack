# =============================================================================
# 2. Jackett — seed session cookie, add public indexers, set admin password
# =============================================================================

# Seed the session cookie in <jar>, then prove it works; if not, authenticate
# with the admin password. Probe the HTTP code explicitly: Jackett returns
# 302 -> /UI/Login when the session is invalid, and `http_curl -sf` does NOT fail on
# 3xx, so a bare `! http_curl -sf` check passes falsely once the admin password is
# set (every indexer then reports "not available in Jackett").
# Args: <jackett base url> <indexers url> <api key> <jar> <admin password>
_jackett_session() {
    local base="$1" indexers_url="$2" key="$3" jar="$4" pw="$5" probe_code
    http_curl -sf -c "$jar" -X POST "${base}/UI/Dashboard" -d "" >/dev/null 2>&1
    probe_code=$(http_curl -s -o /dev/null -w '%{http_code}' -b "$jar" -K - \
        < <(curl_url_config "${indexers_url}?configured=true&apikey=${key}") 2>/dev/null || echo "000")
    if [[ "$probe_code" != "200" && -n "$pw" ]]; then
        curl_data_urlencode_stdin password "$pw" \
            -sf -c "$jar" -X POST "${base}/UI/Dashboard" >/dev/null 2>&1 || true
    fi
}

configure_jackett() {
    echo ""
    echo -e "${BOLD}Configuring Jackett indexers...${NC}"

    local jackett_key
    jackett_key=$(api_get_jackett_key)
    if [[ -z "$jackett_key" ]]; then
        log_warn "Cannot read Jackett API key"
        return 0
    fi
    log_ok "Jackett API key: ${jackett_key:0:8}..."

    local jackett_base jackett_url
    jackett_base="$(service_local_url jackett)"
    jackett_url="${jackett_base}/api/v2.0/indexers"
    local jf_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    # Jackett's management API (everything except /results/torznab/) requires a
    # session cookie; the apikey query param alone returns 302 -> /UI/Login.
    # POST /UI/Dashboard with no body sets the cookie even when AdminPassword="".
    # On re-run (password already set), we must POST the password to authenticate.
    local jar
    jar=$(mktemp) || {
        log_warn "Cannot create cookie jar"
        return 0
    }

    _jackett_session "$jackett_base" "$jackett_url" "$jackett_key" "$jar" "$jf_pw"

    # Jackett's first-start rewrites ServerConfig.json and drops the pre-seeded
    # FlareSolverrUrl. Set it via API so Cloudflare-protected indexers work.
    local current_flare
    current_flare=$(python3 -c "
import json
with open('$SCRIPT_DIR/config/jackett/Jackett/ServerConfig.json') as f:
    print(json.load(f).get('FlareSolverrUrl') or '')
" 2>/dev/null || echo "")

    if [[ -n "$current_flare" ]]; then
        log_skip "FlareSolverr already configured ($current_flare)"
    else
        local server_cfg
        server_cfg=$(http_curl -sf -b "$jar" -K - \
            < <(curl_url_config "${jackett_base}/api/v2.0/server/config?apikey=${jackett_key}") 2>/dev/null)
        if [[ -n "$server_cfg" ]] && json_check "Jackett server config" :object flaresolverrurl:nullable <<<"$server_cfg"; then
            local patched
            patched=$(echo "$server_cfg" | FLARESOLVERR_URL="$(service_internal_url flaresolverr)" python3 -c "
import os, sys, json
d = json.load(sys.stdin)
d['flaresolverrurl'] = os.environ['FLARESOLVERR_URL']
d['flaresolverr_maxtimeout'] = 60000
print(json.dumps(d))
" 2>/dev/null)
            # The server config carries api_key, so the body rides stdin too.
            if [[ -n "$patched" ]] && http_curl -sf -b "$jar" -X POST -K - \
                -H "Content-Type: application/json" \
                < <(curl_url_config "${jackett_base}/api/v2.0/server/config?apikey=${jackett_key}" "$patched") >/dev/null 2>&1; then
                log_ok "FlareSolverr connected: $(service_internal_url flaresolverr)"
            else
                log_warn "Failed to set FlareSolverr URL"
            fi
        else
            log_warn "Failed to read Jackett server config"
        fi
        # Server config POST triggers an internal webhost restart (~20 s).
        # Wait for Jackett to come back, then re-seed the session cookie.
        sleep 1
        post_restart_wait "${jackett_base}/UI/Dashboard" 60 1 || true
        # The restart ends the session. With the admin password set, the
        # empty-body POST alone no longer authenticates.
        _jackett_session "$jackett_base" "$jackett_url" "$jackett_key" "$jar" "$jf_pw"
    fi

    # Get already-configured indexers
    local configured
    if ! configured=$(api_fetch "Jackett configured indexers" -b "$jar" -K - < <(curl_url_config "${jackett_url}?configured=true&apikey=${jackett_key}")); then
        rm -f "$jar"
        return 1
    fi

    json_check "Jackett configured indexers" :array '[].id:string' '[].configured:boolean' <<<"$configured" || {
        rm -f "$jar"
        return 1
    }

    # Add each indexer from config.yml
    while IFS=: read -r indexer_id indexer_type; do
        # Check if already configured
        if echo "$configured" | python3 -c "
import sys, json
sys.exit(0 if any(i.get('id','')=='$indexer_id' and i.get('configured',False) for i in json.load(sys.stdin)) else 1)
" 2>/dev/null; then
            log_skip "$indexer_id already configured"
            continue
        fi

        # Get default config and save it (enables the indexer)
        local config
        if ! config=$(api_fetch "Jackett $indexer_id config" -b "$jar" -K - < <(curl_url_config "${jackett_url}/${indexer_id}/config?apikey=${jackett_key}")); then
            config=""
        fi
        if [[ -z "$config" || "$config" == "[]" ]]; then
            log_warn "$indexer_id not available in Jackett"
            continue
        fi

        json_check "Jackett $indexer_id config" :array <<<"$config" || continue
        if http_curl -sf -b "$jar" -X POST -K - \
            -H "Content-Type: application/json" \
            < <(curl_url_config "${jackett_url}/${indexer_id}/config?apikey=${jackett_key}" "$config") >/dev/null 2>&1; then
            log_ok "Indexer added: $indexer_id ($indexer_type)"
        else
            log_warn "Failed: $indexer_id"
        fi
    done < <(cfg_indexers)

    # Set admin password (uses shared Jellyfin admin credentials).
    # POST /api/v2.0/server/adminpassword accepts a JSON string body (not an
    # object); Jackett hashes it internally with the API key as salt.
    if [[ -n "$jf_pw" ]]; then
        local current_hash
        current_hash=$(python3 -c "
import json
with open('$SCRIPT_DIR/config/jackett/Jackett/ServerConfig.json') as f:
    print(json.load(f).get('AdminPassword') or '')
" 2>/dev/null || echo "")

        if [[ -n "$current_hash" ]]; then
            log_skip "Jackett admin password already set"
        else
            local pw_json
            pw_json=$(JF_PW="$jf_pw" python3 -c "import json,os; print(json.dumps(os.environ['JF_PW']))" 2>/dev/null)
            # The password body and the key-bearing URL share one stdin config.
            if http_curl -sf -b "$jar" -X POST -K - \
                -H "Content-Type: application/json" \
                < <(curl_url_config "${jackett_base}/api/v2.0/server/adminpassword?apikey=${jackett_key}" "$pw_json") >/dev/null 2>&1; then
                log_ok "Jackett admin password set"
            else
                log_warn "Failed to set Jackett admin password"
            fi
        fi
    fi

    rm -f "$jar"
}

# =============================================================================
# 2. Jackett — seed session cookie, add public indexers, set admin password
# =============================================================================

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

    curl -sf -c "$jar" -X POST "${jackett_base}/UI/Dashboard" -d "" >/dev/null 2>&1
    # Verify session works; if not, retry with admin password. Must probe the
    # HTTP code explicitly — Jackett returns 302 → /UI/Login when the session
    # is invalid, and `curl -sf` does NOT fail on 3xx, so the bare `! curl -sf`
    # check passed falsely on re-runs (admin password set on first pass left
    # the empty-body POST unauthenticated, cascading into every indexer
    # reporting "not available in Jackett").
    local probe_code
    probe_code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" \
        "${jackett_url}?configured=true&apikey=${jackett_key}" 2>/dev/null || echo "000")
    if [[ "$probe_code" != "200" && -n "$jf_pw" ]]; then
        curl -sf -c "$jar" -X POST "${jackett_base}/UI/Dashboard" \
            --data-urlencode "password=$jf_pw" >/dev/null 2>&1 || true
    fi

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
        server_cfg=$(curl -sf -b "$jar" \
            "${jackett_base}/api/v2.0/server/config?apikey=${jackett_key}" 2>/dev/null)
        if [[ -n "$server_cfg" ]]; then
            local patched
            patched=$(echo "$server_cfg" | FLARESOLVERR_URL="$(service_internal_url flaresolverr)" python3 -c "
import os, sys, json
d = json.load(sys.stdin)
d['flaresolverrurl'] = os.environ['FLARESOLVERR_URL']
d['flaresolverr_maxtimeout'] = 60000
print(json.dumps(d))
" 2>/dev/null)
            if [[ -n "$patched" ]] && curl -sf -b "$jar" -X POST \
                "${jackett_base}/api/v2.0/server/config?apikey=${jackett_key}" \
                -H "Content-Type: application/json" \
                -d "$patched" >/dev/null 2>&1; then
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
        curl -sf -c "$jar" -X POST "${jackett_base}/UI/Dashboard" -d "" >/dev/null 2>&1
    fi

    # Get already-configured indexers
    local configured
    if ! configured=$(api_fetch "Jackett configured indexers" -b "$jar" "${jackett_url}?configured=true&apikey=${jackett_key}"); then
        configured="[]"
    fi

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
        if ! config=$(api_fetch "Jackett $indexer_id config" -b "$jar" "${jackett_url}/${indexer_id}/config?apikey=${jackett_key}"); then
            config=""
        fi
        if [[ -z "$config" || "$config" == "[]" ]]; then
            log_warn "$indexer_id not available in Jackett"
            continue
        fi

        if curl -sf -b "$jar" -X POST "${jackett_url}/${indexer_id}/config?apikey=${jackett_key}" \
            -H "Content-Type: application/json" -d "$config" >/dev/null 2>&1; then
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
            if curl -sf -b "$jar" -X POST \
                "${jackett_base}/api/v2.0/server/adminpassword?apikey=${jackett_key}" \
                -H "Content-Type: application/json" \
                -d "$pw_json" >/dev/null 2>&1; then
                log_ok "Jackett admin password set"
            else
                log_warn "Failed to set Jackett admin password"
            fi
        fi
    fi

    rm -f "$jar"
}

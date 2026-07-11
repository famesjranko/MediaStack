# =============================================================================
# Beszel — system resource monitoring (hub + agent) via PocketBase REST API
# =============================================================================
# Hub auto-creates a user from USER_EMAIL/USER_PASSWORD env vars on first start.
# This configurator authenticates, retrieves the agent SSH key, saves it to .env,
# recreates the agent container to pick up the key, and registers this host as a
# monitored system.

configure_beszel() {
    echo ""
    echo -e "${BOLD}Configuring Beszel...${NC}"

    local hub_url
    hub_url="$(service_local_url beszel)"
    local admin_email="${NPM_ADMIN_EMAIL:-}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$admin_email" || -z "$admin_pw" ]]; then
        log_warn "Admin credentials not set - skipping Beszel"
        return 0
    fi

    # --- 0. Ensure superuser exists (Homepage widget requires superuser auth) ---
    docker exec beszel /beszel superuser upsert "$admin_email" "$admin_pw" >/dev/null 2>&1 \
        && log_ok "Beszel superuser ensured" \
        || log_warn "Could not upsert Beszel superuser"

    # --- 1. Authenticate to hub ---
    local auth_body auth_resp token user_id
    auth_body=$(B_EMAIL="$admin_email" B_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"identity": os.environ["B_EMAIL"], "password": os.environ["B_PW"]}))
' 2>/dev/null) || { log_warn "Failed to build auth payload"; return 0; }

    auth_resp=$(curl -sS -X POST "$hub_url/api/collections/users/auth-with-password" \
        -H "Content-Type: application/json" \
        -d "$auth_body" -w "\n%{http_code}" 2>/dev/null) || { log_warn "Beszel hub not reachable - skipping"; return 0; }

    local auth_code="${auth_resp##*$'\n'}"
    auth_resp="${auth_resp%$'\n'*}"

    if [[ ! "$auth_code" =~ ^2 ]]; then
        log_warn "Beszel auth failed (HTTP $auth_code) - hub may still be initializing"
        return 0
    fi

    token=$(echo "$auth_resp" | json_get token)
    user_id=$(echo "$auth_resp" | json_path record.id)

    if [[ -z "$token" ]]; then
        log_warn "Beszel auth returned no token"
        return 0
    fi
    log_ok "Beszel hub authenticated"

    # --- 2. Get SSH key from hub ---
    local key_resp hub_key
    key_resp=$(curl -sS "$hub_url/api/beszel/getkey" \
        -H "Authorization: Bearer $token" 2>/dev/null)
    hub_key=$(echo "$key_resp" | json_get key)

    if [[ -z "$hub_key" ]]; then
        log_warn "Could not retrieve Beszel agent key"
        return 0
    fi

    # --- 3. Save key to .env if changed ---
    local current_key="${BESZEL_AGENT_KEY:-}"
    if [[ "$current_key" == "$hub_key" ]]; then
        log_skip "Beszel agent key already in .env"
    else
        save_api_key "BESZEL_AGENT_KEY" "$hub_key"

        # --- 4. Recreate agent so it picks up the new KEY ---
        log_info "Recreating beszel-agent with SSH key..."
        docker compose up -d beszel-agent >/dev/null 2>&1
        log_ok "Beszel agent restarted with key"
    fi

    # --- 5. Register this host as a monitored system ---
    local systems_resp
    systems_resp=$(curl -sS "$hub_url/api/collections/systems/records" \
        -H "Authorization: Bearer $token" 2>/dev/null)

    if echo "$systems_resp" | json_has_name "MediaStack" --key items; then
        log_skip "Beszel system 'MediaStack' already registered"
    else
        local sys_body sys_code sys_out
        sys_body=$(B_USER_ID="$user_id" python3 -c '
import os, json
print(json.dumps({
    "name": "MediaStack",
    "host": "host.docker.internal",
    "port": 45876,
    "users": [os.environ["B_USER_ID"]],
}))' 2>/dev/null)

        sys_out=$(curl -sS -X POST "$hub_url/api/collections/systems/records" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$sys_body" -w "\n%{http_code}" 2>/dev/null)
        sys_code="${sys_out##*$'\n'}"

        if [[ "$sys_code" =~ ^2 ]]; then
            log_ok "Beszel system 'MediaStack' registered"
        else
            sys_out="${sys_out%$'\n'*}"
            log_warn "Beszel system registration returned HTTP $sys_code: ${sys_out:0:200}"
        fi
    fi
}

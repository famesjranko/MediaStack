# =============================================================================
# 7. Portainer CE — create admin user with shared password
# =============================================================================
# Portainer CE locks itself if no admin is created within 5 minutes of first
# start. If that happens, we restart the container to reset the window.

configure_portainer() {
    echo ""
    echo -e "${BOLD}Configuring Portainer...${NC}"

    local portainer_url="http://localhost:9000"
    local admin_user="${JELLYFIN_ADMIN_USER:-admin}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$admin_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set in .env - skipping Portainer"
        return 0
    fi

    # Check current state via HTTP status code (not body — Portainer returns
    # JSON error bodies for timeouts that would give false positives).
    #   204 = admin exists     → skip
    #   404 = no admin yet     → create
    #   other = timeout/error  → restart and retry
    local check_http
    check_http=$(curl -s -o /dev/null -w "%{http_code}" \
        "$portainer_url/api/users/admin/check" 2>/dev/null)

    local admin_exists=false
    if [[ "$check_http" == "204" ]]; then
        log_skip "Portainer admin already initialized"
        admin_exists=true
    fi

    local init_body
    init_body=$(ADMIN_USER="$admin_user" ADMIN_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"Username": os.environ["ADMIN_USER"], "Password": os.environ["ADMIN_PW"]}))')

    if [[ "$admin_exists" == "false" ]]; then
        # If Portainer returned anything other than 404 (e.g. init timeout),
        # restart it to reset the 5-minute admin creation window.
        if [[ "$check_http" != "404" ]]; then
            log_info "Portainer init window expired (HTTP $check_http) - restarting..."
            docker restart portainer >/dev/null 2>&1
            wait_for_service "Portainer" "$portainer_url"
        fi

        # Capture the response body so we can give a specific error when
        # Portainer rejects the password (its 12-char minimum is enforced
        # at this endpoint and the bare HTTP code doesn't say which rule
        # failed). validate_admin_password ALSO requires 12 chars, so this
        # path is normally unreachable — but a user who ran an older
        # wizard with an 8-char password and re-ran configure.sh would
        # hit it without an obvious diagnosis otherwise.
        local init_resp init_http init_body_resp
        init_resp=$(curl -s -w "\n%{http_code}" -X POST \
            "$portainer_url/api/users/admin/init" \
            -H "Content-Type: application/json" \
            -d "$init_body")
        init_http=$(echo "$init_resp" | tail -1)
        init_body_resp=$(echo "$init_resp" | sed '$d')

        case "$init_http" in
            200) log_ok "Portainer admin created (username: $admin_user, shared password)" ;;
            409) log_skip "Portainer admin already exists" ;;
            400)
                if [[ "$init_body_resp" == *"Password does not meet the requirements"* ]]; then
                    log_warn "Portainer rejected the admin password: it requires 12+ characters. Re-run setup.sh with a longer password to enable Portainer."
                else
                    log_warn "Portainer admin creation returned HTTP 400: $init_body_resp"
                fi
                ;;
            *)   log_warn "Portainer admin creation returned HTTP $init_http: $init_body_resp" ;;
        esac
    fi

    # Create local Docker endpoint so Portainer can see containers without
    # requiring the user to complete the web-UI wizard.
    local jwt endpoints_json endpoint_count
    jwt=$(curl -s -X POST "$portainer_url/api/auth" \
        -H "Content-Type: application/json" \
        -d "$init_body" 2>/dev/null \
        | json_get jwt)

    if [[ -z "$jwt" && "$admin_user" != "admin" ]]; then
        local legacy_body legacy_jwt
        legacy_body=$(ADMIN_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"Username": "admin", "Password": os.environ["ADMIN_PW"]}))')
        legacy_jwt=$(curl -s -X POST "$portainer_url/api/auth" \
            -H "Content-Type: application/json" \
            -d "$legacy_body" 2>/dev/null \
            | json_get jwt)

        if [[ -n "$legacy_jwt" ]]; then
            local rename_body rename_resp rename_http rename_body_resp
            rename_body=$(ADMIN_USER="$admin_user" python3 -c '
import os, json
print(json.dumps({"Username": os.environ["ADMIN_USER"], "Role": 1}))')
            rename_resp=$(curl -s -w "\n%{http_code}" -X PUT \
                "$portainer_url/api/users/1" \
                -H "Authorization: Bearer $legacy_jwt" \
                -H "Content-Type: application/json" \
                -d "$rename_body")
            rename_http=$(echo "$rename_resp" | tail -1)
            rename_body_resp=$(echo "$rename_resp" | sed '$d')

            if [[ "$rename_http" == "200" ]]; then
                log_ok "Portainer admin username updated to $admin_user"
                jwt=$(curl -s -X POST "$portainer_url/api/auth" \
                    -H "Content-Type: application/json" \
                    -d "$init_body" 2>/dev/null \
                    | json_get jwt)
                jwt="${jwt:-$legacy_jwt}"
            else
                log_warn "Portainer admin username update returned HTTP $rename_http: $rename_body_resp"
                jwt="$legacy_jwt"
            fi
        fi
    fi

    if [[ -n "$jwt" ]]; then
        endpoints_json=$(curl -s "$portainer_url/api/endpoints" \
            -H "Authorization: Bearer $jwt" 2>/dev/null)
        endpoint_count=$(echo "$endpoints_json" \
            | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read())))' 2>/dev/null)

        # Create persistent API token for Homepage widget (idempotent).
        # rawAPIKey is only returned at creation time, so if PORTAINER_API_KEY
        # is already set and valid, skip.
        local existing_ptkey="${PORTAINER_API_KEY:-}"
        local ptkey_valid=""
        if [[ -n "$existing_ptkey" ]]; then
            if curl -sf "$portainer_url/api/endpoints" \
                -H "X-API-Key: $existing_ptkey" >/dev/null 2>&1; then
                ptkey_valid=1
            fi
        fi
        if [[ -z "$ptkey_valid" ]]; then
            local token_body token_resp token_raw
            token_body=$(ADMIN_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"description": "Homepage", "password": os.environ["ADMIN_PW"]}))')
            token_resp=$(curl -s -X POST "$portainer_url/api/users/1/tokens" \
                -H "Authorization: Bearer $jwt" \
                -H "Content-Type: application/json" \
                -d "$token_body" 2>/dev/null)
            token_raw=$(echo "$token_resp" | json_get rawAPIKey)
            if [[ -n "$token_raw" ]]; then
                save_api_key "PORTAINER_API_KEY" "$token_raw"
            fi
        fi

        if [[ "$endpoint_count" == "0" ]]; then
            local ep_http
            ep_http=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                "$portainer_url/api/endpoints" \
                -H "Authorization: Bearer $jwt" \
                -d "Name=local&EndpointCreationType=1" 2>/dev/null)
            case "$ep_http" in
                200|201) log_ok "Portainer local Docker endpoint created" ;;
                *)       log_warn "Portainer endpoint creation returned HTTP $ep_http" ;;
            esac
        else
            log_skip "Portainer already has $endpoint_count endpoint(s)"
        fi
    else
        log_warn "Portainer authentication did not return a JWT; endpoint/API-token setup skipped. If Portainer was changed manually, reset its admin username/password to match the shared MediaStack credentials."
    fi
}

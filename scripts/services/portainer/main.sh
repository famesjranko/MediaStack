# =============================================================================
# 7. Portainer CE — create admin user with shared password
# =============================================================================
# Portainer CE locks itself if no admin is created within 5 minutes of first
# start. An unreadable admin check must not authorize a restart or creation.

configure_portainer() {
    echo ""
    echo -e "${BOLD}Configuring Portainer...${NC}"

    local portainer_url
    portainer_url="$(service_local_url portainer)"
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
    #   other = unknown       → stop before changing state
    local check_http
    check_http=$(http_curl -s -o /dev/null -w "%{http_code}" \
        "$portainer_url/api/users/admin/check" 2>/dev/null) || check_http=000
    if [[ "$check_http" != 204 && "$check_http" != 404 ]]; then
        log_warn "Could not verify Portainer admin state (HTTP $check_http); setup stopped. If the initial setup window expired, restart Portainer and re-run setup."
        return 1
    fi

    local admin_exists=false
    if [[ "$check_http" == "204" ]]; then
        log_skip "Portainer admin already initialized"
        admin_exists=true
    fi

    local init_body
    init_body=$(http_json_body Username "$admin_user" Password "$admin_pw")

    if [[ "$admin_exists" == "false" ]]; then
        # Newer Portainer versions require X-Setup-Token (printed to container
        # logs at startup) on the admin/init endpoint. Extract it from logs;
        # older versions without this requirement ignore the extra header.
        local setup_token
        setup_token=$(docker logs portainer 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | grep -o 'setup_token=[a-zA-Z0-9]*' | tail -1 | cut -d= -f2 || true)

        # Capture the response body so we can give a specific error when
        # Portainer rejects the password (its 12-char minimum is enforced
        # at this endpoint and the bare HTTP code doesn't say which rule
        # failed). validate_admin_password enforces the same floor, so this
        # path is normally unreachable — but kept for defence against a
        # user who bypassed the wizard (e.g. edited .env directly).
        local -a init_curl_args=(-s -w "\n%{http_code}" -X POST
            "$portainer_url/api/users/admin/init"
            -H "Content-Type: application/json")
        local init_resp init_http init_body_resp
        if [[ -n "$setup_token" ]]; then
            init_resp=$(curl_header_data_stdin "X-Setup-Token" "$setup_token" "$init_body" "${init_curl_args[@]}")
        else
            init_resp=$(curl_data_stdin "$init_body" "${init_curl_args[@]}")
        fi
        init_http=$(echo "$init_resp" | tail -1)
        init_body_resp=$(echo "$init_resp" | sed '$d')

        case "$init_http" in
            200) log_ok "Portainer admin created (username: $admin_user, shared password)" ;;
            409) log_skip "Portainer admin already exists" ;;
            400)
                if [[ "$init_body_resp" == *"Password does not meet the requirements"* ]]; then
                    log_warn "Portainer rejected the admin password: it requires 12+ characters. Choose Install MediaStack from the menu and enter a longer password to enable Portainer."
                else
                    log_warn "Portainer admin creation returned HTTP 400: $init_body_resp"
                fi
                ;;
            *) log_warn "Portainer admin creation returned HTTP $init_http: $init_body_resp" ;;
        esac
    fi

    # Create local Docker endpoint so Portainer can see containers without
    # requiring the user to complete the web-UI wizard.
    local jwt endpoints_json endpoint_count
    local auth_response auth_rc=0
    auth_response=$(http_json_request "Portainer login" POST "$portainer_url/api/auth" "$init_body" "" "" jwt:string) || auth_rc=$?
    if ((auth_rc == 2)); then
        log_warn "Portainer authentication returned an incomplete response; endpoint/API-token setup skipped"
        return 1
    fi
    jwt=""
    if ((auth_rc == 0)); then jwt=$(json_get jwt <<<"$auth_response") || return 1; fi

    if [[ -z "$jwt" && "$admin_user" != "admin" ]]; then
        local legacy_body legacy_jwt
        legacy_body=$(http_json_body Username admin Password "$admin_pw")
        auth_response=$(http_json_request "Portainer legacy login" POST "$portainer_url/api/auth" "$legacy_body" "" "" jwt:string) || return 1
        legacy_jwt=$(json_get jwt <<<"$auth_response") || return 1

        if [[ -n "$legacy_jwt" ]]; then
            local rename_body rename_resp rename_http rename_body_resp
            rename_body=$(http_json_obj Username str "$admin_user" Role int 1)
            rename_resp=$(curl_header_data_stdin "Authorization" "Bearer $legacy_jwt" "$rename_body" \
                -s -w "\n%{http_code}" -X PUT \
                "$portainer_url/api/users/1" \
                -H "Content-Type: application/json")
            rename_http=$(echo "$rename_resp" | tail -1)
            rename_body_resp=$(echo "$rename_resp" | sed '$d')

            if [[ "$rename_http" == "200" ]]; then
                log_ok "Portainer admin username updated to $admin_user"
                auth_response=$(http_json_request "Portainer renamed login" POST "$portainer_url/api/auth" "$init_body" "" "" jwt:string) || return 1
                jwt=$(json_get jwt <<<"$auth_response") || return 1
                jwt="${jwt:-$legacy_jwt}"
            else
                log_warn "Portainer admin username update returned HTTP $rename_http: $rename_body_resp"
                jwt="$legacy_jwt"
            fi
        fi
    fi

    if [[ -n "$jwt" ]]; then
        endpoints_json=$(http_json_request "Portainer endpoints" GET "$portainer_url/api/endpoints" "" Authorization "Bearer $jwt" :array '[].Id:integer') || return 1
        endpoint_count=$(echo "$endpoints_json" \
            | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read())))' 2>/dev/null)

        # Create persistent API token for Homepage widget (idempotent).
        # rawAPIKey is only returned at creation time, so if PORTAINER_API_KEY
        # is already set and valid, skip.
        local existing_ptkey="${PORTAINER_API_KEY:-}"
        local ptkey_valid=""
        if [[ -n "$existing_ptkey" ]]; then
            local key_probe key_code key_body
            key_probe=$(curl_header_stdin "X-API-Key" "$existing_ptkey" -sS -w "\n%{http_code}" "$portainer_url/api/endpoints") || {
                log_warn "Could not verify Portainer API key"
                return 1
            }
            key_code=$(tail -n1 <<<"$key_probe")
            key_body=$(sed '$d' <<<"$key_probe")
            case "$key_code" in
                200)
                    json_check "Portainer API-key endpoints" :array '[].Id:integer' <<<"$key_body" || return 1
                    ptkey_valid=1
                    ;;
                401 | 403) ;; # Explicit rejection permits replacing this key.
                *)
                    log_warn "Could not verify Portainer API key (HTTP $key_code)"
                    return 1
                    ;;
            esac
        fi
        if [[ -z "$ptkey_valid" ]]; then
            local token_body token_resp token_raw
            token_body=$(http_json_body description Homepage password "$admin_pw")
            token_resp=$(http_json_request "Portainer API token" POST "$portainer_url/api/users/1/tokens" "$token_body" Authorization "Bearer $jwt" rawAPIKey:string) || return 1
            token_raw=$(echo "$token_resp" | json_get rawAPIKey) || return 1
            if [[ -n "$token_raw" ]]; then
                env_save_api_key "PORTAINER_API_KEY" "$token_raw"
            fi
        fi

        if [[ "$endpoint_count" == "0" ]]; then
            local ep_http
            ep_http=$(curl_header_data_stdin "Authorization" "Bearer $jwt" "Name=local&EndpointCreationType=1" \
                -s -o /dev/null -w "%{http_code}" -X POST \
                "$portainer_url/api/endpoints" 2>/dev/null)
            case "$ep_http" in
                200 | 201) log_ok "Portainer local Docker endpoint created" ;;
                *) log_warn "Portainer endpoint creation returned HTTP $ep_http" ;;
            esac
        else
            log_skip "Portainer already has $endpoint_count endpoint(s)"
        fi
    else
        log_warn "Portainer authentication did not return a JWT; endpoint/API-token setup skipped. If Portainer was changed manually, reset its admin username/password to match the shared MediaStack credentials."
    fi
}

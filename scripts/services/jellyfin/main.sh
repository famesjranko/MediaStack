# =============================================================================
# 5. Jellyfin — first-run wizard (admin user, libraries) or re-auth on rerun
# =============================================================================

_JELLYFIN_SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_JELLYFIN_SERVICE_DIR/wizard.sh"
source "$_JELLYFIN_SERVICE_DIR/encoding.sh"
source "$_JELLYFIN_SERVICE_DIR/server.sh"
source "$_JELLYFIN_SERVICE_DIR/network.sh"

configure_jellyfin() {
    echo ""
    echo -e "${BOLD}Configuring Jellyfin...${NC}"

    local jf_url
    jf_url="$(service_local_url jellyfin)"
    local jf_user="${JELLYFIN_ADMIN_USER:-admin}"
    local jf_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$jf_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set in .env - skipping"
        return 0
    fi

    local auth_header="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\""

    # Check if setup wizard is still pending
    local startup_info
    startup_info=$(curl -sf "$jf_url/Startup/Configuration" 2>/dev/null || echo "")

    # Auth body is JSON-safe regardless of what's in jf_user/jf_pw — python's
    # json.dumps escapes quotes, backslashes, and control chars. The previous
    # envsubst-into-template pattern was unsafe for passwords containing " or \.
    local auth_body
    auth_body=$(json_body Username "$jf_user" Pw "$jf_pw")

    if [[ -z "$startup_info" ]]; then
        # Wizard already completed — wait for the auth subsystem to become
        # ready (it lags /health by several seconds after a container
        # recreate while SQLite WAL replays), then authenticate.
        log_info "Jellyfin wizard already completed, authenticating..."
        local auth_result jf_token
        auth_result=$(wait_for_jellyfin_auth "$jf_url" "$auth_header" "$auth_body" 30)
        case $? in
            0)
                jf_token=$(echo "$auth_result" | json_get AccessToken)
                log_ok "Authenticated as $jf_user"
                save_jellyfin_api_key "$jf_url" "$jf_token" "$auth_header"
                configure_jellyfin_server_name "$jf_url" "$jf_token"
                if declare -F storage_is_manual >/dev/null && storage_is_manual; then
                    log_skip "Jellyfin libraries skipped (manual app wiring)"
                else
                    configure_jellyfin_libraries "$jf_url" "$jf_token"
                fi
                configure_jellyfin_encoding "$jf_url" "$jf_token"
                configure_jellyfin_streaming "$jf_url" "$jf_token"
                configure_jellyfin_networking "$jf_url" "$jf_token"
                ;;
            2)
                log_warn "Jellyfin rejected JELLYFIN_ADMIN_PASSWORD from .env - verify the password matches what Jellyfin has stored."
                ;;
            *)
                log_warn "Jellyfin auth subsystem did not become ready within 30s - skipping configuration."
                ;;
        esac
        return 0
    fi

    # --- Run the startup wizard ---
    log_info "Running Jellyfin first-time setup..."

    # Each sub-step uses http_check: a non-2xx aborts with an actionable error
    # rather than silently logging [OK]. Previously all four were fire-and-
    # forget (curl -sf >/dev/null 2>&1) so a silently-rejected user-creation
    # POST produced a "successful" install with a broken admin account.
    http_check "Jellyfin /Startup/Configuration" \
        -X POST "$jf_url/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d "@$SCRIPT_DIR/scripts/services/jellyfin/templates/startup-config.json" \
        >/dev/null || return 1
    log_ok "Server configuration set"

    # GET /Startup/User first: this triggers UserManager.InitializeAsync() which
    # creates the initial "root" user. POST /Startup/User is UPDATE-only — it
    # calls .First() on the user collection and silently no-ops (returning 204)
    # if none exists yet. Without this GET, the subsequent POST claims success
    # but the admin is never persisted.
    http_check "Jellyfin /Startup/User (init)" "$jf_url/Startup/User" >/dev/null || return 1

    # User body built via json_body so passwords with " \ or control chars are
    # properly escaped instead of breaking the JSON payload.
    local startup_user_body
    startup_user_body=$(json_body Name "$jf_user" Password "$jf_pw")
    http_check "Jellyfin /Startup/User (create admin)" \
        -X POST "$jf_url/Startup/User" \
        -H "Content-Type: application/json" \
        -d "$startup_user_body" \
        >/dev/null || return 1

    http_check "Jellyfin /Startup/RemoteAccess" \
        -X POST "$jf_url/Startup/RemoteAccess" \
        -H "Content-Type: application/json" \
        -d "@$SCRIPT_DIR/scripts/services/jellyfin/templates/remote-access.json" \
        >/dev/null || return 1

    http_check "Jellyfin /Startup/Complete" \
        -X POST "$jf_url/Startup/Complete" \
        -H "Content-Type: application/json" \
        >/dev/null || return 1

    # Verify the wizard actually created a working admin. The startup-wizard
    # admin is IsHidden=true so /Users/Public can't see it — authenticating is
    # the reliable check. Also: auth only works after /Startup/Complete, which
    # is why this verification runs last. If it fails, the Jellyfin image has
    # a broken startup wizard and manual intervention is required.
    sleep 2
    local auth_result
    auth_result=$(curl -sf -X POST "$jf_url/Users/AuthenticateByName" \
        -H "Authorization: $auth_header" \
        -H "Content-Type: application/json" \
        -d "$auth_body" 2>/dev/null || echo "")
    local jf_token
    jf_token=$(echo "$auth_result" | json_get AccessToken)

    if [[ -z "$jf_token" ]]; then
        log_error "Jellyfin wizard completed but admin credentials do not authenticate."
        log_error "This means the Jellyfin image's startup wizard is not working as expected."
        log_error "To recover: stop the stack, delete ./config/jellyfin, and re-run setup."
        return 1
    fi
    log_ok "Admin user created: $jf_user"
    log_ok "Setup wizard completed"
    save_jellyfin_api_key "$jf_url" "$jf_token" "$auth_header"
    configure_jellyfin_server_name "$jf_url" "$jf_token"
    if declare -F storage_is_manual >/dev/null && storage_is_manual; then
        log_skip "Jellyfin libraries skipped (manual app wiring)"
    else
        configure_jellyfin_libraries "$jf_url" "$jf_token"
    fi
    configure_jellyfin_encoding "$jf_url" "$jf_token"
    configure_jellyfin_streaming "$jf_url" "$jf_token"
    configure_jellyfin_networking "$jf_url" "$jf_token"
}

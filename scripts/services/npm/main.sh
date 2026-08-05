# =============================================================================
# 8. Nginx Proxy Manager — seed admin, create proxy hosts for all services
# =============================================================================

if ! type npm_remote_hosts_ready >/dev/null 2>&1; then
    source "$SCRIPT_DIR/scripts/lib/npm-remote.sh"
fi

: "${NPM_CERT_WAIT_MAX_POLLS:=120}"
: "${NPM_CERT_WAIT_INTERVAL_SECONDS:=10}"
: "${NPM_PROXY_CONF_WAIT_MAX_POLLS:=15}"
: "${NPM_PROXY_CONF_WAIT_INTERVAL_SECONDS:=1}"
: "${NPM_HOST_IDLE_MAX_POLLS:=12}"
: "${NPM_HOST_IDLE_REQUEST_TIMEOUT_SECONDS:=3}"
: "${NPM_HOST_IDLE_SLEEP_SECONDS:=5}"
: "${NPM_HEALTH_REPAIR_MAX_ATTEMPTS:=30}"
: "${NPM_HEALTH_PROBE_TIMEOUT_SECONDS:=5}"
: "${NPM_HEALTH_REPAIR_SLEEP_SECONDS:=2}"
: "${NPM_API_READ_TIMEOUT_SECONDS:=10}"
: "${NPM_API_WRITE_TIMEOUT_SECONDS:=30}"
: "${NPM_DNS_PROPAGATION_TIMEOUT_SECONDS:=180}"
: "${NPM_DNS_PROPAGATION_INTERVAL_SECONDS:=10}"
: "${NPM_CERT_POST_TIMEOUT_SECONDS:=180}"
readonly NPM_CERT_WAIT_MAX_POLLS NPM_CERT_WAIT_INTERVAL_SECONDS
readonly NPM_PROXY_CONF_WAIT_MAX_POLLS NPM_PROXY_CONF_WAIT_INTERVAL_SECONDS
readonly NPM_HOST_IDLE_MAX_POLLS NPM_HOST_IDLE_REQUEST_TIMEOUT_SECONDS NPM_HOST_IDLE_SLEEP_SECONDS
readonly NPM_HEALTH_REPAIR_MAX_ATTEMPTS NPM_HEALTH_PROBE_TIMEOUT_SECONDS NPM_HEALTH_REPAIR_SLEEP_SECONDS
readonly NPM_API_READ_TIMEOUT_SECONDS NPM_API_WRITE_TIMEOUT_SECONDS
readonly NPM_DNS_PROPAGATION_TIMEOUT_SECONDS NPM_DNS_PROPAGATION_INTERVAL_SECONDS
readonly NPM_CERT_POST_TIMEOUT_SECONDS

source "$SCRIPT_DIR/scripts/services/npm/certs.sh"

source "$SCRIPT_DIR/scripts/services/npm/rendered.sh"
source "$SCRIPT_DIR/scripts/services/npm/health.sh"
source "$SCRIPT_DIR/scripts/services/npm/stale.sh"
source "$SCRIPT_DIR/scripts/services/npm/publication.sh"
source "$SCRIPT_DIR/scripts/services/npm/post.sh"
configure_npm() {
    echo ""
    echo -e "${BOLD}Configuring Nginx Proxy Manager...${NC}"

    local npm_api
    npm_api="$(service_local_url npm)/api"
    local npm_email="${NPM_ADMIN_EMAIL:-}"
    local npm_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$npm_email" ]]; then
        log_warn "NPM_ADMIN_EMAIL not set in .env - skipping NPM."
        return 0
    fi
    if [[ -z "$npm_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set in .env - skipping NPM."
        return 0
    fi

    # Pre-flight: heal nginx-config drift left by prior interrupted runs.
    # No-op on healthy NPM; bounded recovery (one restart max) when broken.
    _npm_ensure_healthy "$npm_email" "$npm_pw" || {
        log_error "NPM is in an unrecoverable state - aborting NPM configuration"
        return 1
    }

    # NPM ships with an EMPTY user table on first boot. The well-known
    # 'admin@example.com / changeme' pair only exists after someone completes
    # the UI first-run flow. An unauthenticated POST /api/users succeeds
    # while no users exist — we use that to seed the admin directly with
    # the rotated credentials, so defaults are never active.

    # Build the create-user body via python json.dumps so special characters in
    # the password (", \, control chars) are escaped correctly. The previous
    # envsubst-into-template pattern was unsafe because envsubst substitutes
    # literally — a password containing " would have produced invalid JSON.
    local create_body create_http
    create_body=$(NPM_EMAIL="$npm_email" NPM_PW="$npm_pw" python3 -c '
import os, json
print(json.dumps({
    "name": "Administrator",
    "nickname": "Admin",
    "email": os.environ["NPM_EMAIL"],
    "roles": ["admin"],
    "is_disabled": False,
    "auth": {"type": "password", "secret": os.environ["NPM_PW"]},
}))')
    create_http=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$npm_api/users" \
        -H "Content-Type: application/json" \
        -d "$create_body")

    if [[ "$create_http" == "201" ]]; then
        log_ok "NPM admin created: $npm_email (password from .env)"
    elif [[ "$create_http" == "404" || "$create_http" == "409" || "$create_http" == "422" ]]; then
        # User exists — NPM returns 404 (endpoint closed after first user),
        # 409 (conflict), or 422 (validation) depending on version. Try to
        # rotate from the well-known defaults. If those are also rejected, we
        # assume the admin already has non-default credentials and skip.
        log_info "NPM admin already exists (HTTP $create_http). Checking rotation..."
        local default_token
        default_token=$(curl -sf -X POST "$npm_api/tokens" \
            -H "Content-Type: application/json" \
            -d "@$SCRIPT_DIR/scripts/services/npm/templates/token-default.json" 2>/dev/null \
            | json_get token)

        if [[ -z "$default_token" ]]; then
            log_skip "NPM admin already has non-default credentials"
        else
            local user_update_body rotate_body
            user_update_body=$(http_json_body name Administrator nickname Admin email "$npm_email")
            curl -sf -X PUT "$npm_api/users/me" \
                -H "Authorization: Bearer $default_token" \
                -H "Content-Type: application/json" \
                -d "$user_update_body" \
                >/dev/null 2>&1 || true

            rotate_body=$(http_json_body type password current changeme secret "$npm_pw")
            if curl -sf -X PUT "$npm_api/users/me/auth" \
                -H "Authorization: Bearer $default_token" \
                -H "Content-Type: application/json" \
                -d "$rotate_body" \
                >/dev/null 2>&1; then
                log_ok "NPM admin rotated from defaults to credentials in .env"
            else
                log_error "NPM password rotation FAILED - default creds may still work"
                return 1
            fi
        fi
    else
        log_error "NPM admin creation failed unexpectedly (HTTP $create_http) - re-run configure.sh"
        return 1
    fi

    # Authenticate to get a token for proxy host management.
    local npm_token tokens_body
    tokens_body=$(http_json_body identity "$npm_email" secret "$npm_pw")
    npm_token=$(curl -sf -X POST "$npm_api/tokens" \
        -H "Content-Type: application/json" \
        -d "$tokens_body" 2>/dev/null \
        | json_get token)
    if [[ -n "$npm_token" ]]; then
        log_ok "Verified: NPM admin credentials accepted"
    else
        log_error "NPM credentials not accepted post-setup - defaults may still be active"
        return 1
    fi

    # --- Default landing page hardening ---
    # NPM's default "Congratulations" page leaks that NPM is in use. Switch to 404.
    local default_site_settings default_site_value
    if default_site_settings=$(api_fetch "NPM settings" \
        -H "Authorization: Bearer $npm_token" "$npm_api/settings"); then
        default_site_value=$(echo "$default_site_settings" | python3 -c '
import sys, json
for s in json.load(sys.stdin):
    if s.get("id") == "default-site":
        print(s.get("value", ""))
        break
' 2>/dev/null)
        if [[ "$default_site_value" == "congratulations" ]]; then
            local ds_body ds_http
            ds_body=$(http_json_obj value str 404 meta json '{}')
            ds_http=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "$npm_api/settings/default-site" \
                -H "Authorization: Bearer $npm_token" \
                -H "Content-Type: application/json" \
                -d "$ds_body")
            if [[ "$ds_http" =~ ^2 ]]; then
                log_ok "NPM default site: changed from 'congratulations' to '404'"
            else
                log_warn "NPM default site: PUT failed (HTTP $ds_http)"
            fi
        else
            log_skip "NPM default site: already set to '$default_site_value'"
        fi
    fi

    # --- Rate limiting zone (http{} context via NPM custom config) ---
    # Disabled by default (config.yml rate_limiting.enabled) for parity with
    # upstream. When disabled, no limit_req_zone is written here and no limit_req
    # is injected into proxy hosts (below), and the npm-ratelimit jail-verify is
    # skipped.
    local rate_enabled rate_rps rate_burst
    rate_enabled="$(cfg_field "rate_limiting.enabled" 2>/dev/null || echo "false")"
    rate_enabled="${rate_enabled,,}" # cfg_field prints Python "False"/"True"; normalize
    rate_rps=$(cfg_field "rate_limiting.requests_per_second" 2>/dev/null || echo "15")
    rate_burst=$(cfg_field "rate_limiting.burst" 2>/dev/null || echo "60")

    local http_top_dir="$SCRIPT_DIR/config/npm/data/nginx/custom"
    local http_top_file="$http_top_dir/http_top.conf"
    local expected_zone="limit_req_zone \$binary_remote_addr zone=mediastack_ratelimit:10m rate=${rate_rps}r/s;"
    local http_top_created="false"

    if [[ "$rate_enabled" != "true" ]]; then
        log_skip "NPM rate limiting: disabled (config.yml rate_limiting.enabled=false)"
        # Never delete a managed zone left by a previous enabled install: an existing
        # proxy host could still reference it, and removing it would break the nginx
        # reload. Warn only (graceful re-run / never auto-reconcile).
        if [[ -f "$http_top_file" ]] && grep -q "zone=mediastack_ratelimit" "$http_top_file" 2>/dev/null; then
            log_drift "NPM rate limiting disabled but a managed http_top.conf zone remains from a prior install - remove it manually or set rate_limiting.enabled: true"
        fi
    elif [[ -f "$http_top_file" ]]; then
        local current_content
        current_content=$(cat "$http_top_file")
        if [[ "$current_content" == "$expected_zone" ]]; then
            log_skip "NPM rate limit zone: ${rate_rps}r/s already configured"
        else
            log_drift "NPM rate limit zone: http_top.conf exists but content differs from config.yml (${rate_rps}r/s expected)"
        fi
    else
        # NPM container creates config/npm/data/nginx/ as root; fix ownership
        # so the non-root configure.sh user can write http_top.conf.
        if [[ -d "$http_top_dir" && ! -w "$http_top_dir" ]]; then
            sudo chown "$(id -u):$(id -g)" "$http_top_dir" 2>/dev/null || true
        fi
        if mkdir -p "$http_top_dir" 2>/dev/null && printf '%s\n' "$expected_zone" >"$http_top_file" 2>/dev/null; then
            http_top_created="true"
            log_ok "NPM rate limit zone: ${rate_rps}r/s (http_top.conf)"
        else
            log_warn "Could not create ${http_top_file} (permission denied?) - rate limiting disabled"
        fi
    fi

    _npm_configure_publication
    _npm_finish_configuration
}

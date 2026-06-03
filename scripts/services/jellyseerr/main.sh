# =============================================================================
# 6. Jellyseerr — bootstrap auth, sync Jellyfin libraries, connect Sonarr/Radarr
# =============================================================================

_JS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_JS_DIR/arr_connect.sh"

configure_jellyseerr() {
    echo ""
    echo -e "${BOLD}Configuring Jellyseerr...${NC}"

    local js_url="http://localhost:5055"
    local jf_user="${JELLYFIN_ADMIN_USER:-admin}"
    local jf_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$jf_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set - skipping"
        return 0
    fi

    # Determine fresh install vs re-run. mediaServerType is the reliable
    # indicator: 4 = NOT_CONFIGURED (fresh), 2 = JELLYFIN (configured).
    # The initialized flag can be stale from a previous run's settings.json
    # surviving an incomplete cleanup (e.g. container still running during
    # rm -rf recreates the file).
    local js_public media_server_type initialized
    js_public=$(curl -fsS "$js_url/api/v1/settings/public" 2>/dev/null || echo "{}")
    media_server_type=$(echo "$js_public" | json_get mediaServerType 4)
    initialized=$(echo "$js_public" | json_get initialized False)

    local is_fresh=false
    if [[ "$media_server_type" == "4" ]]; then
        is_fresh=true
        log_info "Running Jellyseerr first-time setup..."
    elif [[ "$initialized" == "True" ]]; then
        log_info "Jellyseerr already initialized — reconciling settings..."
    else
        is_fresh=true
        log_info "Running Jellyseerr first-time setup..."
    fi

    # Gate on Jellyseerr's internal init completing. The HTTP port responds
    # before API routes are fully initialized — /api/v1/auth/jellyfin returns
    # 500 during this window on slow hosts (observed on GCP e2-medium).
    local _js_ready="" _js_init_wait
    for _js_init_wait in $(seq 1 20); do
        if curl -fsS "$js_url/api/v1/settings/public" 2>/dev/null \
            | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
            _js_ready="yes"
            break
        fi
        sleep 3
    done
    [[ -z "$_js_ready" ]] && \
        log_warn "Jellyseerr API did not return valid JSON after 60s — auth may fail"

    local cookiejar auth_body auth_http auth_resp auth_msg me_resp
    cookiejar="$(mktemp)"
    auth_resp="$(mktemp)"
    me_resp="$(mktemp)"

    # Clean up temp files on all exits from this function
    cleanup_jellyseerr_tmp() {
        rm -f "$cookiejar" "$auth_resp" "$me_resp"
    }

    # First try the true bootstrap path:
    # - fresh Jellyseerr starts with mediaServerType=4 (NOT_CONFIGURED)
    # - /auth/jellyfin bootstrap needs hostname/port/useSsl/urlBase/serverType:2
    # Bodies are built via python json.dumps so passwords containing " \ or
    # control chars are properly JSON-escaped. The previous envsubst-into-
    # template pattern injected values literally and produced invalid JSON
    # when the admin password contained any JSON-special character.
    local auth_body_bootstrap auth_body_rerun
    auth_body_bootstrap=$(JF_USER="$jf_user" JF_PW="$jf_pw" python3 -c '
import os, json
print(json.dumps({
    "username": os.environ["JF_USER"],
    "password": os.environ["JF_PW"],
    "hostname": "jellyfin",
    "port": 8096,
    "useSsl": False,
    "urlBase": "",
    "serverType": 2,
}))')
    auth_body_rerun=$(JF_USER="$jf_user" JF_PW="$jf_pw" python3 -c '
import os, json
print(json.dumps({
    "username": os.environ["JF_USER"],
    "password": os.environ["JF_PW"],
    "serverType": 2,
}))')

    # Jellyseerr's auth endpoint may return 500 briefly after the web server
    # starts accepting connections (internal init not yet complete). Retry the
    # full auth sequence on 500 with backoff, up to 60s.
    local _auth_attempt
    for _auth_attempt in $(seq 1 20); do
        auth_http=$(curl -sS \
            -o "$auth_resp" \
            -w "%{http_code}" \
            -c "$cookiejar" -b "$cookiejar" \
            -H "Content-Type: application/json" \
            -X POST "$js_url/api/v1/auth/jellyfin" \
            -d "$auth_body_bootstrap" 2>/dev/null || echo "000")

        # Fallback for partial / half-configured reruns:
        # if hostname is already stored, /auth/jellyfin rejects it in the body
        # (returns 500 "hostname already configured"), so retry without hostname.
        if [[ "$auth_http" != "200" ]]; then
            auth_http=$(curl -sS \
                -o "$auth_resp" \
                -w "%{http_code}" \
                -c "$cookiejar" -b "$cookiejar" \
                -H "Content-Type: application/json" \
                -X POST "$js_url/api/v1/auth/jellyfin" \
                -d "$auth_body_rerun" 2>/dev/null || echo "000")
        fi

        [[ "$auth_http" != "500" ]] && break
        sleep 3
    done

    if [[ "$auth_http" != "200" ]]; then
        auth_msg=$(python3 - "$auth_resp" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]
try:
    with open(p, 'r', encoding='utf-8') as f:
        data=json.load(f)
    print(data.get('message') or data.get('error') or '')
except Exception:
    pass
PY
)
        if [[ -n "$auth_msg" ]]; then
            log_warn "Could not sign in to Jellyseerr ($auth_http: $auth_msg) - configure manually"
        else
            log_warn "Could not sign in to Jellyseerr ($auth_http) - configure manually"
        fi
        cleanup_jellyseerr_tmp
        return 0
    fi
    log_ok "Signed in to Jellyseerr as $jf_user"

    # Verify the session really works
    if ! curl -fsS \
        -o "$me_resp" \
        -c "$cookiejar" -b "$cookiejar" \
        "$js_url/api/v1/auth/me" >/dev/null 2>&1; then
        log_warn "Jellyseerr login succeeded but session verification failed - configure manually"
        cleanup_jellyseerr_tmp
        return 0
    fi

    # Gate on the actual endpoint Jellyseerr's sync route consumes.
    # Jellyseerr's /api/v1/settings/jellyfin/library?sync=true internally
    # calls Jellyfin's GET /Library/MediaFolders with the Jellyfin API key
    # Jellyseerr generated for itself during bootstrap. So:
    #   1) read that exact key from /api/v1/settings/jellyfin,
    #   2) poll /Library/MediaFolders with it until Movies+TV Shows appear,
    #   3) only then call sync.
    # Gating on Jellyfin's RefreshLibrary scheduled task is the wrong signal:
    # Jellyseerr never inspects scan task state.
    local jf_url="http://localhost:8096"
    local js_jf_settings js_jf_key mf_resp mf_code mf_ok i
    if ! js_jf_settings=$(api_fetch "Jellyseerr Jellyfin settings" -c "$cookiejar" -b "$cookiejar" "$js_url/api/v1/settings/jellyfin"); then
        js_jf_settings="{}"
    fi
    js_jf_key=$(echo "$js_jf_settings" | json_get apiKey)

    if [[ -n "$js_jf_key" ]]; then
        mf_resp=$(mktemp)
        mf_ok=""
        for i in $(seq 1 30); do
            mf_code=$(curl -sS -o "$mf_resp" -w "%{http_code}" \
                -H "Authorization: MediaBrowser Token=\"$js_jf_key\"" \
                "$jf_url/Library/MediaFolders" 2>/dev/null || echo "000")
            if [[ "$mf_code" == "200" ]]; then
                mf_ok=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get("Items", []) if isinstance(data, dict) else data
    names = {it.get("Name") for it in items}
    print("yes" if {"Movies", "TV Shows"}.issubset(names) else "")
except Exception:
    pass' < "$mf_resp" 2>/dev/null)
                [[ -n "$mf_ok" ]] && break
            fi
            sleep 2
        done
        if [[ -n "$mf_ok" ]]; then
            log_info "Jellyfin libraries visible to Jellyseerr after ${i}s"
        else
            log_warn "Jellyfin /Library/MediaFolders did not return Movies+TV Shows after 60s (last HTTP $mf_code)"
        fi
        rm -f "$mf_resp"
    else
        log_warn "Jellyseerr did not return apiKey from /settings/jellyfin — sync will likely fail"
    fi

    # Sync libraries. Capture HTTP code + body so real failures surface
    # (Jellyseerr returns 404 SYNC_ERROR_NO_LIBRARIES, 501
    # SYNC_ERROR_GROUPED_FOLDERS, etc — the old `|| echo "[]"` masked these).
    local libs lib_ids sync_resp sync_code
    sync_resp=$(mktemp)
    sync_code=$(curl -sS -o "$sync_resp" -w "%{http_code}" \
        -c "$cookiejar" -b "$cookiejar" \
        "$js_url/api/v1/settings/jellyfin/library?sync=true" 2>/dev/null || echo "000")
    if [[ "$sync_code" == "200" ]]; then
        libs=$(cat "$sync_resp")
    else
        libs="[]"
        log_warn "Jellyseerr sync returned HTTP $sync_code: $(head -c 300 "$sync_resp")"
    fi
    rm -f "$sync_resp"

    # NOTE: do NOT use `python3 - <<'PY'` here. The heredoc rebinds stdin to
    # the script body, so `json.load(sys.stdin)` would get EOF and silently
    # produce an empty list — that exact bug masked Jellyseerr's library sync
    # working correctly for several test runs. Use `python3 -c '…'` so the
    # `echo $libs |` pipe actually reaches sys.stdin.
    lib_ids=$(echo "$libs" | python3 -c '
import sys, json
try:
    libs = json.load(sys.stdin)
    ids = [str(x["id"]) for x in libs if x.get("id")]
    print(",".join(ids))
except Exception:
    pass' 2>/dev/null)

    if [[ -n "$lib_ids" ]]; then
        if curl -fsS \
            -c "$cookiejar" -b "$cookiejar" \
            "$js_url/api/v1/settings/jellyfin/library?enable=$lib_ids" >/dev/null 2>&1; then
            log_ok "Jellyfin libraries synced and enabled"
        else
            log_warn "Jellyfin libraries synced but could not enable them automatically"
        fi
    else
        log_warn "No Jellyfin libraries discovered by Jellyseerr"
    fi

    connect_arr_to_jellyseerr sonarr 8989 "$js_url" "$cookiejar"
    connect_arr_to_jellyseerr radarr 7878 "$js_url" "$cookiejar"

    # Mark setup complete (only on first-time setup)
    if [[ "$is_fresh" != "true" ]]; then
        log_ok "Jellyseerr reconciliation complete"
    elif curl -fsS -X POST "$js_url/api/v1/settings/initialize" \
        -H "Content-Type: application/json" \
        -c "$cookiejar" -b "$cookiejar" \
        >/dev/null 2>&1; then

        initialized=$(curl -fsS "$js_url/api/v1/settings/public" 2>/dev/null | \
            json_get initialized False)

        if [[ "$initialized" == "True" ]]; then
            log_ok "Jellyseerr setup complete"
        else
            log_warn "Jellyseerr initialize call returned success but instance still reports uninitialized"
        fi
    else
        log_warn "Failed to mark Jellyseerr setup complete"
    fi

    # Default permissions + request quotas. Non-admin users can submit requests
    # but they require admin approval (bit 32 = REQUEST only, no auto-approve).
    # Quotas prevent request spam from family members.
    local movie_limit movie_days tv_limit tv_days
    movie_limit=$(cfg_field "jellyseerr.quotas.movie.limit" 2>/dev/null || echo "10")
    movie_days=$(cfg_field "jellyseerr.quotas.movie.days" 2>/dev/null || echo "7")
    tv_limit=$(cfg_field "jellyseerr.quotas.tv.limit" 2>/dev/null || echo "10")
    tv_days=$(cfg_field "jellyseerr.quotas.tv.days" 2>/dev/null || echo "7")

    local current_settings current_perms current_movie_limit current_tv_limit
    if ! current_settings=$(api_fetch "Jellyseerr main settings" -c "$cookiejar" -b "$cookiejar" "$js_url/api/v1/settings/main"); then
        current_settings="{}"
    fi
    local js_api_key
    js_api_key=$(echo "$current_settings" | json_get apiKey)
    if [[ -n "$js_api_key" ]]; then
        save_api_key "JELLYSEERR_API_KEY" "$js_api_key"
    fi

    current_perms=$(echo "$current_settings" | json_get defaultPermissions 0)
    current_movie_limit=$(echo "$current_settings" | json_path defaultQuotas.movie.quotaLimit 0)
    current_tv_limit=$(echo "$current_settings" | json_path defaultQuotas.tv.quotaLimit 0)

    if [[ "$current_perms" == "32" && "$current_movie_limit" == "$movie_limit" && "$current_tv_limit" == "$tv_limit" ]]; then
        log_skip "Jellyseerr permissions + quotas already match config.yml"
    else
        local settings_body
        settings_body=$(python3 -c "
import json
body = {'defaultPermissions': 32}
ml, md, tl, td = int('$movie_limit'), int('$movie_days'), int('$tv_limit'), int('$tv_days')
if ml > 0 or tl > 0:
    body['defaultQuotas'] = {
        'movie': {'quotaLimit': ml, 'quotaDays': md} if ml > 0 else {},
        'tv': {'quotaLimit': tl, 'quotaDays': td} if tl > 0 else {}
    }
print(json.dumps(body))
" 2>/dev/null)
        if curl -fsS -X POST "$js_url/api/v1/settings/main" \
            -H "Content-Type: application/json" \
            -c "$cookiejar" -b "$cookiejar" \
            -d "$settings_body" >/dev/null 2>&1; then
            log_ok "Jellyseerr: admin-approval required, quotas ${movie_limit} movies/${movie_days}d + ${tv_limit} TV/${tv_days}d"
        else
            log_warn "Failed to set Jellyseerr permissions/quotas"
        fi
    fi

    cleanup_jellyseerr_tmp
}

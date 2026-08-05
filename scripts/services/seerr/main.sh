# =============================================================================
# 6. Seerr — bootstrap auth, sync Jellyfin libraries, connect Sonarr/Radarr
# =============================================================================

_SEERR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SEERR_DIR/arr-connect.sh"

configure_seerr() {
    echo ""
    echo -e "${BOLD}Configuring Seerr...${NC}"

    local seerr_url
    seerr_url="$(service_local_url seerr)"
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
    local seerr_public media_server_type initialized
    seerr_public=$(curl -fsS "$seerr_url/api/v1/settings/public" 2>/dev/null || echo "{}")
    media_server_type=$(echo "$seerr_public" | json_get mediaServerType 4)
    initialized=$(echo "$seerr_public" | json_get initialized False)

    local is_fresh=false
    if [[ "$media_server_type" == "4" ]]; then
        is_fresh=true
        log_info "Running Seerr first-time setup..."
    elif [[ "$initialized" == "True" ]]; then
        log_info "Seerr already initialized - reconciling settings..."
    else
        is_fresh=true
        log_info "Running Seerr first-time setup..."
    fi

    # Gate on Seerr's internal init completing. The HTTP port responds
    # before API routes are fully initialized — /api/v1/auth/jellyfin returns
    # 500 during this window on slow hosts (observed on GCP e2-medium).
    local _seerr_ready="" _seerr_init_wait
    for _seerr_init_wait in $(seq 1 20); do
        if curl -fsS "$seerr_url/api/v1/settings/public" 2>/dev/null \
            | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
            _seerr_ready="yes"
            break
        fi
        sleep 3
    done
    [[ -z "$_seerr_ready" ]] \
        && log_warn "Seerr API did not return valid JSON after 60s - auth may fail"

    local cookiejar auth_http auth_resp auth_msg me_resp
    cookiejar="$(mktemp)"
    auth_resp="$(mktemp)"
    me_resp="$(mktemp)"

    # Clean up temp files on all exits from this function
    cleanup_seerr_tmp() {
        rm -f "$cookiejar" "$auth_resp" "$me_resp"
    }

    # First try the true bootstrap path:
    # - fresh Seerr starts with mediaServerType=4 (NOT_CONFIGURED)
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

    # Seerr's auth endpoint may return 500 briefly after the web server
    # starts accepting connections (internal init not yet complete). Retry the
    # full auth sequence on 500 with backoff, up to 60s.
    local _auth_attempt
    for _auth_attempt in $(seq 1 20); do
        auth_http=$(curl -sS \
            -o "$auth_resp" \
            -w "%{http_code}" \
            -c "$cookiejar" -b "$cookiejar" \
            -H "Content-Type: application/json" \
            -X POST "$seerr_url/api/v1/auth/jellyfin" \
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
                -X POST "$seerr_url/api/v1/auth/jellyfin" \
                -d "$auth_body_rerun" 2>/dev/null || echo "000")
        fi

        [[ "$auth_http" != "500" ]] && break
        sleep 3
    done

    if [[ "$auth_http" != "200" ]]; then
        auth_msg=$(
            python3 - "$auth_resp" <<'PY' 2>/dev/null || true
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
            log_warn "Could not sign in to Seerr ($auth_http: $auth_msg) - configure manually"
        else
            log_warn "Could not sign in to Seerr ($auth_http) - configure manually"
        fi
        cleanup_seerr_tmp
        return 0
    fi
    log_ok "Signed in to Seerr as $jf_user"

    # Verify the session really works
    if ! curl -fsS \
        -o "$me_resp" \
        -c "$cookiejar" -b "$cookiejar" \
        "$seerr_url/api/v1/auth/me" >/dev/null 2>&1; then
        log_warn "Seerr login succeeded but session verification failed - configure manually"
        cleanup_seerr_tmp
        return 0
    fi

    # Gate on the actual endpoint Seerr's sync route consumes.
    # Seerr's /api/v1/settings/jellyfin/library?sync=true internally
    # calls Jellyfin's GET /Library/MediaFolders with the Jellyfin API key
    # Seerr generated for itself during bootstrap. So:
    #   1) read that exact key from /api/v1/settings/jellyfin,
    #   2) poll /Library/MediaFolders with it until Movies+TV Shows appear,
    #   3) only then call sync.
    # Gating on Jellyfin's RefreshLibrary scheduled task is the wrong signal:
    # Seerr never inspects scan task state.
    local jf_url
    jf_url="$(service_local_url jellyfin)"
    local seerr_jf_settings seerr_jf_key mf_resp mf_code mf_ok i
    if ! seerr_jf_settings=$(api_fetch "Seerr Jellyfin settings" -c "$cookiejar" -b "$cookiejar" "$seerr_url/api/v1/settings/jellyfin"); then
        seerr_jf_settings="{}"
    fi
    seerr_jf_key=$(echo "$seerr_jf_settings" | json_get apiKey)

    if [[ -n "$seerr_jf_key" ]]; then
        mf_resp=$(mktemp)
        mf_ok=""
        for i in $(seq 1 30); do
            mf_code=$(curl -sS -o "$mf_resp" -w "%{http_code}" \
                -H "Authorization: MediaBrowser Token=\"$seerr_jf_key\"" \
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
    pass' <"$mf_resp" 2>/dev/null)
                [[ -n "$mf_ok" ]] && break
            fi
            sleep 2
        done
        if [[ -n "$mf_ok" ]]; then
            log_info "Jellyfin libraries visible to Seerr after ${i}s"
        else
            log_warn "Jellyfin /Library/MediaFolders did not return Movies+TV Shows after 60s (last HTTP $mf_code)"
        fi
        rm -f "$mf_resp"
    else
        log_warn "Seerr did not return apiKey from /settings/jellyfin - sync will likely fail"
    fi

    # Sync libraries. Capture HTTP code + body so real failures surface
    # (Seerr returns 404 SYNC_ERROR_NO_LIBRARIES, 501
    # SYNC_ERROR_GROUPED_FOLDERS, etc — the old `|| echo "[]"` masked these).
    local libs lib_ids sync_resp sync_code
    sync_resp=$(mktemp)
    sync_code=$(curl -sS -o "$sync_resp" -w "%{http_code}" \
        -c "$cookiejar" -b "$cookiejar" \
        "$seerr_url/api/v1/settings/jellyfin/library?sync=true" 2>/dev/null || echo "000")
    if [[ "$sync_code" == "200" ]]; then
        libs=$(cat "$sync_resp")
    else
        libs="[]"
        log_warn "Seerr sync returned HTTP $sync_code: $(head -c 300 "$sync_resp")"
    fi
    rm -f "$sync_resp"

    # NOTE: do NOT use `python3 - <<'PY'` here. The heredoc rebinds stdin to
    # the script body, so `json.load(sys.stdin)` would get EOF and silently
    # produce an empty list — that exact bug masked Seerr's library sync
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
            "$seerr_url/api/v1/settings/jellyfin/library?enable=$lib_ids" >/dev/null 2>&1; then
            log_ok "Jellyfin libraries synced and enabled"
        else
            log_warn "Jellyfin libraries synced but could not enable them automatically"
        fi
    else
        log_warn "No Jellyfin libraries discovered by Seerr"
    fi

    connect_arr_to_seerr sonarr 8989 "$seerr_url" "$cookiejar"
    connect_arr_to_seerr radarr 7878 "$seerr_url" "$cookiejar"

    # Mark setup complete (only on first-time setup)
    if [[ "$is_fresh" != "true" ]]; then
        log_ok "Seerr reconciliation complete"
    elif curl -fsS -X POST "$seerr_url/api/v1/settings/initialize" \
        -H "Content-Type: application/json" \
        -c "$cookiejar" -b "$cookiejar" \
        >/dev/null 2>&1; then

        initialized=$(curl -fsS "$seerr_url/api/v1/settings/public" 2>/dev/null \
            | json_get initialized False)

        if [[ "$initialized" == "True" ]]; then
            log_ok "Seerr setup complete"
        else
            log_warn "Seerr initialize call returned success but instance still reports uninitialized"
        fi
    else
        log_warn "Failed to mark Seerr setup complete"
    fi

    # Default permissions + request quotas. Non-admin users can submit requests
    # but they require admin approval (bit 32 = REQUEST only, no auto-approve).
    # Quotas prevent request spam from family members.
    local movie_limit movie_days tv_limit tv_days
    movie_limit=$(cfg_field "seerr.quotas.movie.limit" 2>/dev/null || echo "10")
    movie_days=$(cfg_field "seerr.quotas.movie.days" 2>/dev/null || echo "7")
    tv_limit=$(cfg_field "seerr.quotas.tv.limit" 2>/dev/null || echo "10")
    tv_days=$(cfg_field "seerr.quotas.tv.days" 2>/dev/null || echo "7")

    local current_settings current_perms current_movie_limit current_tv_limit
    if ! current_settings=$(api_fetch "Seerr main settings" -c "$cookiejar" -b "$cookiejar" "$seerr_url/api/v1/settings/main"); then
        current_settings="{}"
    fi
    local seerr_api_key
    seerr_api_key=$(echo "$current_settings" | json_get apiKey)
    if [[ -n "$seerr_api_key" ]]; then
        save_api_key "SEERR_API_KEY" "$seerr_api_key"
    fi

    current_perms=$(echo "$current_settings" | json_get defaultPermissions 0)
    current_movie_limit=$(echo "$current_settings" | json_path defaultQuotas.movie.quotaLimit 0)
    current_tv_limit=$(echo "$current_settings" | json_path defaultQuotas.tv.quotaLimit 0)

    if [[ "$current_perms" == "32" && "$current_movie_limit" == "$movie_limit" && "$current_tv_limit" == "$tv_limit" ]]; then
        log_skip "Seerr permissions + quotas already match config.yml"
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
        if curl -fsS -X POST "$seerr_url/api/v1/settings/main" \
            -H "Content-Type: application/json" \
            -c "$cookiejar" -b "$cookiejar" \
            -d "$settings_body" >/dev/null 2>&1; then
            log_ok "Seerr: admin-approval required, quotas ${movie_limit} movies/${movie_days}d + ${tv_limit} TV/${tv_days}d"
        else
            log_warn "Failed to set Seerr permissions/quotas"
        fi
    fi

    # ----------------------------------------------------------------------
    # Trust the NPM reverse proxy so Seerr reads the real client IP from
    # X-Forwarded-For (the app-side counterpart to Jellyfin's KnownProxies).
    # Enable it ONLY when remote access via NPM is configured: on a LAN/direct
    # install Seerr is reached at host:5055 with no proxy in front, so
    # trusting forwarded headers would let any direct client spoof its IP.
    # We reconcile trustProxy to that topology-correct value on every run (like
    # the permissions/quotas block above) rather than warn-on-drift like
    # KnownProxies: trustProxy is a single boolean, so we can't tell a user's
    # deliberate off from never-set — the architecture requires it on behind NPM,
    # so it's ensured. trustProxy lives in settings.network (NOT settings.main)
    # and is read at Express startup, so a restart is required to apply it.
    local want_trust=false
    if [[ "${REMOTE_WEB_STATE:-}" == "ready" && -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then
        want_trust=true
    fi

    local seerr_net_settings cur_trust cur_trust_norm seerr_trust_changed=false
    if ! seerr_net_settings=$(api_fetch "Seerr network settings" -c "$cookiejar" -b "$cookiejar" "$seerr_url/api/v1/settings/network"); then
        seerr_net_settings="{}"
    fi
    cur_trust=$(echo "$seerr_net_settings" | json_get trustProxy False)
    cur_trust_norm=false
    [[ "$cur_trust" =~ ^(True|true)$ ]] && cur_trust_norm=true

    if [[ "$cur_trust_norm" == "$want_trust" ]]; then
        log_skip "Seerr trustProxy already $want_trust"
    else
        local net_body
        net_body=$(json_obj trustProxy bool "$want_trust")
        if curl -fsS -X POST "$seerr_url/api/v1/settings/network" \
            -H "Content-Type: application/json" \
            -c "$cookiejar" -b "$cookiejar" \
            -d "$net_body" >/dev/null 2>&1; then
            log_ok "Seerr trustProxy set to $want_trust (reads real client IP behind NPM)"
            seerr_trust_changed=true
        else
            log_warn "Failed to set Seerr trustProxy"
        fi
    fi

    # trustProxy is applied at Express startup — restart so it takes effect
    # (best-effort, mirrors the Jellyfin KnownProxies restart). Placed last:
    # nothing after the settings POSTs uses the cookie session.
    if [[ "$seerr_trust_changed" == "true" ]]; then
        log_info "Restarting Seerr for trustProxy to take effect..."
        if ! docker compose restart seerr >/dev/null 2>&1; then
            log_warn "Failed to restart Seerr - view logs from the menu: Manage stack -> Tail logs (live)"
        else
            post_restart_wait "$seerr_url/api/v1/settings/public" \
                || log_warn "Seerr did not become healthy within 60s after restart - check 'docker logs seerr'"
        fi
    fi

    cleanup_seerr_tmp
}

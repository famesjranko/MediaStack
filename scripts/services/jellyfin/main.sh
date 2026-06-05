# =============================================================================
# 5. Jellyfin — first-run wizard (admin user, libraries) or re-auth on rerun
# =============================================================================

configure_jellyfin() {
    echo ""
    echo -e "${BOLD}Configuring Jellyfin...${NC}"

    local jf_url="http://localhost:8096"
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

# Create (or reuse) a permanent Jellyfin API key and save it to .env.
# Session tokens from AuthenticateByName are transient and change every run;
# a permanent key (POST /Auth/Keys) persists across restarts and re-runs.
save_jellyfin_api_key() {
    local jf_url="$1" session_token="$2" auth_header="$3"
    local auth="$auth_header, Token=\"$session_token\""

    # Check if a MediaStack key already exists
    local existing_key
    existing_key=$(curl -sf "$jf_url/Auth/Keys" -H "Authorization: $auth" 2>/dev/null \
        | python3 -c "
import sys,json
items = json.load(sys.stdin).get('Items',[])
keys = [k['AccessToken'] for k in items if k.get('AppName')=='MediaStack']
print(keys[0] if keys else '')" 2>/dev/null || echo "")

    if [[ -n "$existing_key" ]]; then
        save_api_key "JELLYFIN_API_KEY" "$existing_key"
        return 0
    fi

    # Create a new permanent key
    curl -sf -X POST "$jf_url/Auth/Keys?app=MediaStack" \
        -H "Authorization: $auth" >/dev/null 2>&1

    local new_key
    new_key=$(curl -sf "$jf_url/Auth/Keys" -H "Authorization: $auth" 2>/dev/null \
        | python3 -c "
import sys,json
items = json.load(sys.stdin).get('Items',[])
keys = [k['AccessToken'] for k in items if k.get('AppName')=='MediaStack']
print(keys[0] if keys else '')" 2>/dev/null || echo "")

    if [[ -n "$new_key" ]]; then
        save_api_key "JELLYFIN_API_KEY" "$new_key"
    else
        log_warn "Could not create permanent Jellyfin API key, saving session token"
        save_api_key "JELLYFIN_API_KEY" "$session_token"
    fi
}

configure_jellyfin_libraries() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local existing_libs
    if ! existing_libs=$(api_fetch "Jellyfin libraries" "$jf_url/Library/VirtualFolders" -H "Authorization: $auth"); then
        existing_libs="[]"
    fi

    # Add libraries from config.yml. On re-run with an existing library whose
    # path has drifted, warn but do not re-root — Jellyfin has no path-rename
    # endpoint and DELETE drops watch history.
    while IFS=: read -r lib_name lib_type lib_path; do
        local lib_status
        lib_status=$(echo "$existing_libs" | WANT_NAME="$lib_name" WANT_PATH="$lib_path" python3 -c '
import sys, json, os
name = os.environ["WANT_NAME"]
want = os.environ["WANT_PATH"]
try: items = json.load(sys.stdin)
except Exception: items = []
lib = next((l for l in items if l.get("Name") == name), None)
if lib is None:
    print("absent")
else:
    live = (lib.get("Locations") or [""])[0]
    print("match" if live == want else "drift\t" + live)
' 2>/dev/null)
        case "${lib_status%%$'\t'*}" in
            match)
                log_skip "Jellyfin library '$lib_name' already matches config.yml"
                continue
                ;;
            drift)
                log_warn "Jellyfin library '$lib_name' path differs from config.yml (live=${lib_status#*$'\t'}, config.yml=$lib_path). Jellyfin cannot re-root a library without losing watch history. To migrate: Jellyfin UI -> Dashboard -> Libraries -> delete '$lib_name' and re-run configure.sh (accepts history loss), or rebuild (docker compose down -v && ./setup.sh --full)."
                continue
                ;;
        esac

        local encoded_name library_body
        encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$lib_name'))")
        library_body=$(LIB_PATH="$lib_path" python3 -c '
import os, json
print(json.dumps({
    "LibraryOptions": {
        "EnableRealtimeMonitor": True,
        "EnablePhotos": False,
        "EnableChapterImageExtraction": False,
        "PathInfos": [{"Path": os.environ["LIB_PATH"]}],
    },
}))')
        if curl -sf -X POST "$jf_url/Library/VirtualFolders?name=${encoded_name}&collectionType=${lib_type}&refreshLibrary=false" \
            -H "Authorization: $auth" \
            -H "Content-Type: application/json" \
            -d "$library_body" \
            >/dev/null 2>&1; then
            log_ok "Library: $lib_name ($lib_path)"
        else
            log_warn "Failed to create Jellyfin library: $lib_name ($lib_path)"
        fi
    done < <(cfg_jf_libraries)
}

configure_jellyfin_encoding() {
    local jf_url="$1" jf_token="$2"
    local gpu="${JELLYFIN_GPU:-none}"

    if [[ "$gpu" == "none" || -z "$gpu" ]]; then
        case "${STAGE_3_GPU_STATE:-}" in
            skipped)  log_skip "Hardware transcoding: skipped - Jellyfin will use software transcoding" ;;
            fallback) log_skip "Hardware transcoding: fallback - Jellyfin will use software transcoding" ;;
            *)        log_skip "Hardware transcoding: not configured yet - setup handles GPU after Core LAN" ;;
        esac
        return 0
    fi

    local accel_type
    case "$gpu" in
        nvidia)    accel_type="nvenc" ;;
        intel)
            case "${STAGE_3_GPU_ENCODER:-qsv}" in
                vaapi) accel_type="vaapi" ;;
                *)     accel_type="qsv" ;;
            esac
            ;;
        amd)       accel_type="vaapi" ;;
        *) log_skip "Hardware transcoding: unknown GPU type '$gpu'"; return 0 ;;
    esac
    local render_device="${STAGE_3_GPU_RENDER_DEVICE:-/dev/dri/renderD128}"

    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local current_config
    if ! current_config=$(api_fetch "Jellyfin encoding config" \
        "$jf_url/System/Configuration/encoding" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin encoding config - skipping"
        return 0
    fi

    # Jellyfin defaults HardwareAccelerationType to "none" (not "").
    # Both "none" and "" mean "unconfigured / software transcoding".
    local current_accel
    current_accel=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('HardwareAccelerationType', ''))" 2>/dev/null)

    local stage3_state="${STAGE_3_GPU_STATE:-}"
    if [[ "$stage3_state" == "complete" && "$current_accel" != "$accel_type" ]]; then
        log_warn "Jellyfin transcoding is '$current_accel', expected '$accel_type' from completed hardware transcoding proof. Leaving manual Jellyfin settings unchanged; run ./setup.sh --transcoding to re-verify and apply."
        return 0
    fi

    local allow_intel_method_switch=false
    if [[ "$gpu" == "intel" && "$stage3_state" == "pending" ]]; then
        case "$current_accel:$accel_type" in
            qsv:vaapi|vaapi:qsv) allow_intel_method_switch=true ;;
        esac
    fi
    if [[ "$current_accel" != "$accel_type" && "$current_accel" != "none" && -n "$current_accel" && "$allow_intel_method_switch" != "true" ]]; then
        log_warn "Jellyfin transcoding is '$current_accel', expected '$accel_type' (from JELLYFIN_GPU=$gpu). To reset: Jellyfin Dashboard -> Playback -> Transcoding."
        return 0
    fi

    # GET-merge-POST: modify only GPU-related fields, preserve everything else.
    local encoding_result encoding_action encoding_body
    encoding_result=$(echo "$current_config" \
        | ACCEL_TYPE="$accel_type" \
          HW_DECODING_CODECS="${STAGE_3_GPU_HW_DECODING_CODECS:-h264}" \
          DECODE_HEVC_10BIT="${STAGE_3_GPU_DECODE_HEVC_10BIT:-false}" \
          DECODE_VP9_10BIT="${STAGE_3_GPU_DECODE_VP9_10BIT:-false}" \
          ALLOW_HEVC_ENCODING="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-false}" \
          ALLOW_AV1_ENCODING="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-false}" \
          RENDER_DEVICE="$render_device" \
          python3 -c "
import sys, json, os
c = json.load(sys.stdin)
accel = os.environ['ACCEL_TYPE']
def as_bool(value):
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')
codecs = [
    item.strip()
    for item in os.environ.get('HW_DECODING_CODECS', 'h264').split(',')
    if item.strip()
]
if not codecs:
    codecs = ['h264']
desired = {
    'HardwareAccelerationType': accel,
    'EnableHardwareEncoding': True,
    'HardwareDecodingCodecs': codecs,
    'EnableDecodingColorDepth10Hevc': as_bool(os.environ.get('DECODE_HEVC_10BIT', 'false')),
    'EnableDecodingColorDepth10Vp9': as_bool(os.environ.get('DECODE_VP9_10BIT', 'false')),
    'EnableDecodingColorDepth10HevcRext': False,
    'EnableDecodingColorDepth12HevcRext': False,
    'AllowHevcEncoding': as_bool(os.environ.get('ALLOW_HEVC_ENCODING', 'false')),
    'AllowAv1Encoding': as_bool(os.environ.get('ALLOW_AV1_ENCODING', 'false')),
}
if accel == 'nvenc':
    desired.update({
        'EnableEnhancedNvdecDecoder': True,
        'EnableTonemapping': True,
        'TonemappingAlgorithm': 'bt2390',
    })
elif accel == 'qsv':
    desired.update({
        'QsvDevice': os.environ.get('RENDER_DEVICE', ''),
        'VaapiDevice': '',
        'EnableVppTonemapping': False,
        'EnableTonemapping': True,
        'TonemappingAlgorithm': 'bt2390',
    })
elif accel == 'vaapi':
    desired.update({
        'VaapiDevice': os.environ.get('RENDER_DEVICE', '/dev/dri/renderD128'),
        'EnableTonemapping': True,
        'EnableVppTonemapping': False,
        'TonemappingAlgorithm': 'bt2390',
    })
changed = False
for key, value in desired.items():
    if c.get(key) != value:
        c[key] = value
        changed = True
print('APPLY' if changed else 'SKIP')
if changed:
    print(json.dumps(c))")
    encoding_action=$(echo "$encoding_result" | head -1)
    if [[ "$encoding_action" == "SKIP" ]]; then
        log_skip "Hardware transcoding already set to $accel_type"
        return 0
    fi
    if [[ "$encoding_action" != "APPLY" ]]; then
        log_warn "Unexpected Jellyfin encoding config diff result - skipping"
        return 0
    fi
    if [[ "$stage3_state" == "complete" ]]; then
        log_warn "Jellyfin hardware transcoding settings differ from the completed hardware transcoding proof. Leaving manual Jellyfin settings unchanged; run ./setup.sh --transcoding to re-verify and apply."
        return 0
    fi
    encoding_body=$(echo "$encoding_result" | tail -n +2)

    if api_fetch "Jellyfin encoding config" \
        "$jf_url/System/Configuration/encoding" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$encoding_body" >/dev/null; then
        log_ok "Hardware transcoding: $accel_type (from JELLYFIN_GPU=$gpu)"
    else
        log_warn "Failed to set Jellyfin encoding config - configure manually in Dashboard -> Playback -> Transcoding"
    fi
}

configure_jellyfin_server_name() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local want_name
    want_name=$(cfg "jellyfin.server_name" 2>/dev/null || echo "MediaStack")
    want_name="${want_name:-MediaStack}"

    local current_config
    if ! current_config=$(api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin server config - skipping server name"
        return 0
    fi

    local current_name
    current_name=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('ServerName', ''))" 2>/dev/null)

    if [[ "$current_name" == "$want_name" ]]; then
        log_skip "Server name: $want_name"
        return 0
    fi

    # Empty or docker-default hostname → first run, safe to set.
    # Anything else → user changed it in the UI, warn but don't overwrite.
    if [[ -n "$current_name" && "$current_name" != "jellyfin" ]]; then
        log_warn "Jellyfin server name is '$current_name' (expected '$want_name'). Changed in Dashboard? Not overwriting."
        return 0
    fi

    local updated_config
    updated_config=$(echo "$current_config" | WANT="$want_name" python3 -c "
import sys, json, os
c = json.load(sys.stdin)
c['ServerName'] = os.environ['WANT']
print(json.dumps(c))")

    if api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$updated_config" >/dev/null; then
        log_ok "Server name: $want_name"
    else
        log_warn "Failed to set server name - configure manually in Dashboard -> General"
    fi
}

configure_jellyfin_streaming() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local bitrate_mbps
    bitrate_mbps=$(cfg "jellyfin.remote_bitrate_limit" 2>/dev/null || echo "0")
    bitrate_mbps="${bitrate_mbps:-0}"
    # Accept decimal Mbps (3.5, 12.5, etc.) — useful for ISPs whose upload
    # doesn't divide neatly across viewer counts. Reject only true garbage.
    if ! [[ "$bitrate_mbps" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "jellyfin.remote_bitrate_limit is not a valid number ('$bitrate_mbps') - skipping"
        return 0
    fi
    # Use python for the Mbps→bps conversion so decimals survive (bash
    # arithmetic is integer-only). int() truncates rather than rounds, which
    # is the right choice — better to cap a hair below the budget than over.
    local bitrate_bps
    bitrate_bps=$(BITRATE_MBPS="$bitrate_mbps" python3 -c 'import os; print(int(float(os.environ["BITRATE_MBPS"]) * 1_000_000))')

    local current_config
    if ! current_config=$(api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin server config - skipping streaming limit"
        return 0
    fi

    local current_limit
    current_limit=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('RemoteClientBitrateLimit', 0))" 2>/dev/null)

    if [[ "$current_limit" == "$bitrate_bps" ]]; then
        if [[ "$bitrate_bps" == "0" ]]; then
            log_skip "Remote streaming limit: unlimited"
        else
            log_skip "Remote streaming limit already set to ${bitrate_mbps} Mbps"
        fi
        return 0
    fi

    local updated_config
    updated_config=$(echo "$current_config" | BITRATE="$bitrate_bps" python3 -c "
import sys, json, os
c = json.load(sys.stdin)
c['RemoteClientBitrateLimit'] = int(os.environ['BITRATE'])
print(json.dumps(c))")

    if api_fetch "Jellyfin server config" \
        "$jf_url/System/Configuration" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$updated_config" >/dev/null; then
        if [[ "$bitrate_mbps" == "0" ]]; then
            log_ok "Remote streaming limit: unlimited"
        else
            log_ok "Remote streaming limit: ${bitrate_mbps} Mbps"
            local domain="${DOMAIN:-}"
            if [[ -n "$domain" && "$domain" != "example.com" ]]; then
                log_info "Bitrate limit for proxied users requires KnownProxies - configuring next"
            fi
        fi
    else
        log_warn "Failed to set streaming limit - configure manually in Dashboard -> Playback -> Streaming"
    fi
}

configure_jellyfin_networking() {
    local jf_url="$1" jf_token="$2"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local current_config
    if ! current_config=$(api_fetch "Jellyfin network config" \
        "$jf_url/System/Configuration/network" -H "Authorization: $auth"); then
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
    result=$(echo "$current_config" | REMOTE_READY="$remote_ready" HOST_ADDR="$host_addr" DOMAIN_VAL="$domain" NPM_PROXY_IP="$npm_proxy_ip" python3 -c "
import sys, json, os

c = json.load(sys.stdin)
remote_ready = os.environ['REMOTE_READY'] == 'true'
host = os.environ['HOST_ADDR']
domain = os.environ['DOMAIN_VAL']

want_auto = True
# Use the npm container's pinned IP, not the hostname. Jellyfin caches
# DNS resolution at startup (jellyfin/jellyfin#14731) and would reject
# forwarded headers after any network rebuild — manifesting as a login
# loop behind the proxy. The pinned IP comes from docker-compose.yml's
# mediastack network IPAM block.
NPM_PROXY_IP = os.environ.get('NPM_PROXY_IP') or '172.28.0.10'
want_published = ['internal=http://{}:8096'.format(host)]
if remote_ready:
    want_published.append('external=https://jellyfin.{}'.format(domain))

cur_auto = c.get('AutoDiscovery', True)
cur_proxies = c.get('KnownProxies', [])
cur_published = c.get('PublishedServerUriBySubnet', [])

MANAGED_PROXY_VALUES = {'npm', '172.28.0.10', NPM_PROXY_IP}

def desired_known_proxies(current):
    if not isinstance(current, list):
        current = []
    out = []
    managed_added = False
    for entry in current:
        if entry in MANAGED_PROXY_VALUES:
            if remote_ready and not managed_added:
                out.append(NPM_PROXY_IP)
                managed_added = True
            continue
        out.append(entry)
    if remote_ready and not managed_added:
        out.append(NPM_PROXY_IP)
    return out

want_proxies = desired_known_proxies(cur_proxies)

def is_our_published_entry(e):
    if e.startswith('internal=http://') and e.endswith(':8096'):
        host = e[len('internal=http://'):-len(':8096')]
        if host == 'localhost':
            return True
        return all(c.isdigit() or c == '.' for c in host) and host.count('.') == 3
    return e.startswith('external=https://jellyfin.')

changes = {}
drift = []
skip_all = True

# AutoDiscovery — default is True, we want True
if cur_auto == want_auto:
    pass
elif cur_auto is not True:
    drift.append('AutoDiscovery is {} (expected {})'.format(cur_auto, want_auto))

# KnownProxies
if cur_proxies == want_proxies:
    pass
else:
    # Merge/remove only MediaStack-managed proxy entries. Preserve any
    # user-added proxies so remote-ready and cleanup paths do not overwrite UI
    # changes unrelated to NPM.
    changes['KnownProxies'] = want_proxies
    skip_all = False

# PublishedServerUriBySubnet — recognise our own previous values so
# HOST_ADDRESS or DOMAIN changes trigger an update, not a drift warning
if cur_published == want_published:
    pass
elif not cur_published:
    changes['PublishedServerUriBySubnet'] = want_published
    skip_all = False
elif all(is_our_published_entry(e) for e in cur_published):
    changes['PublishedServerUriBySubnet'] = want_published
    skip_all = False
else:
    drift.append('PublishedServerUriBySubnet is {} (expected {})'.format(cur_published, want_published))

if drift and not changes:
    print('DRIFT')
    for d in drift:
        print(d)
elif skip_all and not changes:
    print('SKIP')
else:
    for k, v in changes.items():
        c[k] = v
    if drift:
        print('APPLY_WITH_DRIFT')
        for d in drift:
            print(d)
        print('---')
    else:
        print('APPLY')
    print(json.dumps(c))
" 2>/dev/null)

    local action
    action=$(echo "$result" | head -1)

    case "$action" in
        SKIP)
            log_skip "Jellyfin networking already configured"
            save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"
            if [[ "$published_url_changed" == "true" ]]; then
                log_info "Recreating Jellyfin for PublishedServerUrl change..."
                if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                    log_warn "Failed to recreate Jellyfin - check 'docker compose logs jellyfin'"
                fi
                for _ in $(seq 1 30); do
                    curl -sf http://localhost:8096/health >/dev/null 2>&1 && break; sleep 2
                done
                if ! curl -sf http://localhost:8096/health >/dev/null 2>&1; then
                    log_warn "Jellyfin did not become healthy within 60s after recreate - check 'docker logs jellyfin'"
                fi
            fi
            return 0
            ;;
        DRIFT)
            echo "$result" | tail -n +2 | while IFS= read -r msg; do
                log_warn "Jellyfin networking: $msg - not overwriting (changed in UI?)"
            done
            save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"
            if [[ "$published_url_changed" == "true" ]]; then
                log_info "Recreating Jellyfin for PublishedServerUrl change..."
                if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                    log_warn "Failed to recreate Jellyfin - check 'docker compose logs jellyfin'"
                fi
                for _ in $(seq 1 30); do
                    curl -sf http://localhost:8096/health >/dev/null 2>&1 && break; sleep 2
                done
                if ! curl -sf http://localhost:8096/health >/dev/null 2>&1; then
                    log_warn "Jellyfin did not become healthy within 60s after recreate - check 'docker logs jellyfin'"
                fi
            fi
            return 0
            ;;
        APPLY_WITH_DRIFT)
            local drift_lines body
            drift_lines=$(echo "$result" | sed '1d;/^---$/,$d')
            body=$(echo "$result" | sed '1,/^---$/d')
            echo "$drift_lines" | while IFS= read -r msg; do
                log_warn "Jellyfin networking: $msg - not overwriting (changed in UI?)"
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

    if api_fetch "Jellyfin network config" \
        "$jf_url/System/Configuration/network" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null; then

        # Write JELLYFIN_PUBLISHED_URL to .env for docker-compose
        save_api_key "JELLYFIN_PUBLISHED_URL" "$published_url"

        log_ok "Jellyfin networking configured (AutoDiscovery, KnownProxies, PublishedServerUriBySubnet)"

        # KnownProxies and AutoDiscovery are startup-config — restart required
        if [[ "$published_url_changed" == "true" ]]; then
            # Give Jellyfin a moment to flush the just-POSTed network config
            # before replacing the container to pick up compose env changes.
            sleep 2
            log_info "Recreating Jellyfin for networking and PublishedServerUrl changes to take effect..."
            if ! docker compose up -d --no-deps --force-recreate jellyfin >/dev/null 2>&1; then
                log_warn "Failed to recreate Jellyfin - check 'docker compose logs jellyfin'"
            fi
        else
            log_info "Restarting Jellyfin for networking changes to take effect..."
            if ! docker compose restart jellyfin >/dev/null 2>&1; then
                log_warn "Failed to restart Jellyfin - check 'docker compose logs jellyfin'"
            fi
        fi
        for _ in $(seq 1 30); do
            curl -sf http://localhost:8096/health >/dev/null 2>&1 && break; sleep 2
        done
        if ! curl -sf http://localhost:8096/health >/dev/null 2>&1; then
            log_warn "Jellyfin did not become healthy within 60s after restart - check 'docker logs jellyfin'"
        fi
    else
        log_warn "Failed to set Jellyfin networking config - configure manually in Dashboard -> Networking"
    fi
}

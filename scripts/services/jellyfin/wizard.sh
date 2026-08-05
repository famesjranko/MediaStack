# =============================================================================
# Jellyfin wizard follow-ups — permanent API key, library provisioning
# =============================================================================

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
                log_skip "Jellyfin library '$lib_name' already matches your settings"
                continue
                ;;
            drift)
                log_drift "Jellyfin library '$lib_name' path differs from config.yml (live=${lib_status#*$'\t'}, config.yml=$lib_path). Jellyfin cannot re-root a library without losing watch history. To migrate: Jellyfin UI -> Dashboard -> Libraries -> delete '$lib_name' and re-run configure.sh (accepts history loss), or rebuild (docker compose down -v && ./setup.sh --full)."
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

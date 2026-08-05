# Owns: configure_* — Sonarr/Radarr authentication and Jellyfin notification configuration.
# Sources: scripts/lib/arr/main.sh state plus lib/common.sh, lib/json.sh, and Docker/service helpers.
configure_arr_auth() {
    local app="$1" base="$2" key="$3"

    local jf_user="${JELLYFIN_ADMIN_USER:-admin}"
    local jf_pw="${JELLYFIN_ADMIN_PASSWORD:-}"
    if [[ -z "$jf_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set - skipping ${app^} auth"
        return 0
    fi

    local host_config current_auth
    if ! host_config=$(api_get "$base/config/host" "$key"); then
        log_warn "Could not fetch ${app^} host config - skipping auth check"
        host_config="{}"
    fi
    current_auth=$(echo "$host_config" | json_get authenticationMethod none)

    if [[ "$current_auth" == "forms" ]]; then
        log_skip "${app^} Forms authentication already enabled"
        return 0
    fi

    local auth_config
    auth_config=$(echo "$host_config" | JF_USER="$jf_user" JF_PW="$jf_pw" python3 -c '
import os, sys, json
config = json.load(sys.stdin)
config["authenticationMethod"] = "forms"
config["authenticationRequired"] = "enabled"
config["username"] = os.environ["JF_USER"]
config["password"] = os.environ["JF_PW"]
config["passwordConfirmation"] = os.environ["JF_PW"]
json.dump(config, sys.stdout)' 2>/dev/null)

    if api_put "$base/config/host" "$key" "$auth_config" >/dev/null 2>&1; then
        log_ok "${app^} Forms authentication enabled (user: $jf_user)"
        docker restart "$app" >/dev/null 2>&1
        post_restart_wait "$(service_local_url "$app")" || true
    else
        log_warn "Failed to enable ${app^} authentication"
    fi
}

# Connect a Sonarr or Radarr instance to Jellyfin so library scans trigger
# automatically on import. Uses the MediaBrowser notification type.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_jellyfin_connection() {
    local app="$1" base="$2" key="$3"

    local jf_key="${JELLYFIN_API_KEY:-}"
    if [[ -z "$jf_key" ]]; then
        log_warn "JELLYFIN_API_KEY not set - skipping ${app^} Jellyfin connection"
        return 0
    fi

    local existing conn_status
    if ! existing=$(api_get "$base/notification" "$key"); then
        sleep 5
        if ! existing=$(api_get "$base/notification" "$key"); then
            log_warn "Could not fetch ${app^} notifications - skipping Jellyfin connection"
            return 0
        fi
    fi
    conn_status=$(echo "$existing" | python3 -c '
import sys, json
try: items = json.load(sys.stdin)
except Exception: items = []
jf = next((n for n in items if n.get("implementation") == "MediaBrowser"), None)
if jf is None:
    print("absent")
else:
    print("present")
' 2>/dev/null)

    if [[ "$conn_status" == "present" ]]; then
        log_skip "${app^} Jellyfin connection already configured"
        return 0
    fi

    # Sonarr uses onImportComplete; Radarr uses onDownload for the same purpose
    local notif_json
    notif_json=$(JF_KEY="$jf_key" APP="$app" python3 -c '
import os, json
app = os.environ["APP"]
trigger = {"onImportComplete": True} if app == "sonarr" else {"onDownload": True}
payload = {
    "name": "Jellyfin",
    "implementation": "MediaBrowser",
    "configContract": "MediaBrowserSettings",
    "onGrab": False,
    "onUpgrade": False,
    "onRename": False,
    "onHealthIssue": False,
    "onHealthRestored": False,
    "onApplicationUpdate": False,
    "fields": [
        {"name": "host", "value": "jellyfin"},
        {"name": "port", "value": 8096},
        {"name": "useSsl", "value": False},
        {"name": "urlBase", "value": ""},
        {"name": "apiKey", "value": os.environ["JF_KEY"]},
        {"name": "notify", "value": False},
        {"name": "updateLibrary", "value": True},
        {"name": "mapFrom", "value": ""},
        {"name": "mapTo", "value": ""},
    ],
}
payload.update(trigger)
print(json.dumps(payload))')

    # POST /notification runs a provider Test() before saving — Sonarr hits
    # Jellyfin GET /System/Configuration, Radarr hits POST /Notifications/Admin.
    # The test can transiently fail if Jellyfin just restarted and isn't ready yet.
    # Retry with backoff, then fall back to forceSave=true (same pattern as indexers).
    local attempt
    for attempt in 1 2 3; do
        if api_post "$base/notification" "$key" "$notif_json" >/dev/null 2>&1; then
            log_ok "${app^} -> Jellyfin: library update on import"
            return 0
        fi
        sleep $((attempt * 3))
    done
    if api_post "$base/notification?forceSave=true" "$key" "$notif_json" >/dev/null 2>&1; then
        log_ok "${app^} -> Jellyfin: library update on import"
    else
        log_warn "Failed to add Jellyfin connection to ${app^}"
    fi
}

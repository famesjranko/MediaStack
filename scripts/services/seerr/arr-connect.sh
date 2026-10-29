# =============================================================================
# Seerr — connect a Sonarr or Radarr instance
# =============================================================================
# Sourced by seerr/main.sh. Depends on helpers already loaded by
# configure.sh: api_get_key, api_get, api_fetch, json_array_nonempty,
# http_json_post, cfg_field (common.sh / http.sh / json.sh).

# Args: <sonarr|radarr> <arr_port> <seerr_url> <cookiejar>
connect_arr_to_seerr() {
    local app="$1" arr_port="$2" seerr_url="$3" cookiejar="$4"
    local app_label="${app^}"

    # Endpoint literals must stay greppable for the contract checker.
    local settings_url
    case "$app" in
        sonarr) settings_url="$seerr_url/api/v1/settings/sonarr" ;;
        radarr) settings_url="$seerr_url/api/v1/settings/radarr" ;;
        *) return 0 ;;
    esac

    local arr_key
    arr_key=$(api_get_key "$SCRIPT_DIR/config/${app}/config.xml")
    [[ -z "$arr_key" ]] && return 0

    # Read the current Seerr-side config for this app. A failed GET must NOT be
    # treated as "empty": Seerr's POST /settings/{app} CREATES a new server, so
    # on a re-run whose GET merely hiccuped (expired session cookie, transient
    # non-2xx) falling through to the POST below spawns a DUPLICATE server —
    # which demotes the original's isDefault and can be rejected outright.
    # Retry a few times (day-2 re-runs must tolerate transient *arr/Seerr API
    # blips), and if the read still fails, skip rather than risk a duplicate.
    local existing="" attempt
    for attempt in 1 2 3; do
        existing=$(api_fetch "Seerr ${app_label} settings" -c "$cookiejar" -b "$cookiejar" "$settings_url") && break
        existing=""
        sleep "$attempt"
    done
    if [[ -z "$existing" ]]; then
        log_warn "Could not read Seerr ${app_label} settings after retries; skipping connect to avoid a duplicate server. Re-run via ./mediastack -> Install MediaStack or connect ${app_label} in the Seerr UI."
        return 0
    fi
    json_check "Seerr ${app_label} settings" :array '[].id:integer' <<<"$existing" || return 1
    if echo "$existing" | json_array_nonempty; then
        log_skip "${app_label} already connected to Seerr"
        return 0
    fi

    local profile_json profile_id profile_name target_profile_name
    if ! profile_json=$(api_get "http://localhost:${arr_port}/api/v3/qualityprofile" "$arr_key" :array '[].id:integer' '[].name:string'); then
        log_warn "Could not fetch ${app_label} quality profiles for Seerr - skipping connection"
        return 1
    fi
    if ! json_array_nonempty <<<"$profile_json"; then
        log_warn "${app_label} returned no quality profile to connect"
        return 1
    fi
    target_profile_name=$(cfg_field quality_profile.name)
    profile_id=$(echo "$profile_json" | PROFILE_TARGET="$target_profile_name" python3 -c '
import os,sys,json
profiles=json.load(sys.stdin)
target=os.environ["PROFILE_TARGET"]
match=next((p for p in profiles if p["name"]==target), profiles[0])
print(match["id"])
') || return 1
    profile_name=$(echo "$profile_json" | PROFILE_TARGET="$target_profile_name" python3 -c '
import os,sys,json
profiles=json.load(sys.stdin)
target=os.environ["PROFILE_TARGET"]
match=next((p for p in profiles if p["name"]==target), profiles[0])
print(match["name"])
') || return 1

    local lang_id=""
    if [[ "$app" == "sonarr" ]]; then
        local _lang_json
        if ! _lang_json=$(api_get "http://localhost:${arr_port}/api/v3/languageprofile" "$arr_key" :array '[].id:integer'); then
            log_warn "Could not fetch Sonarr language profiles for Seerr - skipping connection"
            return 1
        fi
        if ! json_array_nonempty <<<"$_lang_json"; then
            log_warn "Sonarr returned no language profile to connect"
            return 1
        fi
        lang_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])' <<<"$_lang_json") || return 1
    fi

    local root_dir
    root_dir=$(cfg_field "${app}.root_folder")

    local body
    body=$(APP="$app" ARR_PORT="$arr_port" ARR_KEY="$arr_key" \
        PROFILE_ID="$profile_id" PROFILE_NAME="$profile_name" \
        ROOT_DIR="$root_dir" LANG_ID="$lang_id" \
        python3 -c '
import os, json
app = os.environ["APP"]
body = {
    "name": app.capitalize(),
    "hostname": app,
    "port": int(os.environ["ARR_PORT"]),
    "useSsl": False,
    "apiKey": os.environ["ARR_KEY"],
    "baseUrl": "",
    "activeProfileId": int(os.environ["PROFILE_ID"]),
    "activeProfileName": os.environ["PROFILE_NAME"],
    "activeDirectory": os.environ["ROOT_DIR"],
    "is4k": False,
    "isDefault": True,
    "syncEnabled": True,
    "preventSearch": False,
}
if app == "sonarr":
    body["activeLanguageProfileId"] = int(os.environ["LANG_ID"])
    body["enableSeasonFolders"] = True
else:
    body["minimumAvailability"] = "released"
print(json.dumps(body))
')

    http_json_post "$app_label" "$settings_url" \
        "$body" \
        "$cookiejar"
}

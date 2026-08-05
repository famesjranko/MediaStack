# Owns: configure_* — Sonarr/Radarr root-folder, disk-threshold, and download-client configuration.
# Sources: scripts/lib/arr/main.sh state plus lib/common.sh, lib/json.sh, and the target app APIs.
configure_arr_root_folder() {
    local app="$1" base="$2" key="$3"

    local root_folder
    root_folder=$(cfg_field "$app.root_folder")

    local existing rf_status
    if ! existing=$(api_get "$base/rootfolder" "$key"); then
        log_warn "Could not fetch ${app^} root folders - skipping check"
        existing="[]"
    fi
    rf_status=$(echo "$existing" | WANT_PATH="$root_folder" python3 -c '
import sys, json, os
want = os.environ["WANT_PATH"]
try: items = json.load(sys.stdin)
except Exception: items = []
paths = [r.get("path","") for r in items]
if want in paths: print("match")
elif paths:       print("drift\t" + ",".join(paths))
else:             print("absent")
' 2>/dev/null)
    case "${rf_status%%$'\t'*}" in
        match)
            log_skip "${app^} root folder $root_folder already matches config.yml"
            ;;
        drift)
            log_drift "${app^} root folder differs from config.yml (live=${rf_status#*$'\t'}, config.yml=$root_folder). configure.sh does not reconcile this on re-run. To change: ${app^} UI -> Settings -> Media Management -> Root Folders -> delete the stale entry, or rebuild (docker compose down -v && ./setup.sh --full)."
            ;;
        *)
            local root_body
            root_body=$(ROOT_FOLDER="$root_folder" python3 -c '
import json
import os
import sys

json.dump({"path": os.environ["ROOT_FOLDER"]}, sys.stdout)
' 2>/dev/null)
            if [[ -n "$root_body" ]] && api_post "$base/rootfolder" "$key" "$root_body" >/dev/null 2>&1; then
                log_ok "Root folder: $root_folder"
            else
                log_warn "Failed to set ${app^} root folder: $root_folder"
            fi
            ;;
    esac
}

# Set the global minimum-free-space threshold for a Sonarr or Radarr instance.
# Reads min_free_space_gb from config.yml, converts to MB, and applies via
# GET/PUT /api/v3/config/mediamanagement. Only updates when the current value
# is the API default (100 MB); warns on drift from user-customized values.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_disk_threshold() {
    local app="$1" base="$2" key="$3"

    local min_free_gb
    min_free_gb=$(cfg_field "min_free_space_gb" 2>/dev/null || echo "20")

    if [[ "$min_free_gb" == "0" ]]; then
        log_skip "${app^} disk threshold disabled (min_free_space_gb=0)"
        return 0
    fi

    local min_free_mb=$((min_free_gb * 1024))

    local mm_config current_mb
    if ! mm_config=$(api_get "$base/config/mediamanagement" "$key"); then
        log_warn "Could not fetch ${app^} media management config - skipping disk threshold"
        return 0
    fi
    current_mb=$(echo "$mm_config" | json_get minimumFreeSpaceWhenImporting 100)

    if [[ "$current_mb" == "$min_free_mb" ]]; then
        log_skip "${app^} disk threshold already ${min_free_gb}GB"
        return 0
    fi

    if [[ "$current_mb" != "100" ]]; then
        log_drift "${app^} minimumFreeSpaceWhenImporting=${current_mb}MB differs from config.yml (${min_free_gb}GB=${min_free_mb}MB). configure.sh does not reconcile on re-run."
        return 0
    fi

    local mm_body
    mm_body=$(echo "$mm_config" | MIN_FREE_MB="$min_free_mb" python3 -c '
import sys, json, os
config = json.load(sys.stdin)
config["minimumFreeSpaceWhenImporting"] = int(os.environ["MIN_FREE_MB"])
json.dump(config, sys.stdout)' 2>/dev/null)

    if api_put "$base/config/mediamanagement" "$key" "$mm_body" >/dev/null 2>&1; then
        log_ok "Disk threshold: ${min_free_gb}GB minimum free space"
    else
        log_warn "Failed to set ${app^} disk threshold"
    fi
}

# Check/create a qBittorrent download client for a Sonarr or Radarr instance.
# The category field name differs between apps (tvCategory vs movieCategory),
# passed as the 4th argument.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key> <category-field-name>
configure_arr_download_client() {
    local app="$1" base="$2" key="$3" category_field="$4"

    local dl_category
    dl_category=$(cfg_field "$app.download_client_category")

    local existing dc_status
    if ! existing=$(api_get "$base/downloadclient" "$key"); then
        log_warn "Could not fetch ${app^} download clients - skipping check"
        existing="[]"
    fi
    dc_status=$(echo "$existing" | WANT_CATEGORY="$dl_category" CATEGORY_FIELD="$category_field" python3 -c '
import sys, json, os
want = os.environ["WANT_CATEGORY"]
cat_field = os.environ["CATEGORY_FIELD"]
try: items = json.load(sys.stdin)
except Exception: items = []
qbt = next((c for c in items if c.get("name") == "qBittorrent"), None)
if qbt is None:
    print("absent")
else:
    live = next((f.get("value","") for f in qbt.get("fields",[]) if f.get("name")==cat_field), "")
    print("match" if str(live) == str(want) else "drift\t" + str(live))
' 2>/dev/null)
    case "${dc_status%%$'\t'*}" in
        match)
            log_skip "${app^} qBittorrent category already matches config.yml ($dl_category)"
            ;;
        drift)
            log_drift "${app^} qBittorrent category differs from config.yml (live=${dc_status#*$'\t'}, config.yml=$dl_category). configure.sh does not reconcile this on re-run. To change: ${app^} UI -> Settings -> Download Clients -> qBittorrent -> update Category, or rebuild."
            ;;
        *)
            local dlclient_json
            dlclient_json=$(DL_CATEGORY="$dl_category" CATEGORY_FIELD="$category_field" \
                python3 -c '
import os, json
print(json.dumps({
    "enable": True,
    "protocol": "torrent",
    "priority": 1,
    "name": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "removeCompletedDownloads": True,
    "removeFailedDownloads": True,
    "fields": [
        {"name": "host", "value": "qbittorrent"},
        {"name": "port", "value": 8080},
        {"name": os.environ["CATEGORY_FIELD"], "value": os.environ["DL_CATEGORY"]},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": False},
        {"name": "firstAndLastFirst", "value": False},
    ],
}))')
            if api_post "$base/downloadclient" "$key" "$dlclient_json" >/dev/null 2>&1; then
                log_ok "Download client: qBittorrent (category: $dl_category)"
            else
                log_warn "Failed to add qBittorrent to ${app^}"
            fi
            ;;
    esac
}

# Enable Forms authentication on a Sonarr or Radarr instance using Jellyfin
# admin credentials. Restarts the container and polls until ready.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>

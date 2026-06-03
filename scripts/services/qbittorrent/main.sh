# =============================================================================
# 1. qBittorrent — login, set preferences, seed categories
# =============================================================================

configure_qbittorrent() {
    echo ""
    echo -e "${BOLD}Configuring qBittorrent...${NC}"

    local qbt_url="http://localhost:8080"
    local jar authed="" target_pw="${JELLYFIN_ADMIN_PASSWORD:-}" target_user="${JELLYFIN_ADMIN_USER:-admin}"
    jar=$(mktemp)

    # qBittorrent v5.x returns HTTP 200 with body "Fails." for bad passwords,
    # so we must check the response body, not just the HTTP status.
    _qbt_login() {
        local username="$1" password="$2" resp body http_code
        resp=$(curl -s -c "$jar" -w "\n%{http_code}" "$qbt_url/api/v2/auth/login" \
            --data-urlencode "username=$username" \
            --data-urlencode "password=$password" 2>/dev/null) || return 1
        http_code=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')
        [[ "$body" == "Ok." || ( "$http_code" == "204" && -z "$body" ) ]]
    }

    # Try shared admin password first (re-run / already unified)
    if [[ -n "$target_pw" ]]; then
        if _qbt_login "$target_user" "$target_pw"; then
            authed="target"
        elif [[ "$target_user" != "admin" ]] && _qbt_login "admin" "$target_pw"; then
            authed="target"
        fi
    fi

    _qbt_temp_password_from_logs() {
        {
            docker compose logs qbittorrent 2>/dev/null
            docker logs qbittorrent 2>/dev/null
        } | python3 -c '
import re
import sys

password = ""
for line in sys.stdin:
    match = re.search(r"temporary password.*:\s*(\S+)", line, re.IGNORECASE)
    if match:
        password = match.group(1)
print(password)
'
    }

    # First run: extract temporary password from container logs. qBittorrent can
    # report healthy before the one-time password line is flushed, so poll for a
    # short bounded window before giving up.
    if [[ -z "$authed" ]]; then
        local temp_pw attempt
        for attempt in $(seq 1 60); do
            temp_pw=$(_qbt_temp_password_from_logs)
            if [[ -n "$temp_pw" ]] && _qbt_login "admin" "$temp_pw"; then
                authed="temp"
                break
            fi
            [[ "$attempt" -lt 60 ]] && sleep 2
        done
    fi

    # Migration: try legacy QBT_ADMIN_PASSWORD from .env (pre-unification installs)
    if [[ -z "$authed" ]]; then
        local legacy_pw="${QBT_ADMIN_PASSWORD:-}"
        if [[ -n "$legacy_pw" ]]; then
            if _qbt_login "$target_user" "$legacy_pw"; then
                authed="legacy"
            elif [[ "$target_user" != "admin" ]] && _qbt_login "admin" "$legacy_pw"; then
                authed="legacy"
            fi
        fi
    fi

    if [[ -z "$authed" ]]; then
        log_warn "Could not authenticate with qBittorrent (JELLYFIN_ADMIN_PASSWORD failed, no usable temp password in logs after waiting)"
        rm -f "$jar"; return 0
    fi

    local manual_storage=false
    if declare -F storage_is_manual >/dev/null && storage_is_manual; then
        manual_storage=true
    fi

    # Read settings from config.yml
    local save_path temp_path max_ratio max_seed_time max_dl max_ul max_total
    save_path=$(cfg_field "qbittorrent.save_path")
    temp_path=$(cfg_field "qbittorrent.temp_path")
    max_ratio=$(cfg_field "qbittorrent.max_ratio")
    max_seed_time=$(cfg_field "qbittorrent.max_seeding_time" 2>/dev/null || echo "1440")
    max_dl=$(cfg_field "qbittorrent.max_active_downloads")
    max_ul=$(cfg_field "qbittorrent.max_active_uploads")
    max_total=$(cfg_field "qbittorrent.max_active_torrents")

    # Speed limits: .env overrides config.yml; stored as MB/s, API wants bytes/s
    local dl_limit_mb ul_limit_mb
    dl_limit_mb=$(cfg_field "qbittorrent.dl_speed_limit" 2>/dev/null || echo "0")
    ul_limit_mb=$(cfg_field "qbittorrent.ul_speed_limit" 2>/dev/null || echo "0")
    [[ -n "${QBT_DL_LIMIT:-}" ]] && dl_limit_mb="$QBT_DL_LIMIT"
    [[ -n "${QBT_UL_LIMIT:-}" ]] && ul_limit_mb="$QBT_UL_LIMIT"
    local dl_limit ul_limit
    dl_limit=$(python3 -c "print(int(float('${dl_limit_mb}') * 1048576))")
    ul_limit=$(python3 -c "print(int(float('${ul_limit_mb}') * 1048576))")

    local prefs_json
    if $manual_storage; then
        prefs_json=$(DL_LIMIT="$dl_limit" UP_LIMIT="$ul_limit" TORRENT_PORT="${TORRENT_PORT:-6881}" python3 -c '
import os, json
print(json.dumps({
    "listen_port": int(os.environ["TORRENT_PORT"]),
    "dl_limit": int(os.environ["DL_LIMIT"]),
    "up_limit": int(os.environ["UP_LIMIT"]),
    "bypass_auth_subnet_whitelist": "172.16.0.0/12",
    "bypass_auth_subnet_whitelist_enabled": True,
}))')
        log_skip "qBittorrent save/temp paths skipped (manual app wiring)"
    else
        prefs_json=$(SAVE_PATH="$save_path" TEMP_PATH="$temp_path" \
            MAX_RATIO="$max_ratio" MAX_SEED_TIME="$max_seed_time" \
            MAX_DL="$max_dl" MAX_UL="$max_ul" MAX_TOTAL="$max_total" \
            DL_LIMIT="$dl_limit" UP_LIMIT="$ul_limit" \
            TORRENT_PORT="${TORRENT_PORT:-6881}" \
            python3 -c '
import os, json
print(json.dumps({
    "save_path": os.environ["SAVE_PATH"],
    "temp_path": os.environ["TEMP_PATH"],
    "temp_path_enabled": True,
    "listen_port": int(os.environ["TORRENT_PORT"]),
    "max_ratio": float(os.environ["MAX_RATIO"]),
    "max_ratio_enabled": True,
    "max_ratio_act": 0,
    "max_seeding_time": int(os.environ["MAX_SEED_TIME"]),
    "max_seeding_time_enabled": True,
    "dl_limit": int(os.environ["DL_LIMIT"]),
    "up_limit": int(os.environ["UP_LIMIT"]),
    "max_connec": 500,
    "max_connec_per_torrent": 100,
    "max_uploads": 100,
    "max_uploads_per_torrent": 5,
    "queueing_enabled": True,
    "max_active_downloads": int(os.environ["MAX_DL"]),
    "max_active_uploads": int(os.environ["MAX_UL"]),
    "max_active_torrents": int(os.environ["MAX_TOTAL"]),
    "upnp": True,
    "preallocate_all": True,
    "bypass_auth_subnet_whitelist": "172.16.0.0/12",
    "bypass_auth_subnet_whitelist_enabled": True,
}))')
    fi
    if curl -sf -b "$jar" "$qbt_url/api/v2/app/setPreferences" \
        --data-urlencode "json=$prefs_json" >/dev/null 2>&1; then
        log_ok "Preferences set"
    else
        log_warn "Failed to set qBittorrent preferences"
    fi

    # Keep qBittorrent aligned with the shared setup credentials. qBittorrent
    # defaults to username "admin"; MediaStack's access summary promises the
    # wizard admin username, so set both fields explicitly.
    if [[ -z "$target_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set — cannot set qBittorrent WebUI credentials"
    else
        local auth_json
        auth_json=$(QBT_WEB_USER="$target_user" PW="$target_pw" \
            MAX_RATIO="$max_ratio" MAX_SEED_TIME="$max_seed_time" \
            python3 -c '
import os, json
print(json.dumps({
    "web_ui_username": os.environ["QBT_WEB_USER"],
    "web_ui_password": os.environ["PW"],
    "max_ratio": float(os.environ["MAX_RATIO"]),
    "max_ratio_enabled": True,
    "max_ratio_act": 0,
    "max_seeding_time": int(os.environ["MAX_SEED_TIME"]),
    "max_seeding_time_enabled": True,
}))
')
        if curl -sf -b "$jar" "$qbt_url/api/v2/app/setPreferences" \
            --data-urlencode "json=$auth_json" >/dev/null 2>&1; then
            log_ok "WebUI login: $target_user / shared admin password"
        else
            log_warn "Could not set qBittorrent WebUI credentials"
        fi
    fi

    if $manual_storage; then
        log_skip "qBittorrent categories skipped (manual app wiring)"
        rm -f "$jar"
        return 0
    fi

    # Categories from config.yml. createCategory may 409 if the category was
    # pre-seeded via categories.json; editCategory ensures savePath is set
    # regardless. Check existing categories first for idempotent logging.
    local existing_cats
    if ! existing_cats=$(api_fetch "qBittorrent categories" -b "$jar" "$qbt_url/api/v2/torrents/categories"); then
        existing_cats="{}"
    fi
    _qbt_category_path() {
        local cats_json="$1" name="$2"
        CATEGORY_NAME="$name" python3 -c '
import json
import os
import sys
try:
    cats = json.load(sys.stdin)
except Exception:
    cats = {}
cat = cats.get(os.environ["CATEGORY_NAME"], {})
print(cat.get("savePath", ""))
' <<< "$cats_json" 2>/dev/null || echo ""
    }

    while IFS=: read -r cat_name cat_path; do
        local current_path
        current_path=$(_qbt_category_path "$existing_cats" "$cat_name")

        if [[ "$current_path" == "$cat_path" ]]; then
            log_skip "Category: $cat_name -> $cat_path"
            continue
        fi

        curl -sf -b "$jar" "$qbt_url/api/v2/torrents/createCategory" \
            --data-urlencode "category=${cat_name}" \
            --data-urlencode "savePath=${cat_path}" >/dev/null 2>&1 || true
        if curl -sf -b "$jar" "$qbt_url/api/v2/torrents/editCategory" \
            --data-urlencode "category=${cat_name}" \
            --data-urlencode "savePath=${cat_path}" >/dev/null 2>&1; then
            log_ok "Category: $cat_name -> $cat_path"
        else
            local refreshed_cats refreshed_path
            if refreshed_cats=$(api_fetch "qBittorrent categories" -b "$jar" "$qbt_url/api/v2/torrents/categories"); then
                refreshed_path=$(_qbt_category_path "$refreshed_cats" "$cat_name")
            else
                refreshed_path=""
            fi
            if [[ "$refreshed_path" == "$cat_path" ]]; then
                log_ok "Category: $cat_name -> $cat_path"
            else
                log_warn "Failed to set qBittorrent category: $cat_name -> $cat_path"
            fi
        fi
    done < <(cfg_qbt_categories)

    rm -f "$jar"
}

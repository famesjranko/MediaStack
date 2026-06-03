#!/usr/bin/env bash
# Shared NPM remote-readiness checks. Sourceable by setup stages without
# importing scripts/services/npm/main.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

npm_remote_container_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' npm 2>/dev/null || echo false)" == "true" ]]
}

npm_remote_cert_material_ready() {
    local cert_id="$1"
    [[ -z "$cert_id" || "$cert_id" == "0" ]] && return 1

    if npm_remote_container_running; then
        docker exec npm test -f "/etc/letsencrypt/live/npm-$cert_id/fullchain.pem" >/dev/null 2>&1 && \
        docker exec npm test -f "/etc/letsencrypt/live/npm-$cert_id/privkey.pem" >/dev/null 2>&1
        return $?
    fi

    local live_dir="$SCRIPT_DIR/config/npm/letsencrypt/live/npm-$cert_id"
    if test -f "$live_dir/fullchain.pem" && test -f "$live_dir/privkey.pem"; then
        return 0
    fi
    [[ $(id -u) -eq 0 ]] && return 1
    sudo -n test -f "$live_dir/fullchain.pem" 2>/dev/null && \
    sudo -n test -f "$live_dir/privkey.pem" 2>/dev/null
}

npm_remote_proxy_conf_renders() {
    local host_id="$1" fqdn="$2" cert_id="${3:-0}"
    [[ -z "$host_id" || -z "$fqdn" ]] && return 1

    if npm_remote_container_running; then
        local conf_in_container="/data/nginx/proxy_host/$host_id.conf"
        docker exec npm test -f "$conf_in_container" >/dev/null 2>&1 || return 1
        docker exec npm grep -q "server_name $fqdn" "$conf_in_container" >/dev/null 2>&1 || return 1
        if [[ -n "$cert_id" && "$cert_id" != "0" ]]; then
            docker exec npm grep -q "/etc/letsencrypt/live/npm-$cert_id/" "$conf_in_container" >/dev/null 2>&1 || return 1
        fi
        return 0
    fi

    local conf="$SCRIPT_DIR/config/npm/data/nginx/proxy_host/$host_id.conf"
    local sudo_cmd=()
    if test -f "$conf" 2>/dev/null; then
        sudo_cmd=()
    elif [[ $(id -u) -ne 0 ]] && sudo -n test -f "$conf" 2>/dev/null; then
        sudo_cmd=(sudo -n)
    else
        return 1
    fi

    "${sudo_cmd[@]}" grep -q "server_name $fqdn" "$conf" 2>/dev/null || return 1
    if [[ -n "$cert_id" && "$cert_id" != "0" ]]; then
        "${sudo_cmd[@]}" grep -q "/etc/letsencrypt/live/npm-$cert_id/" "$conf" 2>/dev/null || return 1
    fi
    return 0
}

npm_remote_api_cert_ids_by_fqdn() {
    local token="$1" api="$2" fqdn="$3"
    local certs
    certs=$(curl -sf --max-time 30 -H "Authorization: Bearer $token" \
        "$api/nginx/certificates" 2>/dev/null) || return 2
    echo "$certs" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
matches = [c for c in json.load(sys.stdin)
           if not c.get("is_deleted") and fqdn in c.get("domain_names", [])]
matches.sort(key=lambda c: int(c.get("id", 0)), reverse=True)
for c in matches:
    print(c.get("id", 0))
' 2>/dev/null
}

npm_remote_usable_cert_id_by_fqdn() {
    local token="$1" api="$2" fqdn="$3"
    local ids rc candidate
    ids=$(npm_remote_api_cert_ids_by_fqdn "$token" "$api" "$fqdn")
    rc=$?
    (( rc == 2 )) && return 2
    while IFS= read -r candidate; do
        [[ -z "$candidate" || "$candidate" == "0" ]] && continue
        if npm_remote_cert_material_ready "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done <<< "$ids"
    return 0
}

npm_remote_host_json_by_fqdn() {
    local hosts_json="$1" fqdn="$2"
    echo "$hosts_json" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
for host in json.load(sys.stdin):
    if fqdn in host.get("domain_names", []):
        print(json.dumps(host))
        break
' 2>/dev/null
}

npm_remote_json_field() {
    local field="$1" default="${2:-}"
    FIELD="$field" DEFAULT="$default" python3 -c '
import sys, json, os
try:
    value = json.load(sys.stdin).get(os.environ["FIELD"], None)
except Exception:
    value = None
if value is None:
    value = os.environ["DEFAULT"]
print(value)
' 2>/dev/null
}

npm_remote_token() {
    local api="${1:-http://localhost:81/api}"
    local email="${NPM_ADMIN_EMAIL:-}" password="${JELLYFIN_ADMIN_PASSWORD:-}"
    [[ -z "$email" || -z "$password" ]] && return 1

    local body
    body=$(NPM_EMAIL="$email" NPM_PASSWORD="$password" python3 -c '
import os, json
print(json.dumps({"identity": os.environ["NPM_EMAIL"], "secret": os.environ["NPM_PASSWORD"]}))
')
    curl -sf --max-time 10 -X POST "$api/tokens" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null | npm_remote_json_field token
}

npm_remote_hosts_ready() {
    local domain="$1"
    local api="${2:-http://localhost:81/api}"
    [[ -z "$domain" || "$domain" == "example.com" ]] && return 1

    local token hosts fqdn cert_id host_json host_id host_cert_id host_enabled
    token=$(npm_remote_token "$api") || return 1
    [[ -z "$token" ]] && return 1

    hosts=$(curl -sf --max-time 30 -H "Authorization: Bearer $token" \
        "$api/nginx/proxy-hosts" 2>/dev/null) || return 1

    for fqdn in "jellyfin.$domain" "jellyseerr.$domain"; do
        cert_id=$(npm_remote_usable_cert_id_by_fqdn "$token" "$api" "$fqdn") || return 1
        [[ -z "$cert_id" || "$cert_id" == "0" ]] && return 1

        host_json=$(npm_remote_host_json_by_fqdn "$hosts" "$fqdn")
        [[ -z "$host_json" ]] && return 1

        host_id=$(echo "$host_json" | npm_remote_json_field id)
        host_cert_id=$(echo "$host_json" | npm_remote_json_field certificate_id 0)
        host_enabled=$(echo "$host_json" | npm_remote_json_field enabled False)
        [[ "$host_enabled" =~ ^(True|true)$ ]] || return 1
        [[ "$host_cert_id" == "$cert_id" ]] || return 1

        npm_remote_cert_material_ready "$cert_id" || return 1
        npm_remote_proxy_conf_renders "$host_id" "$fqdn" "$cert_id" || return 1
    done
}

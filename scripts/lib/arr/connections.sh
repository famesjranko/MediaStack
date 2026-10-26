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

# What MediaStack writes when it creates the connection. A record is
# MediaStack-created only when its name, host and port all match; anything else
# is user-managed and is never changed.
_ARR_JF_NAME="Jellyfin"
_ARR_JF_HOST="jellyfin"
_ARR_JF_PORT="8096"

# Classify the MediaBrowser records in a GET /notification body on stdin.
# Prints one line per record: id, name, kind (managed|user), notify (0|1),
# separated by tabs. Exits 1 on a body that is not a list of addressable
# records. The Jellyfin API key is never read: Sonarr and Radarr mask it as
# "********" on every GET.
_configure_arr_jellyfin_records() {
    JF_NAME="$_ARR_JF_NAME" JF_HOST="$_ARR_JF_HOST" JF_PORT="$_ARR_JF_PORT" python3 -c '
import os, sys, json
try:
    items = json.load(sys.stdin)
    if not isinstance(items, list):
        raise ValueError
    rows = []
    for n in items:
        if not isinstance(n, dict) or n.get("implementation") != "MediaBrowser":
            continue
        if type(n.get("id")) is not int:
            raise ValueError
        f = {x.get("name"): x.get("value") for x in n.get("fields", []) if isinstance(x, dict)}
        name = "".join(c for c in str(n.get("name", "")) if c.isprintable())[:40] or "(unnamed)"
        managed = (n.get("name") == os.environ["JF_NAME"] and f.get("host") == os.environ["JF_HOST"]
                   and str(f.get("port")) == os.environ["JF_PORT"] and f.get("useSsl") is False)
        rows.append("%d\t%s\t%s\t%d" % (n["id"], name, "managed" if managed else "user", f.get("notify") is True))
except Exception:
    sys.exit(1)
print("\n".join(rows))' 2>/dev/null
}

# Fetch one notification record by id; fails unless the body is a record.
_configure_arr_jellyfin_fetch_record() {
    local base="$1" key="$2" id="$3" record
    record=$(api_get "$base/notification/$id" "$key") || return 1
    python3 -c '
import sys, json
r = json.load(sys.stdin)
sys.exit(0 if isinstance(r, dict) and isinstance(r.get("fields"), list) and type(r.get("id")) is int else 1)' <<<"$record" 2>/dev/null || return 1
    printf '%s' "$record"
}

# Ask Sonarr/Radarr to test a stored record. The record body carries the masked
# key, so the app tests the key it has stored. For a record that does not notify
# users, the test only reads Jellyfin's configuration. Prints ok, stale (Jellyfin
# rejected the key) or unverified (any other failure). Never prints the key.
_configure_arr_jellyfin_test_record() {
    local base="$1" key="$2" record="$3" out attempt
    for attempt in 1 2; do
        if out=$(api_post "$base/notification/test" "$key" "$record" 2>&1 >/dev/null); then
            echo ok
            return 0
        fi
        if grep -qi '"propertyName": *"ApiKey"' <<<"$out"; then
            echo stale
            return 0
        fi
        ((attempt < 2)) && sleep 3
    done
    echo unverified
}

# Warning for a record whose key Jellyfin rejects. The wording names the menu
# path, not a script, so it also holds for installs that never use the CLI.
_configure_arr_jellyfin_warn_stale() {
    local who="$1" kind="$2" app="$3"
    if [[ "$kind" == "managed" ]]; then
        log_warn "$who is MediaStack-created but Jellyfin rejects its API key. Repair: ./mediastack -> Features & settings -> Repair Jellyfin connections (CLI flag: --repair-jellyfin-connections)"
    else
        log_warn "$who is user-managed and Jellyfin rejects its API key. MediaStack leaves it unchanged; update the key in ${app^} under Settings > Connect"
    fi
}

# Normal re-run: report on every existing MediaBrowser record, change none.
_configure_arr_jellyfin_check_records() {
    local app="$1" base="$2" key="$3" records="$4"
    local warned=0 id name kind notify record state who
    while IFS=$'\t' read -r id name kind notify; do
        [[ -n "$id" ]] || continue
        who="${app^} Jellyfin connection '${name}' (id ${id})"
        if [[ "$notify" == "1" ]]; then
            # A test would send a visible message to Jellyfin users.
            log_warn "$who was not tested because it also sends Jellyfin notifications; left unchanged"
            warned=1
            continue
        fi
        if record=$(_configure_arr_jellyfin_fetch_record "$base" "$key" "$id"); then
            state=$(_configure_arr_jellyfin_test_record "$base" "$key" "$record")
        else
            state=unverified
        fi
        case "$state" in
            ok) ;;
            stale)
                _configure_arr_jellyfin_warn_stale "$who" "$kind" "$app"
                warned=1
                ;;
            *)
                log_warn "$who could not be verified; left unchanged"
                warned=1
                ;;
        esac
    done <<<"$records"
    ((warned)) || log_skip "${app^} Jellyfin connection already configured"
}

# PUT one record with the current Jellyfin key, then run the app's connection
# test against what is stored. Success is only reported when that test passes.
_configure_arr_jellyfin_repair_record() {
    local app="$1" base="$2" key="$3" id="$4" name="$5"
    local who="${app^} Jellyfin connection '${name}' (id ${id})" record body attempt
    if ! record=$(_configure_arr_jellyfin_fetch_record "$base" "$key" "$id"); then
        log_error "$who could not be read - nothing changed"
        return 1
    fi
    if ! body=$(JF_KEY="${JELLYFIN_API_KEY}" python3 -c '
import os, sys, json
r = json.load(sys.stdin)
hit = [f for f in r["fields"] if isinstance(f, dict) and f.get("name") == "apiKey"]
if len(hit) != 1:
    sys.exit(1)
hit[0]["value"] = os.environ["JF_KEY"]
json.dump(r, sys.stdout)' <<<"$record" 2>/dev/null); then
        log_error "$who has no apiKey field - nothing changed"
        return 1
    fi

    # The app tests the new key before it saves, so a Jellyfin that is still
    # starting fails the PUT. Retry, but never force-save an unverified key.
    local saved=0
    for attempt in 1 2 3; do
        if api_put "$base/notification/$id" "$key" "$body" >/dev/null 2>&1; then
            saved=1
            break
        fi
        sleep $((attempt * 3))
    done
    if ((!saved)); then
        log_error "$who: ${app^} rejected the new Jellyfin API key - nothing changed"
        return 1
    fi

    if ! record=$(_configure_arr_jellyfin_fetch_record "$base" "$key" "$id") \
        || [[ "$(_configure_arr_jellyfin_test_record "$base" "$key" "$record")" != ok ]]; then
        log_error "$who: key replaced but the connection test failed"
        return 1
    fi
    log_ok "$who: Jellyfin API key replaced; connection test passed"
}

# Explicit, confirmed repair for one app. Replaces only the stale Jellyfin API
# key in MediaStack-created records; user-managed records are reported and left
# alone. Sends the fetched record back with just that field changed, so the id,
# event selections and every other field survive. Returns 1 if any step failed.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_jellyfin_repair() {
    local app="$1" base="$2" key="$3"
    if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
        log_warn "JELLYFIN_API_KEY not set - cannot repair the ${app^} Jellyfin connection"
        return 1
    fi

    local existing records
    if ! existing=$(api_get "$base/notification" "$key") || ! records=$(_configure_arr_jellyfin_records <<<"$existing"); then
        log_error "Could not read ${app^} notifications - nothing changed"
        return 1
    fi
    if [[ -z "$records" ]]; then
        log_skip "${app^} has no Jellyfin connection to repair"
        return 0
    fi

    local id name kind notify record state who rc=0
    local -a stale_ids=() stale_names=()
    while IFS=$'\t' read -r id name kind notify; do
        [[ -n "$id" ]] || continue
        who="${app^} Jellyfin connection '${name}' (id ${id})"
        if [[ "$notify" == "1" ]]; then
            log_warn "$who was not tested because it also sends Jellyfin notifications; left unchanged"
            continue
        fi
        if ! record=$(_configure_arr_jellyfin_fetch_record "$base" "$key" "$id"); then
            log_warn "$who could not be read; left unchanged"
            rc=1
            continue
        fi
        state=$(_configure_arr_jellyfin_test_record "$base" "$key" "$record")
        if [[ "$state" == "ok" ]]; then
            log_ok "$who: Jellyfin accepts its API key; unchanged"
        elif [[ "$state" == "stale" && "$kind" == "managed" ]]; then
            stale_ids+=("$id")
            stale_names+=("$name")
        elif [[ "$state" == "stale" ]]; then
            _configure_arr_jellyfin_warn_stale "$who" "$kind" "$app"
        else
            log_warn "$who could not be verified; left unchanged"
            rc=1
        fi
    done <<<"$records"

    ((${#stale_ids[@]})) || return "$rc"

    local i
    for i in "${!stale_ids[@]}"; do
        log_info "${app^} record '${stale_names[i]}' (id ${stale_ids[i]}) is MediaStack-created (name ${_ARR_JF_NAME}, ${_ARR_JF_HOST}:${_ARR_JF_PORT}) and Jellyfin rejects its stored API key"
    done
    if ! ui_confirm "Replace the Jellyfin API key in ${#stale_ids[@]} ${app^} connection(s)?" no; then
        log_info "No change."
        return "$rc"
    fi
    for i in "${!stale_ids[@]}"; do
        _configure_arr_jellyfin_repair_record "$app" "$base" "$key" "${stale_ids[i]}" "${stale_names[i]}" || rc=1
    done
    return "$rc"
}

# Repair both apps. Respects manual app wiring and skips an app that is not up.
configure_arr_jellyfin_repair_all() {
    if storage_is_manual; then
        log_skip "Jellyfin connection repair skipped (manual app wiring)"
        return 0
    fi
    local rc=0 app app_key
    for app in sonarr radarr; do
        if ! service_container_running "$app"; then
            log_skip "${app^} is not running - skipped"
            continue
        fi
        app_key=$(api_get_key "$SCRIPT_DIR/config/$app/config.xml")
        if [[ -z "$app_key" ]]; then
            log_warn "No ${app^} API key found - skipped"
            rc=1
            continue
        fi
        configure_arr_jellyfin_repair "$app" "$(service_local_url "$app")/api/v3" "$app_key" || rc=1
    done
    return "$rc"
}

# Connect a Sonarr or Radarr instance to Jellyfin so library scans trigger
# automatically on import. Uses the MediaBrowser notification type. An existing
# MediaBrowser record is never rewritten here: each one is tested and a stale
# key is reported with the explicit repair action (configure_arr_jellyfin_repair).
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_jellyfin_connection() {
    local app="$1" base="$2" key="$3"

    local jf_key="${JELLYFIN_API_KEY:-}"
    if [[ -z "$jf_key" ]]; then
        log_warn "JELLYFIN_API_KEY not set - skipping ${app^} Jellyfin connection"
        return 0
    fi

    local existing records
    if ! existing=$(api_get "$base/notification" "$key"); then
        sleep 5
        if ! existing=$(api_get "$base/notification" "$key"); then
            log_warn "Could not fetch ${app^} notifications - skipping Jellyfin connection"
            return 0
        fi
    fi
    # Fail closed: an unreadable list must never read as "no connection yet",
    # or the add path below would create a duplicate record.
    if ! records=$(_configure_arr_jellyfin_records <<<"$existing"); then
        log_warn "Could not read ${app^} notifications - skipping Jellyfin connection"
        return 0
    fi

    if [[ -n "$records" ]]; then
        _configure_arr_jellyfin_check_records "$app" "$base" "$key" "$records"
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

    # POST /notification runs a provider Test() before saving, which reads
    # Jellyfin's configuration. The test can transiently fail if Jellyfin just
    # restarted and isn't ready yet.
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

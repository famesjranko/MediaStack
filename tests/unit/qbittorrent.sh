#!/usr/bin/env bash
# tests/unit/qbittorrent.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="qbittorrent"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CURL_LOG="$TMP_DIR/curl.log"

source "$REPO_ROOT/scripts/services/qbittorrent/main.sh"

BOLD=""
NC=""
JELLYFIN_ADMIN_USER='mediaadmin'
JELLYFIN_ADMIN_PASSWORD='abc&% =defghi'
TORRENT_PORT=6881
QBT_DL_LIMIT=1
QBT_UL_LIMIT=1

LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
log_ok() { LOG_OK_MESSAGES+=("$1"); }
log_warn() { LOG_WARN_MESSAGES+=("$1"); }
log_skip() { :; }

cfg_field() {
    case "$1" in
        qbittorrent.save_path) echo "/data/torrents/all&media" ;;
        qbittorrent.temp_path) echo "/data/torrents/incomplete=tmp" ;;
        qbittorrent.max_ratio) echo "2.0" ;;
        qbittorrent.max_seeding_time) echo "1440" ;;
        qbittorrent.max_active_downloads) echo "3" ;;
        qbittorrent.max_active_uploads) echo "3" ;;
        qbittorrent.max_active_torrents) echo "6" ;;
        qbittorrent.dl_speed_limit|qbittorrent.ul_speed_limit) echo "0" ;;
        *) echo "" ;;
    esac
}

cfg_qbt_categories() {
    printf '%s\n' \
        'tv-sonarr:/data/torrents/tv&specials' \
        'movie=radarr:/data/torrents/movies=all'
}

API_FETCH_COUNT_FILE="$TMP_DIR/api-fetch-count"
DOCKER_LOG_COUNT_FILE="$TMP_DIR/docker-log-count"
api_fetch() {
    local count=0
    [[ -f "$API_FETCH_COUNT_FILE" ]] && count=$(<"$API_FETCH_COUNT_FILE")
    count=$((count + 1))
    printf '%s' "$count" > "$API_FETCH_COUNT_FILE"
    if [[ "${QBT_VERIFY_CATEGORY_AFTER_EDIT_FAIL:-0}" == "1" && "$count" -gt 1 ]]; then
        printf '%s\n' '{"tv-sonarr":{"name":"tv-sonarr","savePath":"/data/torrents/tv&specials"},"movie=radarr":{"name":"movie=radarr","savePath":"/data/torrents/movies=all"}}'
    else
        printf '%s\n' '{}'
    fi
}

sleep() { :; }

docker() {
    if [[ "${1:-}" == "compose" && "${2:-}" == "logs" && "${3:-}" == "qbittorrent" ]]; then
        local count=0
        [[ -f "$DOCKER_LOG_COUNT_FILE" ]] && count=$(<"$DOCKER_LOG_COUNT_FILE")
        count=$((count + 1))
        printf '%s' "$count" > "$DOCKER_LOG_COUNT_FILE"
        printf '%s\n' 'The WebUI administrator username is: admin'
        if [[ "${QBT_DELAY_TEMP_LOGS:-0}" == "1" && "$count" -lt 3 ]]; then
            return 0
        fi
        printf '%s\n' 'The WebUI administrator password was not set. A temporary password is provided for this session: temp&pass=1'
        return 0
    fi
    return 1
}

curl() {
    local arg prev="" endpoint="" is_login=false password="" category=""
    for arg in "$@"; do
        printf '%s\t' "$arg" >> "$CURL_LOG"
        if [[ "$arg" == *"/api/v2/auth/login" ]]; then
            is_login=true
        fi
        if [[ "$arg" == *"/api/v2/torrents/createCategory" ]]; then
            endpoint="createCategory"
        fi
        if [[ "$arg" == *"/api/v2/torrents/editCategory" ]]; then
            endpoint="editCategory"
        fi
        if [[ "$prev" == "--data-urlencode" && "$arg" == password=* ]]; then
            password="${arg#password=}"
        fi
        if [[ "$prev" == "--data-urlencode" && "$arg" == category=* ]]; then
            category="${arg#category=}"
        fi
        prev="$arg"
    done
    printf '\n' >> "$CURL_LOG"

    if $is_login; then
        if [[ "$password" == "temp&pass=1" ]]; then
            if [[ "${QBT_EMPTY_LOGIN_SUCCESS:-0}" == "1" ]]; then
                printf '\n204\n'
            else
                printf '%s\n%s\n' "Ok." "200"
            fi
        else
            printf '%s\n%s\n' "Fails." "200"
        fi
        return 0
    fi
    if [[ "$endpoint" == "createCategory" && "${QBT_FAIL_CREATE_CATEGORY:-}" == "$category" ]]; then
        return 22
    fi
    if [[ "$endpoint" == "editCategory" && "${QBT_FAIL_EDIT_CATEGORY:-}" == "$category" ]]; then
        return 22
    fi
    return 0
}

configure_qbittorrent

curl_log="$(cat "$CURL_LOG")"
assert_contains "$curl_log" $'--data-urlencode\tusername=admin' "qBittorrent login URL-encodes username form field"
assert_contains "$curl_log" $'--data-urlencode\tusername=mediaadmin' "qBittorrent tries the shared admin username on re-run"
assert_contains "$curl_log" $'--data-urlencode\tpassword=abc&% =defghi' "qBittorrent login URL-encodes passwords with form metacharacters"

raw_form_count=$(grep -c $'\t-d\t' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$raw_form_count" "qBittorrent never sends raw form data for user/config values"

json_encoded_count=$(awk -F'\t' '
    /\/api\/v2\/app\/setPreferences/ {
        for (i = 1; i < NF; i++) {
            if ($i == "--data-urlencode" && $(i + 1) ~ /^json=/) count++
        }
    }
    END { print count + 0 }
' "$CURL_LOG")
assert_eq "2" "$json_encoded_count" "qBittorrent URL-encodes both preference and password JSON payloads"

managed_pref_summary=$(python3 - "$CURL_LOG" <<'PY'
import json
import sys

for raw in open(sys.argv[1], encoding="utf-8"):
    fields = raw.rstrip("\n").split("\t")
    if not any("/api/v2/app/setPreferences" in field for field in fields):
        continue
    for index, field in enumerate(fields[:-1]):
        if field == "--data-urlencode" and fields[index + 1].startswith("json="):
            payload = json.loads(fields[index + 1][len("json="):])
            if "save_path" in payload:
                print(payload.get("save_path", ""))
                print(payload.get("temp_path", ""))
                print(str(payload.get("temp_path_enabled", "")))
                raise SystemExit(0)
raise SystemExit(1)
PY
)
mapfile -t managed_pref_lines <<< "$managed_pref_summary"
assert_eq "/data/torrents/all&media" "${managed_pref_lines[0]:-}" "qBittorrent managed mode sets save path from config.yml"
assert_eq "/data/torrents/incomplete=tmp" "${managed_pref_lines[1]:-}" "qBittorrent managed mode sets temp path from config.yml"
assert_eq "True" "${managed_pref_lines[2]:-}" "qBittorrent managed mode enables temp path"

auth_pref_summary=$(python3 - "$CURL_LOG" <<'PY'
import json
import sys

for raw in open(sys.argv[1], encoding="utf-8"):
    fields = raw.rstrip("\n").split("\t")
    if not any("/api/v2/app/setPreferences" in field for field in fields):
        continue
    for index, field in enumerate(fields[:-1]):
        if field == "--data-urlencode" and fields[index + 1].startswith("json="):
            payload = json.loads(fields[index + 1][len("json="):])
            if "web_ui_username" in payload:
                print(payload.get("web_ui_username", ""))
                print(payload.get("web_ui_password", ""))
                raise SystemExit(0)
raise SystemExit(1)
PY
)
mapfile -t auth_pref_lines <<< "$auth_pref_summary"
assert_eq "mediaadmin" "${auth_pref_lines[0]:-}" "qBittorrent WebUI username is set to shared admin user"
assert_eq "abc&% =defghi" "${auth_pref_lines[1]:-}" "qBittorrent WebUI password is set to shared admin password"

category_encoded_count=$(awk -F'\t' '
    /\/api\/v2\/torrents\/(createCategory|editCategory)/ {
        has_category = 0
        has_save_path = 0
        for (i = 1; i < NF; i++) {
            if ($i == "--data-urlencode" && $(i + 1) ~ /^category=/) has_category = 1
            if ($i == "--data-urlencode" && $(i + 1) ~ /^savePath=/) has_save_path = 1
        }
        if (has_category && has_save_path) count++
    }
    END { print count + 0 }
' "$CURL_LOG")
assert_eq "4" "$category_encoded_count" "qBittorrent URL-encodes category and savePath form fields"
assert_contains "$curl_log" $'--data-urlencode\tsavePath=/data/torrents/tv&specials' "qBittorrent managed mode writes TV category path"
assert_contains "$curl_log" $'--data-urlencode\tsavePath=/data/torrents/movies=all' "qBittorrent managed mode writes movie category path"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
QBT_DELAY_TEMP_LOGS=1
configure_qbittorrent
unset QBT_DELAY_TEMP_LOGS

warn_count=$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}" | grep -c . 2>/dev/null || true)
assert_eq "0" "$warn_count" "qBittorrent waits for delayed first-run temporary password"
assert_eq "3" "$(<"$DOCKER_LOG_COUNT_FILE")" "qBittorrent polls logs until temporary password appears"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
QBT_EMPTY_LOGIN_SUCCESS=1
configure_qbittorrent
unset QBT_EMPTY_LOGIN_SUCCESS

warn_count=$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}" | grep -c . 2>/dev/null || true)
assert_eq "0" "$warn_count" "qBittorrent accepts HTTP 204 empty login success"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
QBT_FAIL_EDIT_CATEGORY="tv-sonarr"
QBT_VERIFY_CATEGORY_AFTER_EDIT_FAIL=1
configure_qbittorrent
unset QBT_FAIL_EDIT_CATEGORY QBT_VERIFY_CATEGORY_AFTER_EDIT_FAIL

warn_count=$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}" | grep -c . 2>/dev/null || true)
ok_log=$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")
assert_eq "0" "$warn_count" "qBittorrent verifies category state after editCategory false negative"
assert_contains "$ok_log" "Category: tv-sonarr -> /data/torrents/tv&specials" "qBittorrent logs category success when follow-up fetch verifies it"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
QBT_FAIL_EDIT_CATEGORY="tv-sonarr"
configure_qbittorrent
unset QBT_FAIL_EDIT_CATEGORY

warn_log=$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}")
ok_log=$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")
assert_contains "$warn_log" "Failed to set qBittorrent category: tv-sonarr -> /data/torrents/tv&specials" "qBittorrent warns when category edit fails"
failed_category_ok_count=$(printf '%s\n' "$ok_log" | grep -Fxc "Category: tv-sonarr -> /data/torrents/tv&specials" 2>/dev/null || true)
assert_eq "0" "$failed_category_ok_count" "qBittorrent does not log category success when edit fails"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
QBT_FAIL_CREATE_CATEGORY="tv-sonarr"
configure_qbittorrent
unset QBT_FAIL_CREATE_CATEGORY

warn_count=$(printf '%s\n' "${LOG_WARN_MESSAGES[@]}" | grep -c . 2>/dev/null || true)
ok_log=$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")
assert_eq "0" "$warn_count" "qBittorrent ignores create-category conflicts when edit succeeds"
assert_contains "$ok_log" "Category: tv-sonarr -> /data/torrents/tv&specials" "qBittorrent logs category success after edit succeeds"

: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
rm -f "$API_FETCH_COUNT_FILE" "$DOCKER_LOG_COUNT_FILE"
storage_is_manual() { return 0; }
configure_qbittorrent
unset -f storage_is_manual

manual_pref_has_managed_paths=$(python3 - "$CURL_LOG" <<'PY'
import json
import sys

for raw in open(sys.argv[1], encoding="utf-8"):
    fields = raw.rstrip("\n").split("\t")
    if not any("/api/v2/app/setPreferences" in field for field in fields):
        continue
    for index, field in enumerate(fields[:-1]):
        if field == "--data-urlencode" and fields[index + 1].startswith("json="):
            payload = json.loads(fields[index + 1][len("json="):])
            if "web_ui_password" in payload:
                continue
            print(any(key in payload for key in ("save_path", "temp_path", "temp_path_enabled")))
            raise SystemExit(0)
raise SystemExit(1)
PY
)
assert_eq "False" "$manual_pref_has_managed_paths" "qBittorrent manual mode omits save/temp path preferences"

manual_category_calls=$(grep -c '/api/v2/torrents/\(createCategory\|editCategory\)' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$manual_category_calls" "qBittorrent manual mode skips managed categories"

LIVE_BIN="$TMP_DIR/live-bin"
LIVE_ENV="$TMP_DIR/live.env"
LIVE_CONFIG="$TMP_DIR/live-config.yml"
mkdir -p "$LIVE_BIN"
cat > "$LIVE_BIN/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        */api/v2/auth/login)
            printf 'Ok.\n200\n'
            exit 0
            ;;
        */api/v2/app/preferences)
            printf '%s\n' '{"max_ratio_act":0,"dl_limit":0,"up_limit":1048576,"max_seeding_time":1440,"max_seeding_time_enabled":true,"bypass_auth_subnet_whitelist":"172.16.0.0/12","bypass_auth_subnet_whitelist_enabled":true,"save_path":"/data/torrents","temp_path":"/data/torrents/incomplete","temp_path_enabled":true}'
            exit 0
            ;;
        */api/v2/torrents/categories)
            printf '%s\n' '{"tv-sonarr":{"savePath":"/data/torrents/tv"},"radarr":{"savePath":"/data/torrents/movies"}}'
            exit 0
            ;;
    esac
done
exit 22
SH
chmod +x "$LIVE_BIN/curl"
cat > "$LIVE_ENV" <<'EOF'
JELLYFIN_ADMIN_USER='mediaadmin'
JELLYFIN_ADMIN_PASSWORD='abc&% =defghi'
QBT_DL_LIMIT=0
QBT_UL_LIMIT=1
STORAGE_APP_WIRING=managed
EOF
cat > "$LIVE_CONFIG" <<'EOF'
qbittorrent:
  save_path: "/data/torrents"
  temp_path: "/data/torrents/incomplete"
  max_seeding_time: 1440
  dl_speed_limit: 0
  ul_speed_limit: 0
  categories:
    tv-sonarr: "/data/torrents/tv"
    radarr: "/data/torrents/movies"
EOF
live_out=$(PATH="$LIVE_BIN:$PATH" bash "$REPO_ROOT/tests/assertions/qbittorrent-live.sh" \
    --url http://qbittorrent:8080 \
    --env "$LIVE_ENV" \
    --config "$LIVE_CONFIG")
live_rc=$?
assert_eq "0" "$live_rc" "qBittorrent live assertion succeeds against expected API state"
live_fail_count=$(printf '%s\n' "$live_out" | grep -c '^FAIL' 2>/dev/null || true)
assert_eq "0" "$live_fail_count" "qBittorrent live assertion emits no failures for expected API state"
assert_contains "$live_out" $'PASS\tstep 1 qBittorrent: shared admin credentials authenticate' "qBittorrent live assertion checks shared admin login"
assert_contains "$live_out" $'PASS\tstep 1 qBittorrent: category radarr save path' "qBittorrent live assertion checks managed categories"

# ---------------------------------------------------------------------------
# Day-2 qbt_set_speed_limits (#50): focused, single-setting live apply.
# Re-auths with the shared admin creds (NOT the temp password) and POSTs ONLY
# dl_limit/up_limit — invariant #2 (no broad reconcile). A fresh curl mock that
# accepts the shared creds; the file-wide mock only blesses the temp password.
# ---------------------------------------------------------------------------
: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
curl() {
    local arg is_login=false
    for arg in "$@"; do
        printf '%s\t' "$arg" >> "$CURL_LOG"
        [[ "$arg" == *"/api/v2/auth/login" ]] && is_login=true
    done
    printf '\n' >> "$CURL_LOG"
    if $is_login; then printf '%s\n%s\n' "Ok." "200"; return 0; fi
    return 0   # setPreferences success
}

qbt_set_speed_limits 5 2
day2_rc=$?
assert_eq "0" "$day2_rc" "qbt_set_speed_limits: returns success on apply"

day2_log="$(cat "$CURL_LOG")"
assert_contains "$day2_log" $'--data-urlencode\tusername=mediaadmin' "qbt_set_speed_limits: re-auths with the shared admin username"
ok_log=$(printf '%s\n' "${LOG_OK_MESSAGES[@]}")
assert_contains "$ok_log" "qBittorrent speed limits updated" "qbt_set_speed_limits: logs success"

# The setPreferences payload must carry ONLY dl_limit + up_limit (no save_path,
# web_ui_*, max_ratio, categories) and convert MB/s -> bytes/s correctly.
day2_payload=$(python3 - "$CURL_LOG" <<'PY'
import json, sys
for raw in open(sys.argv[1], encoding="utf-8"):
    fields = raw.rstrip("\n").split("\t")
    if not any("/api/v2/app/setPreferences" in f for f in fields):
        continue
    for i, f in enumerate(fields[:-1]):
        if f == "--data-urlencode" and fields[i + 1].startswith("json="):
            payload = json.loads(fields[i + 1][len("json="):])
            print(",".join(sorted(payload.keys())))
            print(payload.get("dl_limit", ""))
            print(payload.get("up_limit", ""))
            raise SystemExit(0)
raise SystemExit(1)
PY
)
mapfile -t day2_lines <<< "$day2_payload"
assert_eq "dl_limit,up_limit" "${day2_lines[0]:-}" "qbt_set_speed_limits: posts ONLY dl_limit + up_limit (invariant #2)"
assert_eq "5242880" "${day2_lines[1]:-}" "qbt_set_speed_limits: download 5 MB/s -> 5242880 bytes/s"
assert_eq "2097152" "${day2_lines[2]:-}" "qbt_set_speed_limits: upload 2 MB/s -> 2097152 bytes/s"

setpref_calls=$(grep -c '/api/v2/app/setPreferences' "$CURL_LOG" 2>/dev/null || true)
assert_eq "1" "$setpref_calls" "qbt_set_speed_limits: a single setPreferences call (no broad reconcile)"

# Missing shared password -> warn + non-zero, no API traffic.
: > "$CURL_LOG"
LOG_OK_MESSAGES=()
LOG_WARN_MESSAGES=()
( JELLYFIN_ADMIN_PASSWORD="" qbt_set_speed_limits 3 1 ); noauth_rc=$?
assert_eq "1" "$noauth_rc" "qbt_set_speed_limits: fails when shared admin password is unset"

scenario_end "$CURRENT_SCENARIO"
summary

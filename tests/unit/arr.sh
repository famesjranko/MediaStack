#!/usr/bin/env bash
# tests/unit/arr.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="arr"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PUT_BODY="$TMP_DIR/arr-auth.json"
PUT_COUNT="$TMP_DIR/put.count"

source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/lib/arr/main.sh"

BOLD=""
NC=""
JELLYFIN_ADMIN_USER='admin\nuser'
JELLYFIN_ADMIN_PASSWORD='alpha\nbravo\tcharlie\u0031\\end'

log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
service_local_url() {
    case "$1" in
        sonarr) printf 'http://localhost:8989' ;;
        radarr) printf 'http://localhost:7878' ;;
        jackett) printf 'http://localhost:9117' ;;
        *) return 1 ;;
    esac
}
service_internal_url() {
    case "$1" in
        jackett) printf 'http://jackett:9117' ;;
        *) return 1 ;;
    esac
}
post_restart_wait() { return 0; }

api_get() {
    printf '%s\n' '{"authenticationMethod":"none","authenticationRequired":"disabled","existing":"kept"}'
}

api_put() {
    printf '%s' "$3" >"$PUT_BODY"
    local count=0
    [[ -f "$PUT_COUNT" ]] && count=$(<"$PUT_COUNT")
    printf '%s\n' "$((count + 1))" >"$PUT_COUNT"
    return 0
}

docker() { return 0; }
curl() { return 0; }

configure_arr_auth "sonarr" "http://localhost:8989/api/v3" "api-key"

put_calls="$(cat "$PUT_COUNT" 2>/dev/null || echo 0)"
assert_eq "1" "$put_calls" "Sonarr auth writes host config when forms auth is absent"

mapfile -t auth_lines < <(
    python3 - "$PUT_BODY" "$JELLYFIN_ADMIN_USER" "$JELLYFIN_ADMIN_PASSWORD" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    body = json.load(fh)

want_user = sys.argv[2]
want_pw = sys.argv[3]

print(body.get("authenticationMethod", ""))
print(body.get("authenticationRequired", ""))
print(body.get("username") == want_user)
print(body.get("password") == want_pw)
print(body.get("passwordConfirmation") == want_pw)
print(body.get("existing", ""))
PY
)

assert_eq "forms" "${auth_lines[0]:-}" "Sonarr auth enables forms authentication"
assert_eq "enabled" "${auth_lines[1]:-}" "Sonarr auth requires authentication"
assert_eq "True" "${auth_lines[2]:-}" "Sonarr auth preserves username backslash escapes"
assert_eq "True" "${auth_lines[3]:-}" "Sonarr auth preserves password backslash escapes"
assert_eq "True" "${auth_lines[4]:-}" "Sonarr auth confirms password without escape corruption"
assert_eq "kept" "${auth_lines[5]:-}" "Sonarr auth preserves unrelated host config fields"

: >"$PUT_BODY"
printf '%s\n' 0 >"$PUT_COUNT"
configure_arr_auth "radarr" "http://localhost:7878/api/v3" "api-key"

radarr_pw_preserved=$(
    python3 - "$PUT_BODY" "$JELLYFIN_ADMIN_PASSWORD" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    body = json.load(fh)

print(body.get("password") == sys.argv[2])
PY
)
assert_eq "True" "$radarr_pw_preserved" "Radarr auth preserves password backslash escapes"

POST_BODY="$TMP_DIR/root-folder.json"
POST_COUNT="$TMP_DIR/post.count"
ROOT_FOLDER_WANT='/data/media/tv "quoted" \ slash'

cfg_field() {
    case "$1" in
        sonarr.root_folder) printf '%s\n' "$ROOT_FOLDER_WANT" ;;
        *) return 1 ;;
    esac
}

api_get() {
    printf '%s\n' '[]'
}

api_post() {
    printf '%s' "$3" >"$POST_BODY"
    local count=0
    [[ -f "$POST_COUNT" ]] && count=$(<"$POST_COUNT")
    printf '%s\n' "$((count + 1))" >"$POST_COUNT"
    return 0
}

configure_arr_root_folder "sonarr" "http://localhost:8989/api/v3" "api-key"

post_calls="$(cat "$POST_COUNT" 2>/dev/null || echo 0)"
assert_eq "1" "$post_calls" "Sonarr root folder is created when absent"

root_preserved=$(
    python3 - "$POST_BODY" "$ROOT_FOLDER_WANT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    body = json.load(fh)

print(body.get("path") == sys.argv[2])
PY
)
assert_eq "True" "$root_preserved" "Sonarr root folder JSON preserves quotes and backslashes"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/seerr.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="seerr"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$TMP_DIR"
PROFILE_NAME="1080p Balanced O'Brian \\u0031"
SONARR_BODY="$TMP_DIR/sonarr-body.json"
RADARR_BODY="$TMP_DIR/radarr-body.json"

mkdir -p "$SCRIPT_DIR/config/sonarr" "$SCRIPT_DIR/config/radarr"
printf '%s\n' '<Config><ApiKey>sonarr-key</ApiKey></Config>' > "$SCRIPT_DIR/config/sonarr/config.xml"
printf '%s\n' '<Config><ApiKey>radarr-key</ApiKey></Config>' > "$SCRIPT_DIR/config/radarr/config.xml"

source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/services/seerr/arr_connect.sh"

log_skip() { :; }
log_warn() { :; }

get_api_key() {
    case "$1" in
        *sonarr*) printf '%s\n' "sonarr-key" ;;
        *radarr*) printf '%s\n' "radarr-key" ;;
        *) printf '%s\n' "" ;;
    esac
}

cfg_field() {
    case "$1" in
        quality_profile.name) printf '%s\n' "$PROFILE_NAME" ;;
        sonarr.root_folder) printf '%s\n' "/data/media/tv" ;;
        radarr.root_folder) printf '%s\n' "/data/media/movies" ;;
        *) return 1 ;;
    esac
}

api_fetch() {
    printf '%s\n' "[]"
}

api_get() {
    case "$1" in
        *qualityprofile*)
            PROFILE_NAME="$PROFILE_NAME" python3 -c '
import os, json
print(json.dumps([
    {"id": 1, "name": "Any"},
    {"id": 44, "name": os.environ["PROFILE_NAME"]},
]))
'
            ;;
        *languageprofile*)
            printf '%s\n' '[{"id":7}]'
            ;;
        *)
            printf '%s\n' "[]"
            ;;
    esac
}

js_post() {
    case "$1" in
        Sonarr) printf '%s' "$3" > "$SONARR_BODY" ;;
        Radarr) printf '%s' "$3" > "$RADARR_BODY" ;;
        *) return 1 ;;
    esac
}

connect_arr_to_seerr sonarr 8989 "http://localhost:5055" "$TMP_DIR/cookie"
connect_arr_to_seerr radarr 7878 "http://localhost:5055" "$TMP_DIR/cookie"

mapfile -t sonarr_lines < <(WANT_PROFILE="$PROFILE_NAME" python3 - "$SONARR_BODY" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    body = json.load(fh)

print(body.get("activeProfileId"))
print(body.get("activeProfileName") == os.environ["WANT_PROFILE"])
print(body.get("activeDirectory"))
print(body.get("activeLanguageProfileId"))
PY
)

assert_eq "44" "${sonarr_lines[0]:-}" "Seerr Sonarr profile id resolves configured quoted profile"
assert_eq "True" "${sonarr_lines[1]:-}" "Seerr Sonarr profile name preserves quote and backslash"
assert_eq "/data/media/tv" "${sonarr_lines[2]:-}" "Seerr Sonarr payload keeps configured root folder"
assert_eq "7" "${sonarr_lines[3]:-}" "Seerr Sonarr payload keeps language profile id"

mapfile -t radarr_lines < <(WANT_PROFILE="$PROFILE_NAME" python3 - "$RADARR_BODY" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    body = json.load(fh)

print(body.get("activeProfileId"))
print(body.get("activeProfileName") == os.environ["WANT_PROFILE"])
print(body.get("activeDirectory"))
print(body.get("minimumAvailability"))
PY
)

assert_eq "44" "${radarr_lines[0]:-}" "Seerr Radarr profile id resolves configured quoted profile"
assert_eq "True" "${radarr_lines[1]:-}" "Seerr Radarr profile name preserves quote and backslash"
assert_eq "/data/media/movies" "${radarr_lines[2]:-}" "Seerr Radarr payload keeps configured root folder"
assert_eq "released" "${radarr_lines[3]:-}" "Seerr Radarr payload keeps minimum availability"

scenario_end "$CURRENT_SCENARIO"
summary

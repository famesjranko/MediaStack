#!/usr/bin/env bash
# tests/unit/homepage-jellyfin-version.sh
#
# Guards Jellyfin's Homepage widget API selection and its fail-closed write.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/services/homepage/main.sh"

CURRENT_SCENARIO="homepage-jellyfin-version"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SCRIPT_DIR="$TMP_DIR"
HOST_ADDRESS="10.0.0.5"
JELLYFIN_API_KEY="widget-key"
CURL_LOG="$TMP_DIR/curl.log"
PROBE_BODY=""
PROBE_RC=0
PROBE_STATUS=200

service_container_running() { return 1; }
storage_is_nas() { return 1; }
curl() {
    printf '%s\n' "$*" >>"$CURL_LOG"
    printf '%s' "$PROBE_BODY"
    printf '\n%s' "$PROBE_STATUS"
    return "$PROBE_RC"
}

fresh_config() {
    rm -rf "$TMP_DIR/config"
    mkdir -p "$TMP_DIR/config/homepage"
    : >"$CURL_LOG"
}

widget_version() {
    python3 -c '
import sys, yaml
services = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
widget = services[0]["Media"][0]["Jellyfin"]["widget"]
version = widget["version"]
if type(version) is not int:
    raise SystemExit("Jellyfin widget version is not an int")
print(version)
' "$TMP_DIR/config/homepage/services.yaml"
}

valid_body() {
    python3 -c '
import json, sys
size = int(sys.argv[1])
prefix = json.dumps({"Version": "12.3.0", "Padding": ""}, separators=(",", ":"))
padding = size - len(prefix)
if padding < 0:
    raise SystemExit("requested body is too small")
print(prefix[:-2] + "x" * padding + "\"}", end="")
' "$1"
}

render_known_version() {
    local version="$1" expected="$2" label="$3" out

    # Given a final Jellyfin public version.
    fresh_config
    PROBE_BODY=$(printf '{"Version":"%s"}' "$version")
    PROBE_RC=0
    PROBE_STATUS=200

    # When Homepage renders its widget.
    out=$(configure_homepage 2>&1)

    # Then the widget version is the expected YAML integer.
    assert_eq "$expected" "$(widget_version)" "$label uses integer mode $expected"
    assert_contains "$out" "services.yaml generated" "$label generates services"
}

render_known_version "10.11.9" 1 "10.11.x"
render_known_version "10.12.0" 2 "10.12.0"
render_known_version "12.3.0" 2 "12.3.0"
render_known_version "10.12.0.7" 2 "numeric revision"

# Given Stable, Latest, and an explicit image override.
export IMAGE_CHANNEL=stable
render_known_version "10.11.9" 1 "Stable old image"
export IMAGE_CHANNEL=latest
render_known_version "10.11.9" 1 "Latest old image"
export MS_TEST_IMAGE_OVERRIDES="jellyfin=example.invalid/jellyfin:override"
render_known_version "12.3.0" 2 "explicit image override"
unset IMAGE_CHANNEL MS_TEST_IMAGE_OVERRIDES

# Given discovery transport requirements.
# When the public endpoint is called.
# Then it has bounded timeouts, no redirect flag, and uses the host-side URL.
assert_contains "$(cat "$CURL_LOG")" "--connect-timeout 2 --max-time 5 --write-out \\n%{http_code} http://localhost:8096/System/Info/Public" "probe uses bounded local public endpoint"
assert_not_contains "$(cat "$CURL_LOG")" "--location" "probe refuses redirects"

unknown_preserves_existing() {
    local body="$1" rc="$2" label="$3" status="${4:-200}" out before_file

    # Given a saved dashboard with a trailing-newline sentinel and an unknown response.
    fresh_config
    before_file="$TMP_DIR/before-services.yaml"
    printf 'manual: keep-this-byte-for-byte\n# trailing-newline sentinel\n' >"$before_file"
    cp "$before_file" "$TMP_DIR/config/homepage/services.yaml"
    PROBE_BODY="$body"
    PROBE_RC="$rc"
    PROBE_STATUS="$status"

    # When Homepage configures.
    out=$(configure_homepage 2>&1)

    # Then it preserves every byte and reports the unknown discovery.
    cmp -s "$before_file" "$TMP_DIR/config/homepage/services.yaml"
    assert_eq 0 "$?" "$label preserves existing bytes"
    assert_contains "$out" "version discovery failed" "$label warns visibly"
}

unknown_preserves_existing '{"Version":"10.12.0-rc.1"}' 0 "prerelease"
unknown_preserves_existing '{"Version":"unknown"}' 0 "unknown version"
unknown_preserves_existing '{"Version":"１０.１２.０"}' 0 "non-ASCII version"
unknown_preserves_existing '{"Version":12}' 0 "non-string version"
unknown_preserves_existing '{}' 0 "missing version"
unknown_preserves_existing 'not json' 0 "malformed response"
unknown_preserves_existing "$(valid_body 65537)" 0 "valid oversized response"
unknown_preserves_existing '{"Version":"12.3.0"}' 18 "partial valid transport"
unknown_preserves_existing '{"Version":"12.3.0"}' 0 "non-200 response" 302

# Given a valid response body at the 65,536-byte boundary.
fresh_config
PROBE_BODY="$(valid_body 65536)"
PROBE_RC=0
PROBE_STATUS=200

# When Homepage configures.
configure_homepage >/dev/null 2>&1

# Then the boundary-sized response is accepted.
assert_eq 2 "$(widget_version)" "65,536-byte response is accepted"

# Given discovery fails before a first render.
fresh_config
PROBE_BODY='{}'
PROBE_RC=0
PROBE_STATUS=200

# When no services file exists.
configure_homepage >/dev/null 2>&1

# Then no guessed widget file is created.
assert_file_absent "$TMP_DIR/config/homepage/services.yaml" "unknown fresh install leaves services file absent"

# Given Jellyfin has no widget credential.
fresh_config
JELLYFIN_API_KEY=""
PROBE_BODY='{"Version":"10.11.9"}'
PROBE_RC=0
PROBE_STATUS=200

# When Homepage renders.
configure_homepage >/dev/null 2>&1

# Then it does not query Jellyfin and omits the widget.
assert_eq "" "$(cat "$CURL_LOG")" "no widget skips discovery"
assert_file_not_contains "$TMP_DIR/config/homepage/services.yaml" "type: jellyfin" "no key omits Jellyfin widget"

# Given the same known version twice.
JELLYFIN_API_KEY="widget-key"
fresh_config
PROBE_BODY='{"Version":"12.3.0"}'
PROBE_RC=0
PROBE_STATUS=200
configure_homepage >/dev/null 2>&1

# When Homepage reruns.
out=$(configure_homepage 2>&1)

# Then the atomic services write is an up-to-date skip.
assert_contains "$out" "services.yaml already up to date" "known-version rerun is stable"

# Given successful discovery but an invalid generator input.
fresh_config
_homepage_jellyfin_widget_version() { printf '2\n'; }
service_http_ports_json() { printf '{'; }

# When Homepage configures.
out=$(configure_homepage 2>&1)

# Then it reports generation failure instead of hiding it.
assert_contains "$out" "Failed to generate Homepage services.yaml" "generator failure remains visible after discovery"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/jellyfin.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="jellyfin"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_ROOT/scripts/services/jellyfin/main.sh"

OK_MESSAGES=()
WARN_MESSAGES=()
MOCK_CURL_RC=0
MOCK_EXISTING_LIBS="[]"
MOCK_NETWORK_JSON=""
MOCK_POST_BODY=""

log_ok() { OK_MESSAGES+=("$1"); }
log_info() { :; }
log_warn() { WARN_MESSAGES+=("$1"); }
log_skip() { :; }

api_fetch() {
    if [[ "$*" == *"/System/Configuration/network"* ]]; then
        if [[ " $* " == *" -X POST "* ]]; then
            local prev=""
            MOCK_POST_BODY=""
            for arg in "$@"; do
                if [[ "$prev" == "-d" ]]; then
                    MOCK_POST_BODY="$arg"
                    break
                fi
                prev="$arg"
            done
            return 0
        fi
        printf '%s\n' "$MOCK_NETWORK_JSON"
        return 0
    fi
    printf '%s\n' "$MOCK_EXISTING_LIBS"
}

cfg_jf_libraries() {
    printf '%s\n' "Movies:movies:/data/media/movies"
}

curl() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == *"/Library/VirtualFolders"* ]]; then
            return "$MOCK_CURL_RC"
        fi
    done
    return 0
}

docker() { return 0; }

save_api_key() { :; }

reset_logs() {
    OK_MESSAGES=()
    WARN_MESSAGES=()
    MOCK_POST_BODY=""
}

reset_logs
MOCK_CURL_RC=0
configure_jellyfin_libraries "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin library create success remains non-fatal"
assert_contains "${OK_MESSAGES[*]:-}" "Library: Movies (/data/media/movies)" \
    "Jellyfin library create success logs OK"
assert_eq "" "${WARN_MESSAGES[*]:-}" "Jellyfin library create success does not warn"

reset_logs
MOCK_CURL_RC=22
configure_jellyfin_libraries "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin library create failure remains non-fatal"
assert_contains "${WARN_MESSAGES[*]:-}" "Failed to create Jellyfin library: Movies (/data/media/movies)" \
    "Jellyfin library create failure logs warning"
case " ${OK_MESSAGES[*]:-} " in
    *" Library: Movies (/data/media/movies) "*) fail "Jellyfin library create failure does not log OK" ;;
    *) pass "Jellyfin library create failure does not log OK" ;;
esac

SCRIPT_DIR="$TMP_DIR"
printf 'JELLYFIN_PUBLISHED_URL=http://192.168.1.50:8096\n' > "$TMP_DIR/.env"

reset_logs
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":["npm","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 MEDIASTACK_NPM_IP=172.29.0.10 \
    configure_jellyfin_networking "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin networking cleanup with mixed KnownProxies remains non-fatal"
cleaned_proxies=$(echo "$MOCK_POST_BODY" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin).get("KnownProxies", [])))')
assert_eq "192.168.1.10" "$cleaned_proxies" "Jellyfin networking cleanup removes managed proxy entries and preserves user proxies"

reset_logs
printf 'JELLYFIN_PUBLISHED_URL=https://jellyfin.fresh.test\n' > "$TMP_DIR/.env"
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":["172.28.0.10","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096","external=https://jellyfin.fresh.test"]}'
REMOTE_WEB_STATE=ready DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 MEDIASTACK_NPM_IP=172.29.0.10 \
    configure_jellyfin_networking "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin networking ready-state with mixed KnownProxies remains non-fatal"
ready_proxies=$(echo "$MOCK_POST_BODY" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin).get("KnownProxies", [])))')
assert_eq "172.29.0.10|192.168.1.10" "$ready_proxies" "Jellyfin networking replaces managed legacy proxy and preserves user proxies"

scenario_end "$CURRENT_SCENARIO"
summary

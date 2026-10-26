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

# For curl_header_stdin/curl_header_data_stdin/api_fetch_auth (secret headers
# off argv - see common.sh/http.sh). All three ultimately call the real
# `curl`, which the stub below overrides at call time, so this stays a pure
# stub test; the file's own api_fetch stub (below) still wins over http.sh's.
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/services/jellyfin/main.sh"

JELLYFIN_POLICY_RENDER="$REPO_ROOT/scripts/services/jellyfin/render/network_policy.py"
OK_MESSAGES=()
WARN_MESSAGES=()
MOCK_CURL_RC=0
MOCK_EXISTING_LIBS="[]"
MOCK_NETWORK_JSON=""
MOCK_POST_BODY=""
MOCK_READY_BODY='{"KnownProxies":[],"PublishedServerUriBySubnet":[]}'
MOCK_READY_STATE_FILE="$TMP_DIR/ready-calls"
MOCK_READY_CODES=()

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

# network.sh's config read/write now go through api_fetch_auth (secret
# Authorization header off argv - see http.sh); the header itself is not
# under test here, so just drop it and reuse the api_fetch stub above.
api_fetch_auth() {
    local label="$1"
    shift 3
    api_fetch "$label" "$@"
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

curl_header_stdin() {
    local out_file="" arg next=false call
    for arg in "$@"; do
        if [[ "$next" == "true" ]]; then
            out_file="$arg"
            next=false
        elif [[ "$arg" == "-o" ]]; then
            next=true
        fi
    done
    printf '%s' "$MOCK_READY_BODY" >"$out_file"
    call=$(<"$MOCK_READY_STATE_FILE")
    printf '%s' "${MOCK_READY_CODES[$call]:-200}"
    printf '%s' "$((call + 1))" >"$MOCK_READY_STATE_FILE"
}

docker() { return 0; }

env_save_api_key() { :; }

reset_logs() {
    OK_MESSAGES=()
    WARN_MESSAGES=()
    MOCK_POST_BODY=""
    MOCK_READY_BODY='{"KnownProxies":[],"PublishedServerUriBySubnet":[]}'
    printf '0' >"$MOCK_READY_STATE_FILE"
    MOCK_READY_CODES=()
}

if bash -euo pipefail -c "SCRIPT_DIR=/tmp; CONFIG_FILE=/dev/null; source '$REPO_ROOT/scripts/services/jellyfin/main.sh'; source '$REPO_ROOT/scripts/services/jellyfin/main.sh'; [[ -x /usr/bin/python3 || -x \$(command -v python3) ]]"; then
    pass "Jellyfin service module can be re-sourced under strict mode"
else
    fail "Jellyfin service module can be re-sourced under strict mode"
fi

policy_env() {
    env REMOTE_READY="${1:-false}" HOST_ADDR="${2:-192.168.1.50}" DOMAIN_VAL="${3:-fresh.test}" NPM_PROXY_IP="${4:-172.29.0.10}" \
        python3 "$JELLYFIN_POLICY_RENDER"
}

policy_json_field() {
    local output="$1" expr="$2"
    printf '%s\n' "$output" | tail -n 1 | python3 -c "import json,sys; data=json.load(sys.stdin); print($expr)"
}

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}' \
    | policy_env false)
assert_eq "SKIP" "$policy_out" "Jellyfin network policy: SKIP protocol is exact"

policy_out=$(printf '%s' '{"AutoDiscovery":false,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}' \
    | policy_env false)
assert_eq $'DRIFT\nAutoDiscovery is False (expected True)' "$policy_out" \
    "Jellyfin network policy: AutoDiscovery false remains drift-only"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":["npm","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}' \
    | policy_env false)
assert_eq "APPLY" "$(printf '%s\n' "$policy_out" | sed -n '1p')" "Jellyfin network policy: cleanup emits APPLY first"
assert_eq "2" "$(printf '%s\n' "$policy_out" | wc -l)" "Jellyfin network policy: APPLY emits exactly action plus JSON"
assert_eq "192.168.1.10" "$(policy_json_field "$policy_out" '"|".join(data.get("KnownProxies", []))')" \
    "Jellyfin network policy: cleanup preserves user proxy"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":["172.28.0.10","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096","external=https://jellyfin.fresh.test"]}' \
    | policy_env true)
assert_eq "APPLY" "$(printf '%s\n' "$policy_out" | sed -n '1p')" "Jellyfin network policy: ready replacement emits APPLY first"
assert_eq "172.29.0.10|192.168.1.10" "$(policy_json_field "$policy_out" '"|".join(data.get("KnownProxies", []))')" \
    "Jellyfin network policy: ready replacement uses selected npm proxy IP"

policy_out=$(printf '%s' '{"AutoDiscovery":false,"KnownProxies":["npm"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}' \
    | policy_env true)
assert_eq "APPLY_WITH_DRIFT" "$(printf '%s\n' "$policy_out" | sed -n '1p')" \
    "Jellyfin network policy: changes plus drift emit APPLY_WITH_DRIFT"
assert_eq "AutoDiscovery is False (expected True)" "$(printf '%s\n' "$policy_out" | sed -n '2p')" \
    "Jellyfin network policy: drift line follows action"
assert_eq "---" "$(printf '%s\n' "$policy_out" | sed -n '3p')" \
    "Jellyfin network policy: separator precedes JSON"
assert_eq "4" "$(printf '%s\n' "$policy_out" | wc -l)" \
    "Jellyfin network policy: APPLY_WITH_DRIFT emits no extra stdout"
assert_eq "False" "$(policy_json_field "$policy_out" 'data.get("AutoDiscovery")')" \
    "Jellyfin network policy: AutoDiscovery is not auto-reconciled"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096","external=https://jellyfin.fresh.test"]}' \
    | env -u NPM_PROXY_IP REMOTE_READY=true HOST_ADDR=192.168.1.50 DOMAIN_VAL=fresh.test python3 "$JELLYFIN_POLICY_RENDER")
assert_eq "172.28.0.10" "$(policy_json_field "$policy_out" '"|".join(data.get("KnownProxies", []))')" \
    "Jellyfin network policy: unset NPM_PROXY_IP falls back to default"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096","external=https://jellyfin.fresh.test"]}' \
    | REMOTE_READY=true HOST_ADDR=192.168.1.50 DOMAIN_VAL=fresh.test NPM_PROXY_IP="" python3 "$JELLYFIN_POLICY_RENDER")
assert_eq "172.28.0.10" "$(policy_json_field "$policy_out" '"|".join(data.get("KnownProxies", []))')" \
    "Jellyfin network policy: empty NPM_PROXY_IP falls back to default"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":"npm","PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}' \
    | policy_env false)
assert_eq "APPLY" "$(printf '%s\n' "$policy_out" | sed -n '1p')" \
    "Jellyfin network policy: non-list KnownProxies is normalized"
assert_eq "" "$(policy_json_field "$policy_out" '"|".join(data.get("KnownProxies", []))')" \
    "Jellyfin network policy: non-list KnownProxies becomes empty"

policy_out=$(printf '%s' '{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["custom=https://example.test"]}' \
    | policy_env false)
assert_eq $'DRIFT\nPublishedServerUriBySubnet is ['"'"'custom=https://example.test'"'"'] (expected ['"'"'internal=http://192.168.1.50:8096'"'"'])' "$policy_out" \
    "Jellyfin network policy: user published URL remains drift-only"

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

log_drift() { DRIFT_MESSAGES+=("$1"); }

# Given a Movies library whose live path differs from config.yml.
reset_logs
DRIFT_MESSAGES=()
MOCK_EXISTING_LIBS='[{"Name":"Movies","Locations":["/data/old-movies"]}]'
# When the Jellyfin libraries are configured.
configure_jellyfin_libraries "http://localhost:8096" "token"
rc=$?
# Then the notice offers keeping the live path or removing the library, and
# does not recommend deleting service data with down -v.
assert_eq "0" "$rc" "Jellyfin library path drift remains non-fatal"
assert_contains "${DRIFT_MESSAGES[*]:-}" "set that library's path in config.yml to the live path" \
    "Jellyfin library path drift offers keeping the live path"
assert_contains "${DRIFT_MESSAGES[*]:-}" "remove 'Movies', then run ./scripts/configure.sh --only jellyfin" \
    "Jellyfin library path drift offers reapplying config.yml"
assert_contains "${DRIFT_MESSAGES[*]:-}" "start without watch history" \
    "Jellyfin library path drift names the history it loses"
assert_not_contains "${DRIFT_MESSAGES[*]:-}" "down -v" \
    "Jellyfin library path drift does not recommend down -v"
MOCK_EXISTING_LIBS="[]"

SCRIPT_DIR="$TMP_DIR"
printf 'JELLYFIN_PUBLISHED_URL=http://192.168.1.50:8096\n' >"$TMP_DIR/.env"

# Given an already-published policy, no restart occurs.
reset_logs
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'

# When networking compares the unchanged policy.
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 \
    configure_jellyfin_networking "http://localhost:8096" "token"

# Then the no-restart path makes no readiness request.
assert_eq "0" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin networking unchanged policy does not poll the API"

# Given a skipped policy whose published URL needs a recreate, the API is loading first.
reset_logs
printf 'JELLYFIN_PUBLISHED_URL=https://jellyfin.fresh.test\n' >"$TMP_DIR/.env"
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'
MOCK_READY_CODES=(503 200)

# When the skipped policy recreates Jellyfin.
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 \
    configure_jellyfin_networking "http://localhost:8096" "token"

# Then the actual skipped-policy caller waits for the typed API instead of /health.
assert_eq "2" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin networking skipped recreate waits for typed API readiness"

# Given a drift-protected policy whose published URL needs a recreate.
reset_logs
MOCK_NETWORK_JSON='{"AutoDiscovery":false,"KnownProxies":[],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'

# When the drift-protected policy recreates Jellyfin.
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 \
    configure_jellyfin_networking "http://localhost:8096" "token"

# Then drift still warns and its owned recreate waits for the API.
assert_eq "1" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin networking drift recreate waits for typed API readiness"

# Given a network policy update that owns a restart.
reset_logs
printf 'JELLYFIN_PUBLISHED_URL=http://192.168.1.50:8096\n' >"$TMP_DIR/.env"
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":["npm"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'

# When networking applies the policy and restarts Jellyfin.
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 \
    configure_jellyfin_networking "http://localhost:8096" "token"

# Then the apply path waits for the typed API before it returns.
assert_eq "1" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin networking apply restart waits for typed API readiness"

# Given permanent API failures or invalid typed data.
reset_logs
MOCK_READY_CODES=(401)

# When readiness receives an unauthorized response.
configure_jellyfin_network_ready "http://localhost:8096" "token" 1
rc=$?

# Then it rejects the response without a retry.
assert_eq "1" "$rc" "Jellyfin network readiness rejects unauthorized API access immediately"
assert_eq "1" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin network readiness does not retry unauthorized API access"

# Given an incomplete typed network policy.
reset_logs
MOCK_READY_BODY='{"KnownProxies":[]}'

# When readiness receives an incomplete policy.
configure_jellyfin_network_ready "http://localhost:8096" "token" 1
rc=$?

# Then it rejects the response without a retry.
assert_eq "1" "$rc" "Jellyfin network readiness rejects an incomplete policy immediately"
assert_eq "1" "$(<"$MOCK_READY_STATE_FILE")" "Jellyfin network readiness does not retry an incomplete policy"

reset_logs
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":["npm","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096"]}'
REMOTE_WEB_STATE=skipped DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 MEDIASTACK_NPM_IP=172.29.0.10 \
    configure_jellyfin_networking "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin networking cleanup with mixed KnownProxies remains non-fatal"
cleaned_proxies=$(echo "$MOCK_POST_BODY" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin).get("KnownProxies", [])))')
assert_eq "192.168.1.10" "$cleaned_proxies" "Jellyfin networking cleanup removes managed proxy entries and preserves user proxies"

reset_logs
printf 'JELLYFIN_PUBLISHED_URL=https://jellyfin.fresh.test\n' >"$TMP_DIR/.env"
MOCK_NETWORK_JSON='{"AutoDiscovery":true,"KnownProxies":["172.28.0.10","192.168.1.10"],"PublishedServerUriBySubnet":["internal=http://192.168.1.50:8096","external=https://jellyfin.fresh.test"]}'
REMOTE_WEB_STATE=ready DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 MEDIASTACK_NPM_IP=172.29.0.10 \
    configure_jellyfin_networking "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin networking ready-state with mixed KnownProxies remains non-fatal"
ready_proxies=$(echo "$MOCK_POST_BODY" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin).get("KnownProxies", [])))')
assert_eq "172.29.0.10|192.168.1.10" "$ready_proxies" "Jellyfin networking replaces managed legacy proxy and preserves user proxies"

reset_logs
MOCK_NETWORK_JSON='{'
REMOTE_WEB_STATE=ready DOMAIN=fresh.test HOST_ADDRESS=192.168.1.50 MEDIASTACK_NPM_IP=172.29.0.10 \
    configure_jellyfin_networking "http://localhost:8096" "token"
rc=$?
assert_eq "0" "$rc" "Jellyfin networking malformed policy input remains non-fatal"
assert_contains "${WARN_MESSAGES[*]:-}" "Unexpected result from networking config check - skipping" \
    "Jellyfin networking malformed policy input warns and skips"

scenario_end "$CURRENT_SCENARIO"
summary

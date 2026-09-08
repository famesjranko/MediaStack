#!/usr/bin/env bash
# tests/unit/secret-argv.sh
#
# The shared admin password (JELLYFIN_ADMIN_PASSWORD) must never reach a
# process's argv: /proc/<pid>/cmdline is world-readable on stock Debian, so an
# argument is readable by every local account for the life of the request.
#
# Stubs curl and docker so both their arguments and the payload they are fed on
# stdin are recorded, drives every code path that handles the password, and
# asserts per case that the sentinel appears on stdin and never in argv. The
# stdin half is the positive control: dropping the credential altogether would
# clear argv but also fail the test. No DinD, no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="secret-argv"
echo -e "${CYAN}${BOLD}▶ scenario: secret-argv${NC}"

# Sourced libraries expect these; the cfg_* helpers are never called here.
# shellcheck disable=SC2034  # read by common.sh's cfg_* helpers, not by this file
CONFIG_FILE=/dev/null
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/lib/npm-remote.sh"
source "$REPO_ROOT/scripts/services/qbittorrent/main.sh"
source "$REPO_ROOT/scripts/services/wireguard/main.sh"
source "$REPO_ROOT/scripts/services/beszel/main.sh"
source "$REPO_ROOT/scripts/services/npm/main.sh"
source "$REPO_ROOT/scripts/services/jackett/main.sh"
source "$REPO_ROOT/scripts/setup/stage3/jellyfin.sh"

set +e
set +u

# Plain enough to survive JSON and URL encoding unchanged, so one sentinel can
# prove both halves: absent from argv, present in what curl reads from stdin.
# The escaping of hostile characters is asserted separately below.
SENTINEL='S3nt1nelP4ssw0rd'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARGV_LOG="$WORK/argv"
STDIN_LOG="$WORK/stdin"
COOKIE_JAR="$WORK/jar"

MOCK_BODY=""
MOCK_CODE=200
# Body returned only for NPM's stock-credential token request, so the closing
# token request can still come back empty and end the run there.
MOCK_DEFAULT_TOKEN_BODY=""

# --- Stubs -------------------------------------------------------------------
# Record argv, then drain stdin only when an argument actually asks curl to read
# it (-K -, @-, name@/dev/stdin) so a stdin-less call cannot block.
curl() {
    printf '%s\n' "$@" >>"$ARGV_LOG"
    local arg
    for arg in "$@"; do
        case "$arg" in
            -K | @- | *@/dev/stdin)
                cat >>"$STDIN_LOG"
                printf '\n' >>"$STDIN_LOG"
                break
                ;;
        esac
    done

    local outfile="" want_code=0 prev="" body="$MOCK_BODY"
    for arg in "$@"; do
        [[ "$prev" == "-o" ]] && outfile="$arg"
        [[ "$arg" == "-w" ]] && want_code=1
        [[ "$arg" == *token-default.json && -n "$MOCK_DEFAULT_TOKEN_BODY" ]] && body="$MOCK_DEFAULT_TOKEN_BODY"
        prev="$arg"
    done
    if [[ -n "$outfile" ]]; then
        printf '%s' "$body" >"$outfile"
        [[ "$want_code" == "1" ]] && printf '%s' "$MOCK_CODE"
    elif [[ "$want_code" == "1" ]]; then
        printf '%s\n%s' "$body" "$MOCK_CODE"
    else
        printf '%s' "$body"
    fi
    return 0
}

docker() {
    printf 'docker %s\n' "$*" >>"$ARGV_LOG"
    return 0
}

log_ok() { :; }
log_info() { :; }
log_skip() { :; }
log_warn() { :; }
log_error() { :; }
service_local_url() { echo "http://127.0.0.1:1"; }
env_save_api_key() { :; }

reset_logs() {
    : >"$ARGV_LOG"
    : >"$STDIN_LOG"
    MOCK_BODY=""
    MOCK_CODE=200
    MOCK_DEFAULT_TOKEN_BODY=""
}

# Drive one call site and assert the sentinel travelled on stdin, not on argv.
assert_secret_off_argv() {
    local label="$1"
    shift
    reset_logs
    "$@" >/dev/null 2>&1
    assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "$label: password absent from argv"
    assert_file_contains "$STDIN_LOG" "$SENTINEL" "$label: password delivered on stdin"
}

secret_body() { http_json_body Username admin Password "$SENTINEL"; }

# --- Shared wrappers ---------------------------------------------------------
assert_secret_off_argv "curl_basic_auth" \
    curl_basic_auth admin "$SENTINEL" -s http://svc/api
assert_secret_off_argv "curl_data_stdin" \
    curl_data_stdin "$(secret_body)" -s -X POST http://svc/api
assert_secret_off_argv "curl_data_urlencode_stdin" \
    curl_data_urlencode_stdin password "$SENTINEL" -s -X POST http://svc/api

# curl_basic_auth must reproduce the credential byte for byte despite the quote
# and backslash that curl's config parser would otherwise eat.
reset_logs
curl_basic_auth 'ad"min' 'p@ss"w\ord' -s http://svc/api >/dev/null 2>&1
assert_eq 'user = "ad\"min:p@ss\"w\\ord"' "$(head -1 "$STDIN_LOG")" \
    "curl_basic_auth: escapes quotes and backslashes for curl's config parser"

# --- Secret-bearing headers (SEC-6: X-Api-Key/Authorization as -H argv) -----
# curl_header_stdin must reproduce a header value byte for byte despite an
# embedded quote (e.g. Jellyfin's MediaBrowser Token="...") that curl's config
# parser would otherwise eat.
reset_logs
curl_header_stdin "Authorization" 'MediaBrowser Token="tok"' -s http://svc/api >/dev/null 2>&1
assert_eq 'header = "Authorization: MediaBrowser Token=\"tok\""' "$(head -1 "$STDIN_LOG")" \
    "curl_header_stdin: escapes quotes for curl's config parser"

# Same LF/CR guard as curl_basic_auth: a header value is one config line, and
# an embedded newline is header injection, not legitimate content, so it must
# be refused rather than silently truncated or escaped.
reset_logs
curl_header_stdin "Authorization" "line1
line2" -s http://svc/api >/dev/null 2>&1
assert_eq "2" "$?" "curl_header_stdin: refuses a header value containing a newline"
assert_file_not_contains "$ARGV_LOG" "line1" \
    "curl_header_stdin: a refused header never reaches curl"

# As with the body assertions above, the stdin check is the positive control:
# a wrapper that silently dropped the header instead of sending it would also
# read as "absent from argv" without it.
assert_secret_off_argv "curl_header_stdin (X-Api-Key)" \
    curl_header_stdin "X-Api-Key" "$SENTINEL" -s http://svc/api
assert_secret_off_argv "curl_header_data_stdin (header + body, one stdin)" \
    curl_header_data_stdin "Authorization" "Bearer $SENTINEL" "$(secret_body)" -s -X POST http://svc/api
assert_secret_off_argv "api_get (_api_request X-Api-Key)" \
    api_get http://arr/api "$SENTINEL"
assert_secret_off_argv "api_post (_api_request X-Api-Key + body)" \
    api_post http://arr/api "$SENTINEL" "$(secret_body)"
assert_secret_off_argv "api_fetch_auth" \
    api_fetch_auth "svc" "Authorization" "Bearer $SENTINEL" -s http://svc/api
assert_secret_off_argv "http_check_auth" \
    http_check_auth "svc" "Authorization" "Bearer $SENTINEL" -s http://svc/api
assert_secret_off_argv "npm_remote_api_cert_ids_by_fqdn" \
    npm_remote_api_cert_ids_by_fqdn "$SENTINEL" "http://npm/api" "example.com"

# _stage3_disable_jellyfin_hardware (scripts/setup/stage3/jellyfin.sh): the
# API key travels inside the MediaBrowser Authorization header built from
# JELLYFIN_API_KEY, and the GET+POST pair covers both curl_header_stdin and
# curl_header_data_stdin at this call site.
JELLYFIN_API_KEY="$SENTINEL" \
    assert_secret_off_argv "_stage3_disable_jellyfin_hardware" _stage3_disable_jellyfin_hardware

# --- Per-service call sites --------------------------------------------------
assert_secret_off_argv "http_check_data (Jellyfin /Startup/User)" \
    http_check_data "$(secret_body)" "startup-user" -X POST http://jf/Startup/User
assert_secret_off_argv "wait_for_jellyfin_auth" \
    wait_for_jellyfin_auth http://jf "MediaBrowser Client=\"t\"" "$(secret_body)" 2
assert_secret_off_argv "http_json_post (Seerr)" \
    http_json_post seerr http://seerr/api "$(secret_body)" "$COOKIE_JAR"
assert_secret_off_argv "api_put (arr Jellyfin auth config)" \
    api_put http://arr/api/v3/config/host apikey "$(secret_body)"
assert_secret_off_argv "_qbt_login" \
    _qbt_login "$COOKIE_JAR" http://qbt admin "$SENTINEL"
assert_secret_off_argv "_wg_ensure_firewall_enabled" \
    _wg_ensure_firewall_enabled http://wg admin "$SENTINEL"
assert_secret_off_argv "_wg_create_peer" \
    _wg_create_peer http://wg admin "$SENTINEL" phone
assert_secret_off_argv "_wg_set_peer_firewall_ips" \
    _wg_set_peer_firewall_ips http://wg admin "$SENTINEL" peer-1 "10.0.0.2/32"

NPM_ADMIN_EMAIL="admin@example.com" JELLYFIN_ADMIN_PASSWORD="$SENTINEL" \
    assert_secret_off_argv "npm_remote_token" npm_remote_token http://npm/api

# --- NPM health self-heal: admin token request (npm/health.sh) --------------
# Reached only once nginx -t is failing with a drifted proxy_host referencing
# a missing certificate file, so this drives the real drift-detection path
# (container "running" + nginx -t failing + one .conf with a dangling
# ssl_certificate ref) rather than calling the token-request line in isolation.
# Must run before the "NPM admin setup" block below stubs _npm_ensure_healthy
# to a no-op for configure_npm's own tests.
mkdir -p "$WORK/config/npm/data/nginx/proxy_host"
printf 'ssl_certificate /etc/letsencrypt/live/npm-1/fullchain.pem;\n' \
    >"$WORK/config/npm/data/nginx/proxy_host/5.conf"
# id -u drives _npm_ensure_healthy's sudo gate; stubbed so the file-only scan
# below never actually escalates in a non-root test run.
id() { echo 0; }
docker() {
    [[ "$*" == *"inspect"* ]] && {
        printf 'true'
        return 0
    }
    [[ "$*" == *"nginx -t"* ]] && return 1
    printf 'docker %s\n' "$*" >>"$ARGV_LOG"
    return 0
}
reset_logs
SCRIPT_DIR="$WORK" _npm_ensure_healthy "admin@example.com" "$SENTINEL" >/dev/null 2>&1
unset -f id
docker() {
    printf 'docker %s\n' "$*" >>"$ARGV_LOG"
    return 0
}
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "_npm_ensure_healthy: password absent from argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" "_npm_ensure_healthy: password delivered on stdin"

# --- NPM admin setup ---------------------------------------------------------
# Both halves of configure_npm's credential handling: seeding the admin on a
# fresh install, and rotating away from the stock credentials when the seed
# reports the user already exists. Each run stops at the closing token request,
# which the stub answers empty.
_npm_ensure_healthy() { :; }
export NPM_ADMIN_EMAIL="admin@example.com"
export JELLYFIN_ADMIN_PASSWORD="$SENTINEL"

reset_logs
MOCK_CODE=201
configure_npm >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "configure_npm (create): password absent from argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" "configure_npm (create): password delivered on stdin"

reset_logs
MOCK_CODE=409
# $SENTINEL doubles as the default (stock-credential) token here, so this run
# also drives the rotate path's two curl_header_data_stdin calls (Authorization:
# Bearer <default_token> alongside the user-update/password-rotate bodies) -
# the same argv/stdin assertions below cover the header as well as the body.
MOCK_DEFAULT_TOKEN_BODY='{"token":"'"$SENTINEL"'"}'
configure_npm >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "configure_npm (rotate): password/token absent from argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" "configure_npm (rotate): password/token delivered on stdin"
# The stock-credential marker is unique to the rotation body, so this pins the
# rotate path rather than letting the creation body satisfy the case above.
# Quoted (\"..\") because the body now travels as a curl config `data-raw =`
# line alongside the Authorization header (curl_header_data_stdin), which
# escapes the JSON's own quotes the same way curl_basic_auth escapes a
# credential's.
assert_file_contains "$STDIN_LOG" '\"current\": \"changeme\"' \
    "configure_npm (rotate): rotation body reached curl on stdin"

# --- Jackett admin password --------------------------------------------------
# Reached only when Jackett has no stored hash yet, so seed an unset one.
mkdir -p "$WORK/config/jackett/Jackett"
printf '%s' '{"APIKey":"jackett-key","AdminPassword":""}' \
    >"$WORK/config/jackett/Jackett/ServerConfig.json"
api_get_jackett_key() { printf 'jackett-key'; }
service_internal_url() { echo "http://127.0.0.1:1"; }
cfg_indexers() { :; }

reset_logs
SCRIPT_DIR="$WORK" configure_jackett >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "configure_jackett: password absent from argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" "configure_jackett: password delivered on stdin"
# The set-password body is a bare JSON string, which the urlencoded login body
# is not: quoting pins the case to the path this fix converted.
assert_file_contains "$STDIN_LOG" "\"$SENTINEL\"" \
    "configure_jackett: set-password body reached curl on stdin"

# --- A credential curl's config format cannot carry --------------------------
# Line-oriented parsing would truncate at the newline rather than fail.
reset_logs
curl_basic_auth admin "line1
line2" -s http://svc/api >/dev/null 2>&1
assert_eq "2" "$?" "curl_basic_auth: refuses a credential containing a newline"
assert_file_not_contains "$ARGV_LOG" "line1" \
    "curl_basic_auth: a refused credential never reaches curl"

# --- Beszel: the one path that also reaches docker ---------------------------
# The hub creates the superuser from its own env on first start, so a healthy
# hub answers the API probe and the argv-only PocketBase CLI is never invoked.
reset_logs
MOCK_CODE=200
# $SENTINEL also stands in as the hub auth token here, so this run reaches the
# getkey call's converted Authorization header (curl_header_stdin) as well as
# the auth POST body - one pair of assertions below covers both.
MOCK_BODY='{"token":"'"$SENTINEL"'"}'
NPM_ADMIN_EMAIL="admin@example.com" JELLYFIN_ADMIN_PASSWORD="$SENTINEL" \
    configure_beszel >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" \
    "configure_beszel: password/token absent from curl and docker argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" \
    "configure_beszel: password/token delivered on stdin"
assert_file_not_contains "$ARGV_LOG" "superuser upsert" \
    "configure_beszel: skips the argv-only CLI when the API probe succeeds"

summary

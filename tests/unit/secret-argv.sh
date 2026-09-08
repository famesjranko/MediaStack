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
MOCK_DEFAULT_TOKEN_BODY='{"token":"stock-token"}'
configure_npm >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "configure_npm (rotate): password absent from argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" "configure_npm (rotate): password delivered on stdin"
# The stock-credential marker is unique to the rotation body, so this pins the
# rotate path rather than letting the creation body satisfy the case above.
assert_file_contains "$STDIN_LOG" '"current": "changeme"' \
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
NPM_ADMIN_EMAIL="admin@example.com" JELLYFIN_ADMIN_PASSWORD="$SENTINEL" \
    configure_beszel >/dev/null 2>&1
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" \
    "configure_beszel: password absent from curl and docker argv"
assert_file_contains "$STDIN_LOG" "$SENTINEL" \
    "configure_beszel: password delivered on stdin"
assert_file_not_contains "$ARGV_LOG" "superuser upsert" \
    "configure_beszel: skips the argv-only CLI when the API probe succeeds"

summary

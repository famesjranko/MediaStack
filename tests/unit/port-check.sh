#!/usr/bin/env bash
# =============================================================================
# Unit test — port-check.sh basic sanity
# =============================================================================
# Verifies the script sources cleanly and handles missing/default domain
# without errors. Does NOT test actual port connectivity (that's DinD).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="port-check"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# We need a copy of the repo tree so port-check.sh can source its libs
# without modifying the real .env.
setup_sandbox() {
    local env_content="${1:-}"
    rm -rf "$TMP_DIR/sandbox"
    mkdir -p "$TMP_DIR/sandbox/bin" "$TMP_DIR/sandbox/scripts/lib"
    cp "$REPO_ROOT/scripts/port-check.sh" "$TMP_DIR/sandbox/scripts/"
    cp "$REPO_ROOT/scripts/lib/common.sh" "$TMP_DIR/sandbox/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/env-update.sh" "$TMP_DIR/sandbox/scripts/lib/" # common.sh sources it
    cp "$REPO_ROOT/scripts/lib/ui.sh" "$TMP_DIR/sandbox/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/ui-render-fallback.sh" "$TMP_DIR/sandbox/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/term-caps.sh" "$TMP_DIR/sandbox/scripts/lib/" # common.sh + ui-render-fallback.sh source it
    cat >"$TMP_DIR/sandbox/bin/getent" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "ahosts" ]]; then
    case "${2:-}" in
        jellyfin.test.example.org|seerr.test.example.org|jellyfin.quoted.example.org|seerr.quoted.example.org)
            printf '203.0.113.10 STREAM %s\n' "$2"
            exit 0
            ;;
        test.example.org|quoted.example.org)
            exit 2
            ;;
    esac
fi
exit 2
STUB
    chmod +x "$TMP_DIR/sandbox/bin/getent"
    cat >"$TMP_DIR/sandbox/scripts/lib/network.sh" <<'STUB'
_NET_PUBLIC_IP="203.0.113.10"
net_detect_public_ip() {
    _NET_PUBLIC_IP="203.0.113.10"
    return 0
}
net_check_http() {
    if [[ -n "${PORT_CHECK_HTTP_LOG:-}" ]]; then
        printf '%s\n' "$1" >> "$PORT_CHECK_HTTP_LOG"
    fi
    return 0
}
net_check_tcp_port_external() {
    return 2
}
STUB
    if [[ -n "$env_content" ]]; then
        echo "$env_content" >"$TMP_DIR/sandbox/.env"
    fi
}

run_port_check() {
    : >"$TMP_DIR/http.log"
    PATH="$TMP_DIR/sandbox/bin:$PATH" \
        PORT_CHECK_HTTP_LOG="$TMP_DIR/http.log" \
        "$TMP_DIR/sandbox/scripts/port-check.sh" 2>&1
}

assert_http_log_has_service_urls() {
    local domain="$1" label="$2"
    local missing=()
    local url
    for url in \
        "http://jellyfin.${domain}" \
        "https://jellyfin.${domain}" \
        "http://seerr.${domain}" \
        "https://seerr.${domain}"; do
        grep -qx "$url" "$TMP_DIR/http.log" || missing+=("$url")
    done

    if ((${#missing[@]} == 0)) && ! grep -q "://${domain}" "$TMP_DIR/http.log"; then
        pass "$label"
    else
        fail "$label" "missing=${missing[*]:-none}; log=$(cat "$TMP_DIR/http.log")"
    fi
}

# ---- Test 1: sources without error (no .env) ----
setup_sandbox ""
output=$(run_port_check)
rc=$?
if [[ $rc -le 1 ]]; then
    pass "port-check.sh runs without .env (no crash)"
else
    fail "port-check.sh runs without .env" "exit code $rc"
fi
# No-domain mode should still give pre-install users useful forwarding
# diagnostics: probe 80/443 by temporary listener rather than pretending
# remote ports are unknowable until a domain exists.
if echo "$output" | grep -q "TCP 80 (HTTP)"; then
    pass "port-check.sh probes TCP 80/443 when no domain"
else
    fail "port-check.sh probes TCP 80/443 when no domain" "expected TCP 80 (HTTP) check in output"
fi

# ---- Test 2: exits cleanly with DOMAIN=example.com ----
setup_sandbox "DOMAIN=example.com"
output=$(run_port_check)
if echo "$output" | grep -q "TCP 443 (HTTPS)"; then
    pass "port-check.sh treats DOMAIN=example.com as no-domain pre-install probe"
else
    fail "port-check.sh treats DOMAIN=example.com as no-domain pre-install probe" "expected TCP 443 (HTTPS) check in output"
fi

# ---- Test 3: exits cleanly with a real-looking domain ----
setup_sandbox "DOMAIN=test.example.org"
output=$(run_port_check)
# Real domains use HTTP(S) probes against the service hostnames.
if echo "$output" | grep -q "HTTP jellyfin."; then
    pass "port-check.sh checks TCP 80 when domain is set"
else
    fail "port-check.sh checks TCP 80 when domain is set"
fi
assert_http_log_has_service_urls "test.example.org" "port-check.sh probes all service subdomain URLs, not apex domain"
if echo "$output" | grep -q "Optional apex DNS: test.example.org is not required" \
    && ! echo "$output" | grep -q '\[FAIL\].*test.example.org does not resolve'; then
    pass "port-check.sh accepts subdomain-only DNS records"
else
    fail "port-check.sh accepts subdomain-only DNS records" "$output"
fi

# ---- Test 4: handles single-quoted domain in .env ----
setup_sandbox "DOMAIN='quoted.example.org'"
output=$(run_port_check)
if echo "$output" | grep -q "HTTP jellyfin."; then
    pass "port-check.sh handles single-quoted DOMAIN in .env"
else
    fail "port-check.sh handles single-quoted DOMAIN in .env"
fi
assert_http_log_has_service_urls "quoted.example.org" "port-check.sh handles single-quoted DOMAIN as all service subdomain URLs"

scenario_end "$CURRENT_SCENARIO"
summary

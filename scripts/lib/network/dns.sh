# Owns: Stage 2 Cloudflare CIDR and DNS classification helpers.
# Sources: scripts/lib/network.sh state plus curl, dig, awk, and python3.
stage2_fetch_cloudflare_ips_v4() {
    if [[ -n "${STAGE2_CLOUDFLARE_IPS_TEXT:-}" ]]; then
        printf '%s\n' "$STAGE2_CLOUDFLARE_IPS_TEXT"
        return 0
    fi
    if [[ -n "${STAGE2_CLOUDFLARE_IPS_FILE:-}" && -f "$STAGE2_CLOUDFLARE_IPS_FILE" ]]; then
        cat "$STAGE2_CLOUDFLARE_IPS_FILE"
        return 0
    fi
    if [[ -n "$_STAGE2_CLOUDFLARE_IPS_V4" ]]; then
        printf '%s\n' "$_STAGE2_CLOUDFLARE_IPS_V4"
        return 0
    fi

    _STAGE2_CLOUDFLARE_IPS_V4=$(curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null) || {
        _STAGE2_CLOUDFLARE_IPS_V4=""
        return 1
    }
    printf '%s\n' "$_STAGE2_CLOUDFLARE_IPS_V4"
}

stage2_ip_in_cloudflare_v4() {
    local ip="$1"
    local cidrs="${2:-}"
    if [[ -z "$cidrs" ]]; then
        cidrs=$(stage2_fetch_cloudflare_ips_v4) || return 1
    fi

    IP="$ip" CIDRS="$cidrs" python3 -c '
import ipaddress
import os
import sys

try:
    ip = ipaddress.ip_address(os.environ["IP"])
except ValueError:
    sys.exit(1)

for raw in os.environ["CIDRS"].split():
    try:
        if ip in ipaddress.ip_network(raw, strict=False):
            sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
' 2>/dev/null
}

_stage2_first_ipv4() {
    awk -F. '
        NF == 4 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    next
                }
            }
            print
            exit
        }
    '
}

_stage2_dns_lookup_a() {
    local name="$1"
    local result

    # Try the host's configured resolver first. Some home networks and ISPs
    # block direct queries to public resolvers, and the system resolver is the
    # closest match for what the setup host can actually use.
    result=$(dig +short A "$name" 2>/dev/null | _stage2_first_ipv4)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    result=$(dig +short A "$name" @8.8.8.8 2>/dev/null | _stage2_first_ipv4)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    return 1
}

stage2_dns_classify() {
    local domain="$1" public_ip="$2"
    local jellyfin_a seerr_a apex_a

    jellyfin_a=$(_stage2_dns_lookup_a "jellyfin.${domain}" || true)
    seerr_a=$(_stage2_dns_lookup_a "seerr.${domain}" || true)

    if [[ -z "$jellyfin_a" && -z "$seerr_a" ]]; then
        apex_a=$(_stage2_dns_lookup_a "$domain" || true)
        if [[ -n "$apex_a" ]]; then
            printf 'apex-only'
            return 1
        fi
        printf 'no-a'
        return 1
    fi

    if [[ -z "$jellyfin_a" || -z "$seerr_a" ]]; then
        printf 'no-a'
        return 1
    fi
    if stage2_ip_in_cloudflare_v4 "$jellyfin_a" || stage2_ip_in_cloudflare_v4 "$seerr_a"; then
        printf 'cloudflare'
        return 1
    fi
    if [[ "$jellyfin_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$jellyfin_a"
        return 1
    fi
    if [[ "$seerr_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$seerr_a"
        return 1
    fi

    printf 'ok'
    return 0
}

# -----------------------------------------------------------------------------
# ddns_verify_via_container <config_json_path> [error_body_file]
#
# One uniform credential check for every DDNS provider, with zero blast radius:
# run a throwaway ddns-updater container whose record resolver is blackholed
# (RESOLVER_ADDRESS=127.0.0.1:1). The blackhole makes the container's hostname
# lookup FAIL, which falls through to a REAL provider push at the current public
# IP (upstream's "// update anyway" path). GET /update then maps the provider's
# response. This is a REJECTION channel, not an acceptance channel: a 500 means
# the credentials are definitely wrong; a 202 means accepted OR provider-masked
# (a username/password provider server-side no-ops on an unchanged IP without
# checking the password).
#
# The caller renders config.json first (ddns_render_config_json), so this file
# stays free of provider-registry knowledge. The rendered config is copied into a
# throwaway data dir; teardown removes both the container and the plaintext-cred
# scratch on any exit.
#
# Exit codes:
#   0  /update 202 — accepted (or masked); caller tiers the message by provider
#   1  rejected — /update 500 (bad creds) OR the container fail-fasted on an
#      invalid config (malformed token shape, bad domain eTLD). The provider /
#      validation error is written to <error_body_file> when given (the caller
#      prints it AFTER ui_spin returns, because ui_spin suppresses stdout), and
#      the caller re-prompts. A fail-fast config error is a reject, not a degrade
#      — otherwise a fat-fingered credential persists and the real ddns-updater
#      dies at install.
#   2  degrade — docker missing / image pull failed / container up but never
#      answered / curl could not connect. NEVER re-prompts: the caller lands the
#      honest "configured, unverified" tier. A pull failure must not look like
#      bad creds.
#
# The blackhole MUST fast-refuse (127.0.0.1:1 = connection refused). An
# unroutable / timing-out address would hit the container's context-deadline
# branch, skip the push, and silently turn the rejection channel off.
# -----------------------------------------------------------------------------

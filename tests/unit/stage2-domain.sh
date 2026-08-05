#!/usr/bin/env bash
# tests/unit/stage2-domain.sh
#
# Contract tests for Stage 2 DNS classification. These tests stub DNS and
# Cloudflare CIDR inputs so no real network lookup is required.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-domain"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/network.sh"
[[ -f "$REPO_ROOT/scripts/lib/validators.sh" ]] && source "$REPO_ROOT/scripts/lib/validators.sh"
source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

set +e
set +u

WARN_COUNT=0
LAST_WARN=""
ui_log() {
    local level="$1"
    shift
    if [[ "$level" == "warn" ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        LAST_WARN="$*"
    fi
}
reset_warn() {
    WARN_COUNT=0
    # Recording hook for debugging; not asserted.
    # shellcheck disable=SC2034
    LAST_WARN=""
}

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

cat >"$TMP_ROOT/cloudflare-ips-v4.txt" <<'EOF'
198.51.100.0/24
EOF
export STAGE2_CLOUDFLARE_IPS_FILE="$TMP_ROOT/cloudflare-ips-v4.txt"
STAGE2_CLOUDFLARE_IPS_TEXT="$(cat "$TMP_ROOT/cloudflare-ips-v4.txt")"
export STAGE2_CLOUDFLARE_IPS_TEXT

dig() {
    local query=""
    local google_resolver="false"
    for arg in "$@"; do
        [[ "$arg" == "@8.8.8.8" ]] && google_resolver="true"
        [[ "$arg" == +* || "$arg" == "A" || "$arg" == @* ]] && continue
        query="$arg"
        break
    done
    case "$query" in
        jellyfin.ok.test | seerr.ok.test) printf '203.0.113.10\n' ;;
        jellyfin.system-only.test | seerr.system-only.test)
            [[ "$google_resolver" == "true" ]] && return 1
            printf '203.0.113.10\n'
            ;;
        jellyfin.mismatch.test | seerr.mismatch.test) printf '203.0.113.99\n' ;;
        jellyfin.cloudflare.test | seerr.cloudflare.test) printf '198.51.100.8\n' ;;
        apex-only.test) printf '203.0.113.10\n' ;;
        *) return 0 ;;
    esac
}

curl() {
    case "$*" in
        *cloudflare.com/ips-v4*) cat "$TMP_ROOT/cloudflare-ips-v4.txt" ;;
        *) return 22 ;;
    esac
}

if ! type net_dns_classify >/dev/null 2>&1; then
    net_dns_classify() { printf '__not_implemented__'; }
fi
if ! type validate_domain_name >/dev/null 2>&1; then
    validate_domain_name() { return 99; }
fi
if ! type validate_wireguard_hostname >/dev/null 2>&1; then
    validate_wireguard_hostname() { return 99; }
fi

reset_warn
validate_domain_name "media.mediastack.testhost"
rc=$?
assert_eq "0" "$rc" "validate_domain_name accepts normal FQDN"

for domain in "" "localhost" "bad_name.example.com" "-bad.example.com" "bad-.example.com" "example" "bad..example.com"; do
    reset_warn
    validate_domain_name "$domain"
    rc=$?
    assert_eq "1" "$rc" "validate_domain_name rejects '$domain'"
    assert_eq "1" "$WARN_COUNT" "validate_domain_name warns once for '$domain'"
done

reset_warn
validate_wireguard_hostname "vpn.mediastack.testhost"
rc=$?
assert_eq "0" "$rc" "validate_wireguard_hostname accepts FQDN"

reset_warn
validate_wireguard_hostname "203.0.113.10"
rc=$?
assert_eq "0" "$rc" "validate_wireguard_hostname accepts IPv4 literal"

assert_eq "ok" "$(net_dns_classify "ok.test" "203.0.113.10")" "DNS match classifies as ok"
assert_eq "ok" "$(net_dns_classify "system-only.test" "203.0.113.10")" "system resolver success is accepted when Google DNS is unavailable"
assert_eq "no-a" "$(net_dns_classify "no-a.test" "203.0.113.10")" "missing jellyfin A record classifies as no-a"
assert_eq "mismatch:203.0.113.99" "$(net_dns_classify "mismatch.test" "203.0.113.10")" "mismatched A record includes resolved IP"
assert_eq "cloudflare" "$(net_dns_classify "cloudflare.test" "203.0.113.10")" "Cloudflare CIDR match classifies as cloudflare"
assert_eq "apex-only" "$(net_dns_classify "apex-only.test" "203.0.113.10")" "apex-only DNS classifies as apex-only"

scenario_end "$CURRENT_SCENARIO"
summary

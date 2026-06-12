#!/usr/bin/env bash
# =============================================================================
# MediaStack — Port Forwarding Verification
# =============================================================================
# Re-runnable diagnostic: checks DNS resolution, public IP, and port
# reachability for the ports that must be forwarded at the router.
#
# Usage:  ./scripts/port-check.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/ui.sh"
source "$SCRIPT_DIR/scripts/lib/network.sh"

# -----------------------------------------------------------------------------
# Read DOMAIN from .env
# -----------------------------------------------------------------------------
DOMAIN=""
TORRENT_PORT="6881"
WG_PORT="51820"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    DOMAIN=$(grep -oP '^DOMAIN=\K.*' "$SCRIPT_DIR/.env" | tr -d "'" | tr -d '"')
    TORRENT_PORT=$(grep -oP '^TORRENT_PORT=\K.*' "$SCRIPT_DIR/.env" | tr -d "'" | tr -d '"')
    TORRENT_PORT="${TORRENT_PORT:-6881}"
    WG_PORT=$(grep -oP '^WG_PORT=\K.*' "$SCRIPT_DIR/.env" | tr -d "'" | tr -d '"')
    WG_PORT="${WG_PORT:-51820}"
fi

has_domain=false
service_hosts=()
if [[ -n "$DOMAIN" && "$DOMAIN" != "example.com" ]]; then
    has_domain=true
    service_hosts=("jellyfin.$DOMAIN" "seerr.$DOMAIN")
fi

# -----------------------------------------------------------------------------
# Counters
# -----------------------------------------------------------------------------
checks_pass=0
checks_fail=0
checks_skip=0

check_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; checks_pass=$((checks_pass + 1)); }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $1${2:+  - $2}"; checks_fail=$((checks_fail + 1)); }
check_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1${2:+  ($2)}"; checks_skip=$((checks_skip + 1)); }

resolve_host_ip() {
    local host="$1"
    getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}'
}

# -----------------------------------------------------------------------------
# 1. Public IP detection
# -----------------------------------------------------------------------------
echo ""
ui_box "Port Forwarding Check" \
    "Verifies that your router forwards the required ports" \
    "to this server so remote access works correctly."
echo ""

public_ip=""
if net_detect_public_ip; then
    public_ip="$_NET_PUBLIC_IP"
    log_info "Public IP: $public_ip"
else
    log_warn "Could not detect public IP - skipping DNS comparison"
fi

# -----------------------------------------------------------------------------
# 2. DNS resolution (domain-dependent)
# -----------------------------------------------------------------------------
if $has_domain; then
    for host in "${service_hosts[@]}"; do
        resolved_ip=$(resolve_host_ip "$host")
        if [[ -n "$resolved_ip" ]]; then
            log_info "DNS: $host -> $resolved_ip"
            if [[ -n "$public_ip" ]]; then
                if [[ "$resolved_ip" == "$public_ip" ]]; then
                    check_pass "DNS $host matches public IP ($public_ip)"
                else
                    check_fail "DNS $host matches public IP" "$host resolves to $resolved_ip, but public IP is $public_ip"
                fi
            else
                check_skip "DNS $host vs public IP comparison" "could not detect public IP"
            fi
        else
            check_fail "DNS resolution for $host" "$host does not resolve - add a wildcard *.${DOMAIN} record or separate service A records"
        fi
    done

    apex_ip=$(resolve_host_ip "$DOMAIN")
    if [[ -n "$apex_ip" ]]; then
        log_info "Optional apex DNS: $DOMAIN -> $apex_ip"
    else
        log_info "Optional apex DNS: $DOMAIN is not required; MediaStack uses jellyfin.$DOMAIN and seerr.$DOMAIN."
    fi
fi

# -----------------------------------------------------------------------------
# 3. TCP port checks
# -----------------------------------------------------------------------------
echo ""
log_info "Checking port forwarding..."
echo ""

if $has_domain; then
    for host in "${service_hosts[@]}"; do
        # TCP 80 — any HTTP response means the port is forwarded
        if net_check_http "http://$host"; then
            check_pass "TCP 80 (HTTP: $host)"
        else
            check_fail "TCP 80 (HTTP: $host)" "no response from http://$host"
        fi

        # TCP 443 — cert errors are fine, any response means forwarded
        if net_check_http "https://$host"; then
            check_pass "TCP 443 (HTTPS: $host)"
        else
            check_fail "TCP 443 (HTTPS: $host)" "no response from https://$host"
        fi
    done
elif [[ -n "$public_ip" ]]; then
    # Pre-install / no-domain: fall back to TCP-level external probe.
    # net_check_tcp_port_external spins up a temporary listener if nothing
    # is bound, then triggers the external probe — so this works on a fresh
    # box before NPM is installed. Privileged ports (80/443) need sudo to
    # bind; the helper sudo-wraps internally and may prompt.
    log_info "Probing TCP 80 + 443 via temporary listener (sudo may prompt for privileged bind)..."
    case $(net_check_tcp_port_external 80; echo "rc:$?") in
        rc:0) check_pass "TCP 80 (router forwarding)" ;;
        rc:1) check_fail "TCP 80 (router forwarding)" "no response on $public_ip:80" ;;
        rc:3) check_fail "TCP 80 (router forwarding)" "$public_ip:80 reachable from internet, but traffic does NOT land on this host - router is forwarding 80 to a different LAN device" ;;
        rc:4) check_skip "TCP 80 (router forwarding)" "probed open, but verification skipped - port already bound by another service. Stop that service briefly to re-test" ;;
        *)    check_skip "TCP 80 (router forwarding)" "could not bind listener or external probe service unreachable" ;;
    esac
    case $(net_check_tcp_port_external 443; echo "rc:$?") in
        rc:0) check_pass "TCP 443 (router forwarding)" ;;
        rc:1) check_fail "TCP 443 (router forwarding)" "no response on $public_ip:443" ;;
        rc:3) check_fail "TCP 443 (router forwarding)" "$public_ip:443 reachable from internet, but traffic does NOT land on this host - router is forwarding 443 to a different LAN device" ;;
        rc:4) check_skip "TCP 443 (router forwarding)" "probed open, but verification skipped - port already bound by another service. Stop that service briefly to re-test" ;;
        *)    check_skip "TCP 443 (router forwarding)" "could not bind listener or external probe service unreachable" ;;
    esac
else
    check_skip "TCP 80" "could not detect public IP"
    check_skip "TCP 443" "could not detect public IP"
fi

# TCP — qBittorrent listening port. Use the external probe so we get the
# same answer a real external peer would (canyouseeme/portchecker.io probe
# from their server, no hairpin-NAT dependency).
if [[ -n "$public_ip" ]]; then
    case $(net_check_tcp_port_external "$TORRENT_PORT"; echo "rc:$?") in
        rc:0) check_pass "TCP $TORRENT_PORT (qBittorrent)" ;;
        rc:1) check_fail "TCP $TORRENT_PORT (qBittorrent)" "no response on $public_ip:$TORRENT_PORT (external probe)" ;;
        rc:3) check_fail "TCP $TORRENT_PORT (qBittorrent)" "$public_ip:$TORRENT_PORT reachable from internet, but traffic does NOT land on this host - router is forwarding $TORRENT_PORT to a different LAN device" ;;
        rc:4) check_skip "TCP $TORRENT_PORT (qBittorrent)" "probed open, but verification skipped - port already bound by another service (qBittorrent itself, presumably). Stop it briefly to re-test" ;;
        *)    check_skip "TCP $TORRENT_PORT (qBittorrent)" "external port-check service unreachable" ;;
    esac
else
    check_skip "TCP $TORRENT_PORT (qBittorrent)" "could not detect public IP"
fi

# UDP — WireGuard; can't reliably probe externally, check container status
wg_status=$(docker inspect --format '{{.State.Status}}' wireguard 2>/dev/null || echo "")
if [[ "$wg_status" == "running" ]]; then
    check_pass "UDP $WG_PORT (WireGuard) - container running (external probe not possible)"
elif [[ -z "$wg_status" ]]; then
    check_skip "UDP $WG_PORT (WireGuard)" "WireGuard not installed yet - re-run after setup.sh --remote"
else
    check_fail "UDP $WG_PORT (WireGuard)" "container status: $wg_status"
fi

# -----------------------------------------------------------------------------
# 4. Summary
# -----------------------------------------------------------------------------
echo ""
local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
local_ip="${local_ip:-<your-server-ip>}"

total=$((checks_pass + checks_fail + checks_skip))
if [[ $checks_fail -eq 0 ]]; then
    if (( checks_skip > 0 )); then
        # Avoid the misleading "1/4" framing when 3 of 4 are skipped — that
        # reads as a 25% pass rate to a non-technical user.
        log_ok "$checks_pass passed / $checks_skip skipped / $checks_fail failed"
    else
        log_ok "All checks passed ($checks_pass/$total)"
    fi
else
    log_warn "$checks_fail of $total checks failed"
    echo ""
    echo -e "  ${BOLD}Hairpin NAT caveat:${NC} Some routers can't loop traffic back"
    echo "  to themselves. If checks fail here but access works from outside"
    echo "  your network (e.g., phone on mobile data), your forwarding is fine."
fi

if [[ $checks_fail -gt 0 || $checks_skip -gt 0 ]]; then
    echo ""
    # Script-scope array — port-check.sh is a top-level script, not a function.
    # `local` here triggered "local: can only be used in a function" on stderr.
    # Always list all four ports with conditional annotations — pre-install
    # users don't necessarily have a DOMAIN configured yet but still need to
    # know what to forward if they plan to enable remote access.
    fwd_lines=(
        "Forward these ports to $local_ip in your router:"
        ""
        "  TCP+UDP ${TORRENT_PORT} -> $local_ip   (qBittorrent peer connections - always required)"
        "  TCP 80      -> $local_ip   (Let's Encrypt + HTTP redirect - only if using a domain)"
        "  TCP 443     -> $local_ip   (HTTPS - Jellyfin, Seerr - only if using a domain)"
        "  UDP ${WG_PORT}   -> $local_ip   (WireGuard VPN - only if using remote access)"
    )
    ui_box "Required Port Forwards" "${fwd_lines[@]}"
fi

echo ""

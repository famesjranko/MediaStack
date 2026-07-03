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

# Use the shared status glyphs (✓/✗/→, with [OK]/[ERROR]/[SKIP] ASCII fallback)
# so this diagnostic matches the rest of the UI, and pad the label into a fixed
# column so the short gray detail lines up and never wraps. Keep labels/details
# terse — long sentences wrapped ugly in the terminal.
_PC_LW=21
# Pad the status glyph to a fixed visible width so the label column aligns across
# pass/fail/skip rows: ASCII tags vary 4-7 cols ([OK]..[ERROR]) -> pad to 7;
# unicode icons are 1 col (multibyte, width 1 -> %-*s never byte-pads them).
_PC_GW=1; [[ "$_G_UNICODE" == 1 ]] || _PC_GW=7
check_pass() { printf "  ${GREEN}%-*s${NC} %-*s ${GRAY}%s${NC}\n" "$_PC_GW" "$(_ui_status_token ok)"    "$_PC_LW" "$1" "${2:-}"; checks_pass=$((checks_pass + 1)); }
check_fail() { printf "  ${RED}%-*s${NC} %-*s ${GRAY}%s${NC}\n"   "$_PC_GW" "$(_ui_status_token error)" "$_PC_LW" "$1" "${2:-}"; checks_fail=$((checks_fail + 1)); }
check_skip() { printf "  ${YELLOW}%-*s${NC} %-*s ${GRAY}%s${NC}\n" "$_PC_GW" "$(_ui_status_token skip)"  "$_PC_LW" "$1" "${2:-}"; checks_skip=$((checks_skip + 1)); }

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
                    check_pass "DNS $host" "matches public IP"
                else
                    check_fail "DNS $host" "-> $resolved_ip (want $public_ip)"
                fi
            else
                check_skip "DNS $host" "no public IP"
            fi
        else
            check_fail "DNS $host" "does not resolve"
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
            check_pass "HTTP $host" "reachable"
        else
            check_fail "HTTP $host" "no response"
        fi

        # TCP 443 — cert errors are fine, any response means forwarded
        if net_check_http "https://$host"; then
            check_pass "HTTPS $host" "reachable"
        else
            check_fail "HTTPS $host" "no response"
        fi
    done
elif [[ -n "$public_ip" ]]; then
    # Pre-install / no-domain: fall back to TCP-level external probe.
    # net_check_tcp_port_external spins up a temporary listener if nothing
    # is bound, then triggers the external probe — so this works on a fresh
    # box before NPM is installed. Privileged ports (80/443) need sudo to
    # bind; the helper sudo-wraps internally and may prompt.
    log_info "Probing TCP 80 + 443 (sudo may prompt to bind privileged ports)..."
    case $(net_check_tcp_port_external 80; echo "rc:$?") in
        rc:0) check_pass "TCP 80 (HTTP)" "reachable" ;;
        rc:1) check_fail "TCP 80 (HTTP)" "no response" ;;
        rc:3) check_fail "TCP 80 (HTTP)" "forwarded to another device" ;;
        rc:4) check_skip "TCP 80 (HTTP)" "port in use - re-test later" ;;
        *)    check_skip "TCP 80 (HTTP)" "probe unavailable" ;;
    esac
    case $(net_check_tcp_port_external 443; echo "rc:$?") in
        rc:0) check_pass "TCP 443 (HTTPS)" "reachable" ;;
        rc:1) check_fail "TCP 443 (HTTPS)" "no response" ;;
        rc:3) check_fail "TCP 443 (HTTPS)" "forwarded to another device" ;;
        rc:4) check_skip "TCP 443 (HTTPS)" "port in use - re-test later" ;;
        *)    check_skip "TCP 443 (HTTPS)" "probe unavailable" ;;
    esac
else
    check_skip "TCP 80 (HTTP)" "no public IP"
    check_skip "TCP 443 (HTTPS)" "no public IP"
fi

# TCP — qBittorrent listening port. Use the external probe so we get the
# same answer a real external peer would (canyouseeme/portchecker.io probe
# from their server, no hairpin-NAT dependency).
if [[ -n "$public_ip" ]]; then
    case $(net_check_tcp_port_external "$TORRENT_PORT"; echo "rc:$?") in
        rc:0) check_pass "TCP $TORRENT_PORT (torrent)" "reachable" ;;
        rc:1) check_fail "TCP $TORRENT_PORT (torrent)" "no response" ;;
        rc:3) check_fail "TCP $TORRENT_PORT (torrent)" "forwarded to another device" ;;
        rc:4) check_skip "TCP $TORRENT_PORT (torrent)" "port in use - re-test later" ;;
        *)    check_skip "TCP $TORRENT_PORT (torrent)" "probe unavailable" ;;
    esac
else
    check_skip "TCP $TORRENT_PORT (torrent)" "no public IP"
fi

# UDP — WireGuard; can't reliably probe externally, check container status
wg_status=$(docker inspect --format '{{.State.Status}}' wireguard 2>/dev/null || echo "")
if [[ "$wg_status" == "running" ]]; then
    check_pass "UDP $WG_PORT (WireGuard)" "running (no external probe)"
elif [[ -z "$wg_status" ]]; then
    check_skip "UDP $WG_PORT (WireGuard)" "not installed yet"
else
    check_fail "UDP $WG_PORT (WireGuard)" "container: $wg_status"
fi

# -----------------------------------------------------------------------------
# 4. Summary
# -----------------------------------------------------------------------------
echo ""
local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
local_ip="${local_ip:-<your-server-ip>}"
# LAN gateway = the router's admin page, where the user sets up forwarding.
gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')

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
        "  TCP+UDP ${TORRENT_PORT}  ->  $local_ip   (torrent - always)"
        "  TCP 80       ->  $local_ip   (HTTP/ACME - domain only)"
        "  TCP 443      ->  $local_ip   (HTTPS - domain only)"
        "  UDP ${WG_PORT}    ->  $local_ip   (WireGuard - remote only)"
    )
    if [[ -n "$gateway" ]]; then
        fwd_lines+=("" "Your router's admin page is usually http://${gateway}")
    fi
    ui_box "Required Port Forwards" "${fwd_lines[@]}"
fi

echo ""

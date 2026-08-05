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

HAS_DOMAIN=false
service_hosts=()
if [[ -n "$DOMAIN" && "$DOMAIN" != "example.com" ]]; then
    HAS_DOMAIN=true
    service_hosts=("jellyfin.$DOMAIN" "seerr.$DOMAIN")
fi

# -----------------------------------------------------------------------------
# Counters
# -----------------------------------------------------------------------------
CHECKS_PASS=0
CHECKS_FAIL=0
CHECKS_SKIP=0

# Use the shared status glyphs (✓/✗/→, with [OK]/[ERROR]/[SKIP] ASCII fallback)
# so this diagnostic matches the rest of the UI, and pad the label into a fixed
# column so the short gray detail lines up and never wraps. Keep labels/details
# terse — long sentences wrapped ugly in the terminal.
_PC_LW=21
# Pad the status glyph to a fixed visible width so the label column aligns across
# pass/fail/skip rows: ASCII tags vary 4-7 cols ([OK]..[ERROR]) -> pad to 7;
# unicode icons are 1 col (multibyte, width 1 -> %-*s never byte-pads them).
_PC_GW=1
[[ "$_G_UNICODE" == 1 ]] || _PC_GW=7
check_pass() {
    printf "  ${GREEN}%-*s${NC} %-*s ${GRAY}%s${NC}\n" "$_PC_GW" "$(_ui_status_token ok)" "$_PC_LW" "$1" "${2:-}"
    CHECKS_PASS=$((CHECKS_PASS + 1))
}
check_fail() {
    printf "  ${RED}%-*s${NC} %-*s ${GRAY}%s${NC}\n" "$_PC_GW" "$(_ui_status_token error)" "$_PC_LW" "$1" "${2:-}"
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
}
check_skip() {
    printf "  ${YELLOW}%-*s${NC} %-*s ${GRAY}%s${NC}\n" "$_PC_GW" "$(_ui_status_token skip)" "$_PC_LW" "$1" "${2:-}"
    CHECKS_SKIP=$((CHECKS_SKIP + 1))
}

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

PUBLIC_IP=""
if net_detect_public_ip; then
    PUBLIC_IP="$_NET_PUBLIC_IP"
    log_info "Public IP: $PUBLIC_IP"
else
    log_warn "Could not detect public IP - skipping DNS comparison"
fi

# -----------------------------------------------------------------------------
# 2. DNS resolution (domain-dependent)
# -----------------------------------------------------------------------------
if $HAS_DOMAIN; then
    for host in "${service_hosts[@]}"; do
        resolved_ip=$(resolve_host_ip "$host")
        if [[ -n "$resolved_ip" ]]; then
            log_info "DNS: $host -> $resolved_ip"
            if [[ -n "$PUBLIC_IP" ]]; then
                if [[ "$resolved_ip" == "$PUBLIC_IP" ]]; then
                    check_pass "DNS $host" "matches public IP"
                else
                    check_fail "DNS $host" "-> $resolved_ip (want $PUBLIC_IP)"
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

if $HAS_DOMAIN; then
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
elif [[ -n "$PUBLIC_IP" ]]; then
    # Pre-install / no-domain: fall back to TCP-level external probe.
    # net_check_tcp_port_external spins up a temporary listener if nothing
    # is bound, then triggers the external probe — so this works on a fresh
    # box before NPM is installed. Privileged ports (80/443) need sudo to
    # bind; the helper sudo-wraps internally and may prompt.
    log_info "Probing TCP 80 + 443 (sudo may prompt to bind privileged ports)..."
    case $(
        net_check_tcp_port_external 80
        echo "rc:$?"
    ) in
        rc:0) check_pass "TCP 80 (HTTP)" "reachable" ;;
        rc:1) check_fail "TCP 80 (HTTP)" "no response" ;;
        rc:3) check_fail "TCP 80 (HTTP)" "forwarded to another device" ;;
        rc:4) check_skip "TCP 80 (HTTP)" "port in use - re-test later" ;;
        *) check_skip "TCP 80 (HTTP)" "probe unavailable" ;;
    esac
    case $(
        net_check_tcp_port_external 443
        echo "rc:$?"
    ) in
        rc:0) check_pass "TCP 443 (HTTPS)" "reachable" ;;
        rc:1) check_fail "TCP 443 (HTTPS)" "no response" ;;
        rc:3) check_fail "TCP 443 (HTTPS)" "forwarded to another device" ;;
        rc:4) check_skip "TCP 443 (HTTPS)" "port in use - re-test later" ;;
        *) check_skip "TCP 443 (HTTPS)" "probe unavailable" ;;
    esac
else
    check_skip "TCP 80 (HTTP)" "no public IP"
    check_skip "TCP 443 (HTTPS)" "no public IP"
fi

# TCP — qBittorrent listening port. Use the external probe so we get the
# same answer a real external peer would (canyouseeme/portchecker.io probe
# from their server, no hairpin-NAT dependency).
if [[ -n "$PUBLIC_IP" ]]; then
    case $(
        net_check_tcp_port_external "$TORRENT_PORT"
        echo "rc:$?"
    ) in
        rc:0) check_pass "TCP $TORRENT_PORT (torrent)" "reachable" ;;
        rc:1) check_fail "TCP $TORRENT_PORT (torrent)" "no response" ;;
        rc:3) check_fail "TCP $TORRENT_PORT (torrent)" "forwarded to another device" ;;
        rc:4) check_skip "TCP $TORRENT_PORT (torrent)" "port in use - re-test later" ;;
        *) check_skip "TCP $TORRENT_PORT (torrent)" "probe unavailable" ;;
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
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
LOCAL_IP="${LOCAL_IP:-<your-server-ip>}"
# LAN gateway = the router's admin page, where the user sets up forwarding.
GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')

total=$((CHECKS_PASS + CHECKS_FAIL + CHECKS_SKIP))
if [[ $CHECKS_FAIL -eq 0 ]]; then
    if ((CHECKS_SKIP > 0)); then
        # Avoid the misleading "1/4" framing when 3 of 4 are skipped — that
        # reads as a 25% pass rate to a non-technical user.
        log_ok "$CHECKS_PASS passed / $CHECKS_SKIP skipped / $CHECKS_FAIL failed"
    else
        log_ok "All checks passed ($CHECKS_PASS/$total)"
    fi
else
    log_warn "$CHECKS_FAIL of $total checks failed"
    echo ""
    echo -e "  ${BOLD}Hairpin NAT caveat:${NC} Some routers can't loop traffic back"
    echo "  to themselves. If checks fail here but access works from outside"
    echo "  your network (e.g., phone on mobile data), your forwarding is fine."
fi

if [[ $CHECKS_FAIL -gt 0 || $CHECKS_SKIP -gt 0 ]]; then
    echo ""
    # Script-scope array — port-check.sh is a top-level script, not a function.
    # `local` here triggered "local: can only be used in a function" on stderr.
    # Always list all four ports with conditional annotations — pre-install
    # users don't necessarily have a DOMAIN configured yet but still need to
    # know what to forward if they plan to enable remote access.
    fwd_lines=(
        "Forward these ports to $LOCAL_IP in your router:"
        ""
        "  TCP+UDP ${TORRENT_PORT}  ->  $LOCAL_IP   (torrent - always)"
        "  TCP 80       ->  $LOCAL_IP   (HTTP/ACME - domain only)"
        "  TCP 443      ->  $LOCAL_IP   (HTTPS - domain only)"
        "  UDP ${WG_PORT}    ->  $LOCAL_IP   (WireGuard - remote only)"
    )
    if [[ -n "$GATEWAY" ]]; then
        fwd_lines+=("" "Your router's admin page is usually http://${GATEWAY}")
    fi
    ui_box "Required Port Forwards" "${fwd_lines[@]}"
fi

echo ""

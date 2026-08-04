# Owns: Stage 2 port-failure classification, LAN detection, and WireGuard access tiers.
# Sources: scripts/lib/network.sh state plus ip, python3, and Docker-compose port policy.
stage2_is_rfc6598() {
    local ip="$1"
    IP="$ip" python3 -c '
import ipaddress
import os
import sys

try:
    ip = ipaddress.ip_address(os.environ["IP"])
except ValueError:
    sys.exit(1)
sys.exit(0 if ip in ipaddress.ip_network("100.64.0.0/10") else 1)
' 2>/dev/null
}

stage2_classify_port_failure() {
    local public_ip="$1"
    local dns_state="${2:-ok}"
    local port_state="${3:-closed}"
    local hint="${4:-}"

    case "$dns_state" in
        cloudflare)
            printf 'cloudflare'
            return 0
            ;;
        aaaa-mismatch)
            printf 'aaaa-mismatch'
            return 0
            ;;
        mismatch:*)
            printf 'wrong-lan-target'
            return 0
            ;;
    esac

    if stage2_is_rfc6598 "$public_ip"; then
        printf 'cgnat'
        return 0
    fi

    case "$port_state" in
        probe-unavailable:*)
            printf 'probe-unavailable'
            return 0
            ;;
    esac

    case "$hint" in
        carrier)
            printf 'carrier-block'
            ;;
        hairpin)
            printf 'hairpin-ambiguous'
            ;;
        wrong-lan-target)
            printf 'wrong-lan-target'
            ;;
        *)
            case "$port_state" in
                closed:80 | closed:443 | closed:80,443) printf '%s' "$port_state" ;;
                *) printf 'hairpin-ambiguous' ;;
            esac
            ;;
    esac
}

stage2_port_gate_classify() {
    local public_ip="$1"
    local dns_state="${2:-ok}"
    local hint="${3:-}"
    local port_state
    port_state=$(stage2_check_http_ports)
    if [[ "$port_state" == "ok" ]]; then
        printf 'ok'
        return 0
    fi
    stage2_classify_port_failure "$public_ip" "$dns_state" "$port_state" "$hint"
}

# detect_lan_cidr — read the host's default-route interface and emit the
# normalized network CIDR (e.g. host 192.168.1.50/24 → 192.168.1.0/24).
# Returns empty + non-zero on failure; caller decides the fallback.
detect_lan_cidr() {
    local iface host_cidr
    iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ -z "$iface" ]] && return 1
    host_cidr=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4; exit}')
    [[ -z "$host_cidr" ]] && return 1
    python3 -c '
import sys, ipaddress
try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except Exception:
    sys.exit(1)
' "$host_cidr" 2>/dev/null
}

# wg_firewall_ips_for_tier — returns the comma-separated firewallIps entries
# wg-easy expects for an initial peer at the given tier. Used by both the
# Stage-2 wizard preview and the wireguard configurator.
#
# Tiers:
#   full-lan    → whole LAN CIDR, all ports
#   server      → server IP /32, all ports (host services included: SSH, SMB, etc.)
#   containers  → server IP, explicit MediaStack container ports (51821 excluded)
#   streaming          → server IP, Jellyfin only (watch-only: kids)
#   streaming-requests → server IP, Jellyfin + Seerr (watch + request: friends)
#
# Container port list: keep in sync with docker-compose.yml. Excludes 51821
# (wg-easy admin) so containers-tier peers can't add or modify other peers.
wg_firewall_ips_for_tier() {
    local tier="$1" lan_cidr="$2" server_ip="$3"

    case "$tier" in
        full-lan)
            [[ -z "$lan_cidr" ]] && return 1
            printf '%s' "$lan_cidr"
            ;;
        server)
            [[ -z "$server_ip" ]] && return 1
            printf '%s/32' "$server_ip"
            ;;
        containers)
            [[ -z "$server_ip" ]] && return 1
            # Ports: 80/443/81 NPM (HTTP/HTTPS/admin), 3000 Homepage, 3001 Uptime Kuma,
            # 5055 Seerr, 6767 Bazarr, 7359/udp Jellyfin auto-discovery, 7878 Radarr,
            # 8000 DDNS, 8080 qBittorrent, 8090 Beszel, 8096 Jellyfin, 8191 FlareSolverr,
            # 8989 Sonarr, 9000 Portainer, 9117 Jackett. 51821 (wg-easy admin) excluded.
            local ports=(80/tcp 81/tcp 443/tcp 3000/tcp 3001/tcp 5055/tcp 6767/tcp
                7359/udp 7878/tcp 8000/tcp 8080/tcp 8090/tcp 8096/tcp 8191/tcp
                8989/tcp 9000/tcp 9117/tcp)
            local entries=() p
            for p in "${ports[@]}"; do entries+=("${server_ip}:${p}"); done
            local IFS=,
            printf '%s' "${entries[*]}"
            ;;
        streaming)
            [[ -z "$server_ip" ]] && return 1
            printf '%s:8096/tcp' "$server_ip"
            ;;
        streaming-requests)
            [[ -z "$server_ip" ]] && return 1
            printf '%s:8096/tcp,%s:5055/tcp' "$server_ip" "$server_ip"
            ;;
        *)
            return 1
            ;;
    esac
}

# stage2_wireguard_access_tier_env — given the wizard's tier choice plus the
# detected/confirmed LAN CIDR and server IP, emit the env-key lines the wizard
# persists. WG_PER_CLIENT_FIREWALL is true for every tier; users wanting full
# tunnel set both WG_INIT_ALLOWED_IPS and WG_PER_CLIENT_FIREWALL=false in .env.
stage2_wireguard_access_tier_env() {
    local tier="$1" lan_cidr="$2" server_ip="$3"
    local allowed_ips

    case "$tier" in
        full-lan)
            [[ -z "$lan_cidr" ]] && return 1
            allowed_ips="$lan_cidr"
            ;;
        server | containers | streaming | streaming-requests)
            [[ -z "$server_ip" ]] && return 1
            allowed_ips="${server_ip}/32"
            ;;
        *)
            return 1
            ;;
    esac

    printf "WG_ACCESS_TIER='%s'\n" "$tier"
    printf "WG_LAN_CIDR='%s'\n" "$lan_cidr"
    printf "WG_SERVER_LAN_IP='%s'\n" "$server_ip"
    printf "WG_INIT_ALLOWED_IPS='%s'\n" "$allowed_ips"
    printf "WG_PER_CLIENT_FIREWALL='true'\n"
}

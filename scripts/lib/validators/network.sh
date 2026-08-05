# Owns: Port-in-use helpers plus torrent/WireGuard/SMB port, domain, hostname, LAN CIDR, and IP validators.
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.

_validators_port_process_name() {
    local ss_output="$1"
    printf '%s\n' "$ss_output" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

_validators_wireguard_port_is_mediastack() {
    local value="$1"
    local rows row name ports

    [[ "${WG_PORT:-}" == "$value" ]] || return 1
    command -v docker >/dev/null 2>&1 || return 1

    rows=$(docker ps --filter name=wireguard --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        name="${row%% *}"
        ports="${row#* }"
        [[ "$name" == "wireguard" ]] || continue
        case "$ports" in
            *":${value}->"*"/udp"* | *"${value}/udp"*) return 0 ;;
        esac
    done <<<"$rows"

    return 1
}

validate_torrent_port() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "qBittorrent peer port is required."
        return 1
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        ui_log warn "qBittorrent peer port must be numeric."
        return 1
    fi
    if ((value < 1 || value > 65535)); then
        ui_log warn "qBittorrent peer port must be between 1 and 65535."
        return 1
    fi

    local ss_output process_name
    ss_output=$(sudo ss -lntp "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -n "$ss_output" ]]; then
        process_name=$(_validators_port_process_name "$ss_output")
        if [[ -n "$process_name" ]]; then
            ui_log warn "Port $value is in use by $process_name. Pick a different port."
        else
            ui_log warn "Port $value is already in use. Pick a different port."
        fi
        return 1
    fi
    return 0
}

validate_domain_name() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Domain name is required."
        return 1
    fi

    local lc="${value,,}"
    if [[ "$lc" == "localhost" || "$lc" == *".localhost" ]]; then
        ui_log warn "Use a real domain name, not localhost."
        return 1
    fi
    case "$lc" in
        example.com | *.example.com | example.org | *.example.org | example.net | *.example.net | example.edu | *.example.edu)
            ui_log warn "$value is a reserved example domain (RFC 2606) - enter your real domain."
            return 1
            ;;
        test | *.test | invalid | *.invalid)
            ui_log warn "$value is a reserved test/invalid domain (RFC 6761)."
            return 1
            ;;
    esac
    if ((${#value} > 253)); then
        ui_log warn "Domain name is too long."
        return 1
    fi
    if [[ "$value" != *.* || "$value" == *".."* || "$value" == *"_"* ]]; then
        ui_log warn "Domain must be a normal FQDN such as media.yourdomain.com."
        return 1
    fi

    local label
    IFS='.' read -ra labels <<<"$value"
    for label in "${labels[@]}"; do
        if [[ -z "$label" || ${#label} -gt 63 ]]; then
            ui_log warn "Domain labels must be 1-63 characters."
            return 1
        fi
        if ! [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
            ui_log warn "Domain labels may contain only letters, digits, and interior hyphens."
            return 1
        fi
    done
    return 0
}

validate_wireguard_hostname() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "WireGuard hostname is required."
        return 1
    fi
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        IFS='.' read -ra octets <<<"$value"
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                ui_log warn "WireGuard IPv4 address is invalid."
                return 1
            fi
        done
        return 0
    fi
    validate_domain_name "$value"
}

validate_wireguard_port() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "WireGuard UDP port is required."
        return 1
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        ui_log warn "WireGuard UDP port must be numeric."
        return 1
    fi
    if ((value < 1 || value > 65535)); then
        ui_log warn "WireGuard UDP port must be between 1 and 65535."
        return 1
    fi

    local ss_output process_name
    ss_output=$(sudo ss -lntu "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -n "$ss_output" ]]; then
        process_name=$(_validators_port_process_name "$ss_output")
        if _validators_wireguard_port_is_mediastack "$value"; then
            ui_log info "WireGuard UDP port $value is already in use by MediaStack wireguard - reusing it."
            return 0
        fi
        if [[ -n "$process_name" ]]; then
            ui_log warn "WireGuard UDP port $value is in use by $process_name. Pick a different port."
        else
            ui_log warn "WireGuard UDP port $value is already in use. Pick a different port."
        fi
        return 1
    fi
    return 0
}

validate_smb_port() {
    local value="${1:-445}"
    local ss_output process_name
    ss_output=$(sudo ss -lntp "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -z "$ss_output" ]]; then
        return 0
    fi
    process_name=$(_validators_port_process_name "$ss_output")
    # smbd on 445 IS MediaStack's SMB share — not a conflict. setup_samba()
    # will (re)write /etc/samba/smb.conf with the MEDIASTACK marker block
    # idempotently. This makes re-runs idempotent: once SMB is enabled and
    # smbd is running, the wizard re-run path doesn't false-flag it.
    if [[ "$process_name" == "smbd" ]]; then
        ui_log info "Port 445 in use by smbd - MediaStack will manage it."
        return 0
    fi
    if [[ -n "$process_name" ]]; then
        ui_log warn "Port 445 is in use by $process_name (not samba). Disable SMB or free the port."
    else
        ui_log warn "Port 445 is already in use. Disable SMB or free the port."
    fi
    return 1
}

validate_lan_cidr() {
    local value="$1"
    local rc
    if [[ -z "$value" ]]; then
        ui_log warn "LAN CIDR is required (e.g. 192.168.1.0/24)."
        return 1
    fi
    # Python `is_private` is too permissive — it also accepts loopback,
    # link-local, TEST-NET, CGNAT, etc. Home LANs are RFC1918 only.
    python3 -c '
import sys, ipaddress
try:
    n = ipaddress.IPv4Network(sys.argv[1], strict=False)
except Exception:
    sys.exit(2)
rfc1918 = (
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
)
if not any(n.subnet_of(r) for r in rfc1918):
    sys.exit(3)
' "$value" 2>/dev/null
    rc=$?
    if ((rc != 0)); then
        case "$rc" in
            2) ui_log warn "'$value' is not a valid IPv4 CIDR (try '192.168.1.0/24')." ;;
            3) ui_log warn "'$value' is not an RFC1918 LAN range - use 10/8, 172.16/12, or 192.168/16." ;;
            *) ui_log warn "Invalid LAN CIDR '$value'." ;;
        esac
        return 1
    fi
    return 0
}

# Accepts a single IPv4/IPv6 host address; rejects CIDR / range / hostname.
# Used by the fail2ban whitelist manual-entry path (mediastack). Mirrors
# validate_lan_cidr: empty -> warn+1; python3 ipaddress via argv.
validate_ip() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "An IP address is required (e.g. 203.0.113.45)."
        return 1
    fi
    if ! python3 -c 'import sys, ipaddress; ipaddress.ip_address(sys.argv[1])' "$value" 2>/dev/null; then
        ui_log warn "'$value' is not a valid IP address - enter a single IPv4 or IPv6 address (not a range or CIDR)."
        return 1
    fi
    return 0
}

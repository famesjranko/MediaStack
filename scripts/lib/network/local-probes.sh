# Owns: Local HTTP and port-boundary probes.
# Sources: scripts/lib/network.sh state plus nc, curl, and service-local network state.
net_is_port_locally_bound() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        return 1
    fi
    local hits
    hits=$(ss -tln "sport = :$port" 2>/dev/null | tail -n +2)
    [[ -n "$hits" ]]
}

# -----------------------------------------------------------------------------
# net_check_http <url> — check if an HTTP(S) endpoint responds
# Any HTTP status code (even 4xx/5xx) = port is forwarded. Returns 0/1.
# -----------------------------------------------------------------------------
net_check_http() {
    local url="$1"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then return 0; fi
    local code
    code=$(curl -sko /dev/null --connect-timeout 5 -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    [[ "$code" != "000" ]]
}

# -----------------------------------------------------------------------------
# net_check_port_status <port> <protocol>
# protocol: "tcp" | "udp"
# Stores result in _NET_PORT_STATUS[$port]: "open" | "closed" | "udp-unverifiable"
# -----------------------------------------------------------------------------
net_check_port_status() {
    local port="$1" proto="$2"
    case "$proto" in
        tcp)
            # "open" here means "something is bound locally" (a CONFLICT for
            # services about to be installed). "closed" means "free for our
            # service to bind." This is a local-availability check, not a
            # forwarding check — pre-install nothing is listening yet so
            # forwarding state is irrelevant.
            if net_is_port_locally_bound "$port"; then
                _NET_PORT_STATUS[$port]="open"
            else
                _NET_PORT_STATUS[$port]="closed"
            fi
            ;;
        udp)
            _NET_PORT_STATUS[$port]="udp-unverifiable"
            ;;
    esac
}


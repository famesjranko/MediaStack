# Owns: setup_* — post-wizard UFW rules for configurable torrent and WireGuard ports.
# Sources: hardening.sh globals and firewall.sh's _ms_ufw_allow.
# Globals: TORRENT_PORT, DOMAIN, and WG_PORT (optional .env inputs).

setup_ufw_service_ports() {
    command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]] || return

    local torrent_port="${TORRENT_PORT:-6881}"
    _ms_ufw_allow "$torrent_port/tcp" comment MediaStack:Torrent-TCP >/dev/null 2>&1
    _ms_ufw_allow "$torrent_port/udp" comment MediaStack:Torrent-UDP >/dev/null 2>&1

    local domain="${DOMAIN:-example.com}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        local wg_port="${WG_PORT:-51820}"
        _ms_ufw_allow "$wg_port/udp" comment MediaStack:WireGuard >/dev/null 2>&1
    fi

    sudo ufw reload >/dev/null 2>&1
    local port_msg="torrent ${torrent_port}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        port_msg="${port_msg}, VPN ${WG_PORT:-51820}"
    fi
    log_ok "Firewall: service ports opened (${port_msg})"
}

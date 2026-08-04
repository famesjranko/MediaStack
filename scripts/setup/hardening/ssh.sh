# Owns: SSH port detection, address validation, and UFW SSH rules.
# Sources: hardening.sh globals and firewall.sh's _ms_ufw_allow helper.
# Globals: LAN_CIDRS, SSH_CONNECTION, and SSH_TTY (optional host inputs).

ufw_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

ufw_add_unique_port() {
    local -n ports_ref=$1
    local port="${2:-}"
    local existing

    ufw_valid_port "$port" || return 0
    for existing in "${ports_ref[@]}"; do
        [[ "$existing" == "$port" ]] && return 0
    done
    ports_ref+=("$port")
}

detect_ssh_server_ports() {
    local ports=()
    local server_port

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # Only the 4th field (server_port) is needed; the rest go to throwaway `_`.
        read -r _ _ _ server_port _ <<<"$SSH_CONNECTION"
        ufw_add_unique_port ports "$server_port"
    fi

    local sshd_bin=""
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin="$(command -v sshd)"
    elif [[ -x /usr/sbin/sshd ]]; then
        sshd_bin="/usr/sbin/sshd"
    fi

    if [[ -n "$sshd_bin" ]]; then
        while read -r server_port; do
            ufw_add_unique_port ports "$server_port"
        done < <(sudo "$sshd_bin" -T 2>/dev/null | awk 'tolower($1) == "port" {print $2}')
    fi

    while read -r server_port; do
        ufw_add_unique_port ports "$server_port"
    done < <(sudo awk 'tolower($1) == "port" {print $2}' /etc/ssh/sshd_config 2>/dev/null)

    ((${#ports[@]} > 0)) && printf '%s\n' "${ports[@]}"
}

ufw_valid_ipv4() {
    local ip="${1:-}"
    local a b c d

    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}"
    b="${BASH_REMATCH[2]}"
    c="${BASH_REMATCH[3]}"
    d="${BASH_REMATCH[4]}"

    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

ufw_rfc1918_ipv4() {
    local ip="${1:-}"
    local a b _c _d

    ufw_valid_ipv4 "$ip" || return 1
    IFS=. read -r a b _c _d <<<"$ip"

    ((10#$a == 10)) && return 0
    ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)) && return 0
    ((10#$a == 192 && 10#$b == 168)) && return 0
    return 1
}

ufw_valid_ip_literal() {
    local ip="${1:-}"

    ufw_valid_ipv4 "$ip" && return 0
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
}

detect_active_ssh_client() {
    local client_ip server_port

    [[ -n "${SSH_CONNECTION:-}" ]] || return 0
    # SSH_CONNECTION = "<client_ip> <client_port> <server_ip> <server_port>"; only
    # the client IP and server port are used, the rest go to throwaway `_`.
    read -r client_ip _ _ server_port _ <<<"$SSH_CONNECTION"
    ufw_valid_ip_literal "$client_ip" || return 0
    ufw_valid_port "$server_port" || return 0

    printf '%s %s\n' "$client_ip" "$server_port"
}

ufw_allow_ssh_port() {
    local port="${1:-}"
    local active_client_ip="${2:-}"
    local active_server_port="${3:-}"

    ufw_valid_port "$port" || return 0

    local cidr
    for cidr in "${LAN_CIDRS[@]}"; do
        _ms_ufw_allow from "$cidr" to any port "$port" proto tcp comment MediaStack:SSH-LAN >/dev/null
    done

    if [[ -n "$active_client_ip" && "$active_server_port" == "$port" ]] \
        && ! ufw_rfc1918_ipv4 "$active_client_ip"; then
        _ms_ufw_allow from "$active_client_ip" to any port "$port" proto tcp comment MediaStack:SSH-current-client >/dev/null
    fi
}

setup_ufw_ssh_rules() {
    local ssh_ports=()
    mapfile -t ssh_ports < <(detect_ssh_server_ports)

    local active_client_ip=""
    local active_server_port=""
    local active_client=()
    mapfile -t active_client < <(detect_active_ssh_client)
    if ((${#active_client[@]} > 0)); then
        read -r active_client_ip active_server_port <<<"${active_client[0]}"
    fi

    if ((${#ssh_ports[@]} == 0)); then
        if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
            log_warn "Could not detect the active SSH port; keeping 22/tcp open before enabling UFW."
        fi
        ssh_ports=(22)
    fi

    local ssh_port
    for ssh_port in "${ssh_ports[@]}"; do
        ufw_allow_ssh_port "$ssh_port" "$active_client_ip" "$active_server_port"
    done
}

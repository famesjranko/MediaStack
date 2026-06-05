# =============================================================================
# MediaStack Setup — OS hardening and optional SMB file share
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# setup_hardening() — UFW, unattended-upgrades, sysctl, GPU runtime check.
#                     No wizard dependencies; runs before the wizard.
# setup_samba()     — Optional SMB share. Needs credentials + DATA_DIR from
#                     .env; runs after the wizard.

# ---------------------------------------------------------------------------
# UFW firewall
# ---------------------------------------------------------------------------

ufw_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
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
        read -r _ _ _ server_port _ <<< "$SSH_CONNECTION"
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

    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

ufw_rfc1918_ipv4() {
    local ip="${1:-}"
    local a b _c _d

    ufw_valid_ipv4 "$ip" || return 1
    IFS=. read -r a b _c _d <<< "$ip"

    (( 10#$a == 10 )) && return 0
    (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )) && return 0
    (( 10#$a == 192 && 10#$b == 168 )) && return 0
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
    read -r client_ip _ _ server_port _ <<< "$SSH_CONNECTION"
    ufw_valid_ip_literal "$client_ip" || return 0
    ufw_valid_port "$server_port" || return 0

    printf '%s %s\n' "$client_ip" "$server_port"
}

ufw_allow_ssh_port() {
    local port="${1:-}"
    local active_client_ip="${2:-}"
    local active_server_port="${3:-}"

    ufw_valid_port "$port" || return 0

    sudo ufw allow from 10.0.0.0/8 to any port "$port" proto tcp comment 'SSH (LAN)' >/dev/null
    sudo ufw allow from 172.16.0.0/12 to any port "$port" proto tcp comment 'SSH (LAN)' >/dev/null
    sudo ufw allow from 192.168.0.0/16 to any port "$port" proto tcp comment 'SSH (LAN)' >/dev/null

    if [[ -n "$active_client_ip" && "$active_server_port" == "$port" ]] \
        && ! ufw_rfc1918_ipv4 "$active_client_ip"; then
        sudo ufw allow from "$active_client_ip" to any port "$port" proto tcp comment 'SSH (current client)' >/dev/null
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
        read -r active_client_ip active_server_port <<< "${active_client[0]}"
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
        sudo ufw delete allow "$ssh_port/tcp" >/dev/null 2>&1 || true
    done
}

setup_ufw() {
    if ! command -v ufw &>/dev/null; then
        log_info "Installing ufw..."
        sudo apt-get install -y -qq ufw >/dev/null 2>&1
    fi

    if sudo ufw status 2>/dev/null | grep -q "Status: active" \
       && sudo ufw status 2>/dev/null | grep -q "45876/tcp"; then
        setup_ufw_ssh_rules
        if ufw_docker_rules_installed; then
            log_skip "UFW already configured (service, SSH, and Docker rules found)"
            return
        fi
        log_info "UFW service rules found; repairing Docker LAN-only restrictions..."
        setup_ufw_docker_rules
        return
    fi

    log_info "Configuring UFW firewall..."

    sudo ufw --force reset >/dev/null 2>&1

    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null

    setup_ufw_ssh_rules
    sudo ufw allow 80/tcp >/dev/null           # HTTP / Let's Encrypt
    sudo ufw allow 443/tcp >/dev/null          # HTTPS
    # Configurable ports (TORRENT_PORT, WG_PORT) are opened by
    # setup_ufw_service_ports() after the wizard sets their values.
    sudo ufw allow from 172.16.0.0/12 to any port 45876 proto tcp >/dev/null  # Beszel hub->agent (Docker bridge->host)

    sudo ufw --force enable >/dev/null

    setup_ufw_docker_rules

    log_ok "UFW firewall enabled"
}

# Docker bypasses UFW via direct iptables manipulation. Inject rules into
# the DOCKER-USER chain via /etc/ufw/after.rules to restrict management
# ports to LAN-only access.
ufw_docker_rules_persisted() {
    sudo grep -q '# MEDIASTACK-DOCKER-RULES' /etc/ufw/after.rules 2>/dev/null
}

ufw_docker_jump_live() {
    sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1
}

ufw_docker_rules_installed() {
    ufw_docker_rules_persisted && ufw_docker_jump_live
}

setup_ufw_docker_rules() {
    local after_rules="/etc/ufw/after.rules"
    local rules_persisted=false

    if ufw_docker_rules_persisted; then
        rules_persisted=true
    fi

    if [[ "$rules_persisted" == "true" ]] && ufw_docker_jump_live; then
        return
    fi

    if [[ "$rules_persisted" == "true" ]]; then
        log_info "Reloading Docker/UFW restriction rules..."
    else
        log_info "Adding Docker/UFW restriction rules..."

        sudo tee -a "$after_rules" >/dev/null <<'RULES'

# MEDIASTACK-DOCKER-RULES — restrict Docker management ports to LAN
*filter
:MEDIASTACK-DOCKER-RESTRICT - [0:0]

# Jump from DOCKER-USER into our chain
-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT

# Allow private networks to all Docker ports
-A MEDIASTACK-DOCKER-RESTRICT -s 127.0.0.0/8 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 10.0.0.0/8 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 172.16.0.0/12 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 192.168.0.0/16 -j RETURN

# DROP non-private traffic to LAN-only Docker ports.
# Split into two multiport rules — iptables -m multiport caps at 15 ports
# per match (kernel limit). Going over yields:
#     iptables-restore: too many ports specified
# which silently breaks ufw reload, leaves UFW in a half-loaded state, and
# cascades through Docker bridge networking on the next boot.
-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 8989,7878,9117,8080,5055,9000,81,51821 -j DROP
-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 8000,8090,3001,45876,8191,6767,8096,3000 -j DROP

# Allow everything else (public ports like 80 and 443 pass through)
-A MEDIASTACK-DOCKER-RESTRICT -j RETURN

COMMIT
RULES
    fi

    # Surface ufw-init failures instead of silently swallowing them.
    # ufw reload returns 0 even when /etc/ufw/after.rules is broken — the
    # iptables-restore error only shows up at next ufw-init or system boot,
    # far from where the bad rule was added. Capture stderr explicitly.
    local ufw_err
    ufw_err=$(sudo ufw reload 2>&1 >/dev/null)
    if [[ -n "$ufw_err" ]] && echo "$ufw_err" | grep -qiE 'error|problem'; then
        log_warn "ufw reload reported issues:"
        echo "$ufw_err" | sed 's/^/  /' | head -5
        return 1
    fi

    if sudo iptables -L DOCKER-USER -n >/dev/null 2>&1 && ! ufw_docker_jump_live; then
        log_warn "Docker LAN-only restriction jump is still missing from DOCKER-USER after UFW reload."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Unattended upgrades (security-only)
# ---------------------------------------------------------------------------

setup_unattended_upgrades() {
    if ! command -v unattended-upgrade &>/dev/null; then
        log_info "Installing unattended-upgrades..."
        sudo apt-get install -y -qq unattended-upgrades >/dev/null 2>&1
    fi

    local auto_conf="/etc/apt/apt.conf.d/20auto-upgrades"
    if sudo grep -q 'MediaStack' "$auto_conf" 2>/dev/null; then
        log_skip "Unattended-upgrades already configured"
        return
    fi

    log_info "Configuring automatic security updates..."

    sudo tee "$auto_conf" >/dev/null <<'EOF'
// MediaStack - automatic security updates
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    sudo tee /etc/apt/apt.conf.d/50unattended-upgrades >/dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

Unattended-Upgrade::Package-Blacklist {
    "linux-image*";
    "linux-headers*";
    "nvidia*";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF

    log_ok "Automatic security updates configured"
}

# ---------------------------------------------------------------------------
# Sysctl kernel hardening
# ---------------------------------------------------------------------------

setup_sysctl_hardening() {
    local conf="/etc/sysctl.d/90-mediastack-hardening.conf"

    if [[ -f "$conf" ]]; then
        log_skip "Sysctl hardening already applied"
        return
    fi

    log_info "Applying kernel hardening (sysctl)..."

    sudo tee "$conf" >/dev/null <<'EOF'
# MediaStack — kernel hardening
# Does NOT touch ip_forward (Docker + WireGuard need it enabled)

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirects (MITM prevention)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Reverse path filtering (IP spoofing prevention)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore broadcast ICMP (smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log impossible source addresses
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

    sudo sysctl --system >/dev/null 2>&1

    log_ok "Kernel hardening applied"
}

# ---------------------------------------------------------------------------
# GPU runtime verification (nvidia daemon.json check)
# ---------------------------------------------------------------------------

verify_gpu_runtime() {
    [[ "${GPU_TYPE:-none}" != "nvidia" ]] && return

    local daemon_json="/etc/docker/daemon.json"
    if [[ ! -f "$daemon_json" ]]; then
        log_warn "daemon.json missing - attempting nvidia-ctk runtime configure..."
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        sudo systemctl restart docker 2>/dev/null || true
        return
    fi

    local has_nvidia
    has_nvidia=$(python3 -c "
import json, sys
with open('$daemon_json') as f:
    d = json.load(f)
runtimes = d.get('runtimes', {})
if 'nvidia' in runtimes:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")

    if [[ "$has_nvidia" == "yes" ]]; then
        log_ok "NVIDIA Docker runtime registered in daemon.json"
    else
        log_warn "NVIDIA runtime missing from daemon.json - attempting auto-repair..."
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        sudo systemctl restart docker 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Service-specific UFW ports — called after the wizard (needs .env values)
# ---------------------------------------------------------------------------

setup_ufw_service_ports() {
    command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]] || return

    local torrent_port="${TORRENT_PORT:-6881}"
    sudo ufw allow "$torrent_port/tcp" >/dev/null 2>&1
    sudo ufw allow "$torrent_port/udp" >/dev/null 2>&1

    local domain="${DOMAIN:-example.com}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        local wg_port="${WG_PORT:-51820}"
        sudo ufw allow "$wg_port/udp" >/dev/null 2>&1
    fi

    sudo ufw reload >/dev/null 2>&1
    local port_msg="torrent ${torrent_port}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        port_msg="${port_msg}, VPN ${WG_PORT:-51820}"
    fi
    log_ok "Firewall: service ports opened (${port_msg})"
}

# ---------------------------------------------------------------------------
# Public orchestrator — called before the wizard
# ---------------------------------------------------------------------------

setup_hardening() {
    log_info "Applying OS hardening..."
    echo ""

    setup_ufw
    setup_unattended_upgrades
    setup_sysctl_hardening
    verify_gpu_runtime

    log_ok "OS hardening complete"
}

# ---------------------------------------------------------------------------
# SMB file share — called after the wizard (needs .env values)
# ---------------------------------------------------------------------------

# MediaStack writes its [Media] share to a dedicated include file rather than
# overwriting /etc/samba/smb.conf. The previous behavior `sudo tee smb.conf`
# (no -a) destroyed any pre-existing user samba config on the very first
# SMB_ENABLED=true install, and left orphaned MediaStack stanzas in the file
# on reinstall with SMB_ENABLED=false. The include-file layout:
#   • cleanup is just `rm` — no sed surgery on a shared host file
#   • the user's main smb.conf [global] is preserved (we don't define [global])
#   • the include = line in main smb.conf is left in place after cleanup;
#     samba logs a config-load warning if the file is missing but does not
#     abort — and a subsequent SMB_ENABLED=true install reuses the same path
SAMBA_INCLUDE_FILE="/etc/samba/smb.conf.d/mediastack.conf"
SAMBA_MAIN_CONF="/etc/samba/smb.conf"
# Idempotency keys off the functional `include = <path>` line — a filesystem
# path that is byte-stable and never reformatted — NOT a decorative comment
# marker, whose punctuation is a fragile grep target (an em-dash in the old
# marker silently broke detection when it was "tidied"). The include line is
# derived inline from SAMBA_INCLUDE_FILE at the point of use (so it tracks the
# current path); the comment below is written for humans only and is never matched.
SAMBA_INCLUDE_MARKER="# MEDIASTACK include - managed by setup.sh"

setup_samba() {
    if [[ "${SMB_ENABLED:-false}" != "true" ]]; then
        # Cleanup path: undo a prior SMB_ENABLED=true install. Removing the
        # include file silences the [Media] share. Samba tolerates the now-
        # dangling `include = …` line in main smb.conf with just a warning,
        # so we leave it there — re-enabling SMB later just rewrites the
        # include file at the same path.
        if [[ -f "$SAMBA_INCLUDE_FILE" ]]; then
            log_info "SMB_ENABLED=false - removing MediaStack samba config..."
            sudo rm -f "$SAMBA_INCLUDE_FILE"
            sudo systemctl reload smbd >/dev/null 2>&1 || true
            log_ok "MediaStack samba config removed (user samba config preserved)"
        fi
        return
    fi

    if ! command -v smbd &>/dev/null; then
        log_info "Installing samba..."
        sudo apt-get install -y -qq samba >/dev/null 2>&1
    fi

    local admin_user="${JELLYFIN_ADMIN_USER:-admin}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-changeme}"
    local smb_scope="${SMB_SHARE_SCOPE:-data}"
    local share_name share_comment share_path
    case "$smb_scope" in
        system)
            share_name="MediaStackSystem"
            share_comment="MediaStack full system access"
            share_path="/"
            ;;
        data|"")
            share_name="Media"
            share_comment="MediaStack data directory"
            share_path="${DATA_DIR:-/data}"
            ;;
        *)
            log_warn "Unknown SMB_SHARE_SCOPE='$smb_scope' - using data-only share"
            smb_scope="data"
            share_name="Media"
            share_comment="MediaStack data directory"
            share_path="${DATA_DIR:-/data}"
            ;;
    esac

    # The functional, byte-stable idempotency marker: the include line itself.
    local include_line="include = $SAMBA_INCLUDE_FILE"

    # Idempotency: include file present AND include line present in main conf.
    # If the requested scope differs from an existing generated include, warn
    # and leave it alone. Re-runs must not silently rewrite host file-sharing
    # scope behind the user's back.
    if [[ -f "$SAMBA_INCLUDE_FILE" ]] \
        && sudo grep -Fxq "$include_line" "$SAMBA_MAIN_CONF" 2>/dev/null; then
        if sudo grep -Fxq "[$share_name]" "$SAMBA_INCLUDE_FILE" 2>/dev/null \
            && sudo grep -Fxq "   path = $share_path" "$SAMBA_INCLUDE_FILE" 2>/dev/null; then
            log_skip "Samba already configured"
        else
            log_warn "Samba already configured with a different MediaStack share scope; leaving existing SMB config unchanged."
        fi
        return
    fi

    # Same hardcoded-1000 trap as create_data_dirs: when .env hasn't been
    # generated yet, falling back to 1000 picks the wrong group on hosts
    # where the operator isn't uid 1000. Use the operator's actual gid so
    # SMB admin is added to the right group for /data access.
    local pgid="${PGID:-$(id -g)}"

    log_info "Configuring SMB file share..."

    if ! id "$admin_user" &>/dev/null; then
        sudo useradd -M -s /usr/sbin/nologin "$admin_user" 2>/dev/null || true
    fi

    local gid_group
    gid_group=$(getent group "$pgid" | cut -d: -f1)
    if [[ -n "$gid_group" ]]; then
        sudo usermod -aG "$gid_group" "$admin_user" 2>/dev/null || true
    fi

    printf '%s\n%s\n' "$admin_pw" "$admin_pw" | sudo smbpasswd -a -s "$admin_user" >/dev/null 2>&1

    # Write the [Media] share to the dedicated include file. NO [global]
    # block: that would silently override the user's main-conf [global] on
    # samba reload and break existing shares. The user's [global] owns
    # workgroup, server-role, security-mode, etc.
    sudo install -d -m 0755 "$(dirname "$SAMBA_INCLUDE_FILE")"
    sudo tee "$SAMBA_INCLUDE_FILE" >/dev/null <<EOF
# Managed by MediaStack setup.sh — DO NOT EDIT
# Edits will be overwritten on the next setup.sh run. Disable via
# SMB_ENABLED=false in .env (rerun ./setup.sh) — this file will be removed.

[$share_name]
   comment = $share_comment
   path = $share_path
   browseable = yes
   read only = no
   valid users = ${admin_user}
   create mask = 0664
   directory mask = 0775
EOF

    # Idempotently add the include line to main smb.conf (append-only — never
    # overwrite). Detection keys on the `include = <path>` line itself, so the
    # human-readable comment written above it is decorative and never matched.
    if [[ ! -f "$SAMBA_MAIN_CONF" ]]; then
        sudo install -m 0644 /dev/null "$SAMBA_MAIN_CONF"
    fi
    if ! sudo grep -Fxq "$include_line" "$SAMBA_MAIN_CONF"; then
        printf '\n%s\n%s\n' "$SAMBA_INCLUDE_MARKER" "$include_line" \
            | sudo tee -a "$SAMBA_MAIN_CONF" >/dev/null
    fi

    sudo systemctl enable --now smbd >/dev/null 2>&1
    sudo systemctl reload smbd >/dev/null 2>&1 || true

    # LAN-only SMB access
    sudo ufw allow from 10.0.0.0/8 to any port 445 proto tcp comment 'SMB (LAN)' >/dev/null 2>&1
    sudo ufw allow from 172.16.0.0/12 to any port 445 proto tcp comment 'SMB (LAN)' >/dev/null 2>&1
    sudo ufw allow from 192.168.0.0/16 to any port 445 proto tcp comment 'SMB (LAN)' >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1

    log_ok "SMB share configured: \\\\<server-ip>\\${share_name} -> ${share_path}"
}

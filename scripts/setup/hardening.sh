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

MEDIASTACK_STATE_DIR=/etc/mediastack
MEDIASTACK_STATE_FILE="$MEDIASTACK_STATE_DIR/install-state"
MEDIASTACK_APT_AUTO_CONF=/etc/apt/apt.conf.d/21mediastack-auto-upgrades
MEDIASTACK_APT_POLICY_CONF=/etc/apt/apt.conf.d/51mediastack-unattended-upgrades
MEDIASTACK_SYSCTL_CONF=/etc/sysctl.d/90-mediastack-hardening.conf
MEDIASTACK_UFW_AFTER_RULES=/etc/ufw/after.rules
MEDIASTACK_UFW_AFTER_INIT=/etc/ufw/after.init

_ms_state_get() {
    local key="$1"
    sudo awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' \
        "$MEDIASTACK_STATE_FILE" 2>/dev/null
}

_ms_state_set() {
    local key="$1" value="$2" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    tmp=$(mktemp)
    if sudo test -f "$MEDIASTACK_STATE_FILE"; then
        # shellcheck disable=SC2024 # output intentionally goes to the user-owned temp file
        sudo awk -F= -v key="$key" '$1 != key' "$MEDIASTACK_STATE_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    sudo install -d -m 0755 "$MEDIASTACK_STATE_DIR" \
        && sudo install -m 0600 "$tmp" "$MEDIASTACK_STATE_FILE"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

_ms_root_sha256() {
    sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

_ms_stream_sha256() {
    sha256sum | awk '{print $1}'
}

_ufw_rule_hash() {
    LC_ALL=C sudo ufw show added 2>/dev/null | sed -n '/^ufw /p' | _ms_stream_sha256
}

_ufw_defaults() {
    LC_ALL=C sudo ufw status verbose 2>/dev/null \
        | sed -n 's/^Default: \([^ ]*\) (incoming), \([^ ]*\) (outgoing).*/\1 \2/p' \
        | head -1
}

_ms_ufw_allow() {
    # ufw prints "Rule added"/"Skipping adding existing rule" to stdout on each
    # call; suppress that per-rule noise (the caller logs a single summary line).
    # stderr is preserved so genuine ufw errors still surface.
    sudo ufw allow "$@" >/dev/null || return 1
    sudo test -f "$MEDIASTACK_STATE_FILE" || return 0
    local rule="allow $*" count i
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    for ((i = 1; i <= count; i++)); do
        [[ "$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)" == "$rule" ]] && return 0
    done
    count=$((count + 1))
    _ms_state_set "UFW_RULE_$count" "$rule" && _ms_state_set UFW_RULE_COUNT "$count"
}

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

    _ms_ufw_allow from 10.0.0.0/8 to any port "$port" proto tcp comment MediaStack:SSH-LAN >/dev/null
    _ms_ufw_allow from 172.16.0.0/12 to any port "$port" proto tcp comment MediaStack:SSH-LAN >/dev/null
    _ms_ufw_allow from 192.168.0.0/16 to any port "$port" proto tcp comment MediaStack:SSH-LAN >/dev/null

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
    done
}

setup_ufw() {
    if ! command -v ufw &>/dev/null; then
        ui_spin "Installing ufw..." sudo apt-get install -y -qq ufw
    fi

    if [[ "$(_ms_state_get UFW_DEFAULTS_APPLIED 2>/dev/null || true)" == "true" \
        && "$(_ufw_defaults)" != "deny allow" ]]; then
        log_warn "UFW default policy changed after setup; leaving UFW unchanged"
        return 0
    fi

    # Install/refresh the DOCKER-USER jump dedup hook (idempotent, marker-guarded).
    # After the drift guard above so a "leaving UFW unchanged" box is untouched;
    # before the skip guard below so existing installs pick it up on a re-run.
    setup_ufw_docker_dedup_hook

    if sudo ufw status 2>/dev/null | grep -q 'MediaStack:Beszel-agent' \
        && ufw_docker_rules_installed; then
        if [[ "$(_ufw_defaults)" == "deny allow" ]]; then
            log_skip "UFW already configured"
        else
            log_warn "UFW default policy changed after setup; leaving it unchanged"
        fi
        return 0
    fi

    log_info "Configuring UFW firewall..."
    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    _ms_state_set UFW_DEFAULTS_APPLIED true

    setup_ufw_ssh_rules
    _ms_ufw_allow 80/tcp comment MediaStack:HTTP-ACME >/dev/null
    _ms_ufw_allow 443/tcp comment MediaStack:HTTPS >/dev/null
    # Configurable ports (TORRENT_PORT, WG_PORT) are opened by
    # setup_ufw_service_ports() after the wizard sets their values.
    _ms_ufw_allow from 172.16.0.0/12 to any port 45876 proto tcp comment MediaStack:Beszel-agent >/dev/null

    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw --force enable >/dev/null
        _ms_state_set UFW_ENABLED_BY_MEDIASTACK true
    fi

    setup_ufw_docker_rules || return 1

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
# END MEDIASTACK-DOCKER-RULES
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

# The after.rules block appends `-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT`
# on every full UFW load (iptables-restore --noflush never flushes DOCKER-USER),
# so the jump accumulates one copy per `ufw reload`. We cannot flush DOCKER-USER
# (fail2ban parks its own f2b-* jumps there) and cannot delete-before-add inside
# after.rules (iptables-restore aborts the whole batch on an absent rule). So the
# jump stays in after.rules (fail-closed: it always exists after a load) and this
# after.init hook — run by ufw-init at the end of every start/reload — trims any
# duplicates back to one. Emitted as literal text for /etc/ufw/after.init.
_ufw_docker_dedup_block() {
    cat <<'DEDUP'
# >>> MEDIASTACK-DOCKER-DEDUP (issue #214) — keep exactly one DOCKER-USER→RESTRICT jump
    while [ "$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT')" -gt 1 ]; do
        iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || break
    done
# <<< MEDIASTACK-DOCKER-DEDUP
DEDUP
}

setup_ufw_docker_dedup_hook() {
    local after_init="$MEDIASTACK_UFW_AFTER_INIT"

    # Idempotent: our marker already present -> nothing to do.
    if sudo test -f "$after_init" && sudo grep -q 'MEDIASTACK-DOCKER-DEDUP' "$after_init"; then
        log_skip "Docker jump dedup hook already installed"
        return
    fi

    local created=false was_executable=false
    if sudo test -f "$after_init"; then
        sudo test -x "$after_init" && was_executable=true
    else
        created=true
    fi

    if [[ "$created" == "true" ]]; then
        # No stock sample present — write a minimal MediaStack-owned hook.
        {
            printf '%s\n' '#!/bin/sh' \
                '# after.init — MediaStack-managed; trims duplicate DOCKER-USER jumps (issue #214).' \
                'set -e' \
                'case "$1" in' \
                'start)'
            _ufw_docker_dedup_block
            printf '%s\n' '    ;;' 'esac'
        } | sudo tee "$after_init" >/dev/null
        _ms_state_set UFW_AFTER_INIT_CREATED true
    else
        # Existing after.init (stock Canonical sample on a normal install):
        # inject inside the existing start) arm. Injecting there — rather than
        # appending a second case block — keeps us safe from a trailing exit and
        # from a second exiting *) default. Refuse to edit a file without a clean
        # stock start) arm (re-run invariant: warn + skip, never auto-reconcile).
        if ! sudo grep -qE '^[[:space:]]*start\)[[:space:]]*$' "$after_init"; then
            log_warn "Custom /etc/ufw/after.init present; skipping the DOCKER-USER dedup hook."
            log_warn "Add the MEDIASTACK-DOCKER-DEDUP snippet to its start) arm by hand if you want it."
            return
        fi
        local block_file tmp
        block_file=$(mktemp)
        tmp=$(mktemp)
        _ufw_docker_dedup_block >"$block_file"
        # Insert the block after the first start) line only. sudo reads the
        # root-owned file; awk and the redirect stay unprivileged (bf and tmp
        # are our own temp files).
        sudo cat "$after_init" | awk -v bf="$block_file" '
            { print }
            /^[[:space:]]*start\)[[:space:]]*$/ && !done {
                while ((getline line < bf) > 0) print line
                close(bf)
                done = 1
            }
        ' >"$tmp"
        # Never overwrite the live hook unless the block actually landed.
        if ! grep -q 'MEDIASTACK-DOCKER-DEDUP' "$tmp"; then
            rm -f "$block_file" "$tmp"
            log_warn "Could not inject the DOCKER-USER dedup block into /etc/ufw/after.init; skipping."
            return
        fi
        sudo tee "$after_init" >/dev/null <"$tmp"
        rm -f "$block_file" "$tmp"
        # We injected into a pre-existing file — we did NOT create the whole
        # thing. Record that so a later uninstall strips only our block instead
        # of rm-ing the file (clears any stale =true left by an earlier
        # created-install whose file was since replaced out-of-band).
        _ms_state_set UFW_AFTER_INIT_CREATED false
    fi

    # Make it runnable only if it wasn't already — never re-mode an admin's
    # executable hook. The state flag mirrors "we flipped the exec bit".
    if [[ "$was_executable" == "false" ]]; then
        sudo chmod 750 "$after_init"
        [[ "$created" == "false" ]] && _ms_state_set UFW_AFTER_INIT_ACTIVATED true
    fi

    # Normalize any duplicates that already accumulated, without waiting for the
    # next reload. Safe any time: it only ever deletes surplus copies of our jump.
    sudo "$after_init" start >/dev/null 2>&1 || true

    log_ok "Docker jump dedup hook installed"
}

# ---------------------------------------------------------------------------
# Unattended upgrades (security-only)
# ---------------------------------------------------------------------------

setup_unattended_upgrades() {
    if ! command -v unattended-upgrade &>/dev/null; then
        ui_spin "Installing unattended-upgrades..." sudo apt-get install -y -qq unattended-upgrades
    fi

    if sudo test -e "$MEDIASTACK_APT_AUTO_CONF" \
        || sudo test -e "$MEDIASTACK_APT_POLICY_CONF"; then
        if sudo test -f "$MEDIASTACK_APT_AUTO_CONF" \
            && sudo test -f "$MEDIASTACK_APT_POLICY_CONF" \
            && [[ "$(_ms_root_sha256 "$MEDIASTACK_APT_AUTO_CONF")" == "$(_ms_state_get APT_AUTO_SHA256 2>/dev/null || true)" \
            && "$(_ms_root_sha256 "$MEDIASTACK_APT_POLICY_CONF")" == "$(_ms_state_get APT_POLICY_SHA256 2>/dev/null || true)" ]]; then
            log_skip "Unattended-upgrades already configured"
        else
            log_warn "MediaStack unattended-upgrades files are incomplete or changed; leaving them unchanged"
        fi
        return
    fi

    log_info "Configuring automatic security updates..."

    sudo tee "$MEDIASTACK_APT_AUTO_CONF" >/dev/null <<'EOF'
// MediaStack - automatic security updates
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    sudo tee "$MEDIASTACK_APT_POLICY_CONF" >/dev/null <<'EOF'
// MediaStack - security-only unattended upgrades
#clear Unattended-Upgrade::Allowed-Origins;
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

    _ms_state_set APT_AUTO_SHA256 "$(_ms_root_sha256 "$MEDIASTACK_APT_AUTO_CONF")"
    _ms_state_set APT_POLICY_SHA256 "$(_ms_root_sha256 "$MEDIASTACK_APT_POLICY_CONF")"
    local apt_dump
    apt_dump=$(apt-config dump)
    grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<<"$apt_dump" \
        && grep -q 'Unattended-Upgrade::Automatic-Reboot "false"' <<<"$apt_dump" \
        || { log_error "MediaStack unattended-upgrades policy is not effective"; return 1; }

    log_ok "Automatic security updates configured"
}

# ---------------------------------------------------------------------------
# Sysctl kernel hardening
# ---------------------------------------------------------------------------

setup_sysctl_hardening() {
    local conf="$MEDIASTACK_SYSCTL_CONF"

    if [[ -f "$conf" ]]; then
        if [[ "$(_ms_state_get SYSCTL_FILE_CREATED 2>/dev/null || true)" == "true" ]] \
            && [[ "$(_ms_root_sha256 "$conf")" == "$(_ms_state_get SYSCTL_FILE_SHA256 2>/dev/null || true)" ]]; then
            log_skip "Sysctl hardening already applied"
        else
            log_warn "Existing $conf is not owned by MediaStack; leaving it unchanged"
        fi
        return
    fi

    log_info "Applying kernel hardening (sysctl)..."

    local keys=(
        net.ipv4.tcp_syncookies
        net.ipv4.conf.all.accept_redirects
        net.ipv4.conf.default.accept_redirects
        net.ipv4.conf.all.send_redirects
        net.ipv4.conf.default.send_redirects
        net.ipv4.conf.all.rp_filter
        net.ipv4.conf.default.rp_filter
        net.ipv4.icmp_echo_ignore_broadcasts
        net.ipv4.conf.all.log_martians
        net.ipv4.conf.default.log_martians
    )
    local key state_key
    for key in "${keys[@]}"; do
        state_key="SYSCTL_BEFORE_${key^^}"
        state_key="${state_key//./_}"
        _ms_state_set "$state_key" "$(sudo sysctl -n "$key")"
    done

    _ms_state_set SYSCTL_FILE_CREATED true
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

    _ms_state_set SYSCTL_FILE_SHA256 "$(_ms_root_sha256 "$conf")"
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
        if ! command -v nvidia-ctk &>/dev/null; then
            return  # nvidia-ctk not installed yet — Stage 3 will configure the runtime
        fi
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

# ---------------------------------------------------------------------------
# Pre-install ownership ledger — call once before setup_hardening().
# ---------------------------------------------------------------------------

record_pre_install_state() {
    sudo test -f "$MEDIASTACK_STATE_FILE" && return 0
    if [[ "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        log_error "Completed install has no ownership ledger; refusing to record already-modified host state"
        return 1
    fi

    local defaults="deny allow" incoming outgoing rules_hash tmp
    rules_hash=$(printf '' | _ms_stream_sha256)
    if command -v ufw >/dev/null 2>&1 || [[ -x /usr/sbin/ufw ]]; then
        # Only read live state when UFW is active — inactive UFW has no Default line
        # in `ufw status verbose`, so _ufw_defaults returns empty. Keep the "deny allow"
        # sentinel (nothing to restore on uninstall) when UFW is inactive.
        if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
            defaults=$(_ufw_defaults)
            rules_hash=$(_ufw_rule_hash)
        fi
    fi
    read -r incoming outgoing <<<"$defaults"
    [[ -n "$incoming" && -n "$outgoing" && "$rules_hash" =~ ^[0-9a-f]{64}$ ]] \
        || { log_error "Could not read UFW pre-install state"; return 1; }

    tmp=$(mktemp)
    cat >"$tmp" <<EOF
STATE_FORMAT=1
UFW_RULES_BEFORE_SHA256=$rules_hash
UFW_DEFAULT_INCOMING=$incoming
UFW_DEFAULT_OUTGOING=$outgoing
UFW_DEFAULTS_APPLIED=false
UFW_ENABLED_BY_MEDIASTACK=false
UFW_RULE_COUNT=0
SYSCTL_FILE_CREATED=false
SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false
SAMBA_OWNERSHIP_RECORDED=false
SAMBA_CONFIGURED=false
SAMBA_SETUP_PENDING=false
EOF
    sudo install -d -m 0755 "$MEDIASTACK_STATE_DIR" \
        && sudo install -m 0600 "$tmp" "$MEDIASTACK_STATE_FILE"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

validate_install_state() {
    sudo test -f "$MEDIASTACK_STATE_FILE" \
        && [[ "$(_ms_state_get STATE_FORMAT 2>/dev/null || true)" == "1" ]] \
        && [[ "$(_ms_state_get UFW_RULES_BEFORE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] \
        && [[ -n "$(_ms_state_get UFW_DEFAULT_INCOMING 2>/dev/null || true)" ]] \
        && [[ -n "$(_ms_state_get UFW_DEFAULT_OUTGOING 2>/dev/null || true)" ]] \
        || return 1

    local key value count i
    for key in UFW_DEFAULTS_APPLIED UFW_ENABLED_BY_MEDIASTACK SYSCTL_FILE_CREATED \
        SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK SAMBA_OWNERSHIP_RECORDED SAMBA_CONFIGURED; do
        [[ "$(_ms_state_get "$key" 2>/dev/null || true)" =~ ^(true|false)$ ]] || return 1
    done
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    for ((i = 1; i <= count; i++)); do
        [[ "$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)" == allow\ *MediaStack:* ]] || return 1
    done
    if [[ "$(_ms_state_get SYSCTL_FILE_CREATED)" == "true" ]]; then
        [[ "$(_ms_state_get SYSCTL_FILE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
        for key in TCP_SYNCOOKIES CONF_ALL_ACCEPT_REDIRECTS CONF_DEFAULT_ACCEPT_REDIRECTS \
            CONF_ALL_SEND_REDIRECTS CONF_DEFAULT_SEND_REDIRECTS CONF_ALL_RP_FILTER \
            CONF_DEFAULT_RP_FILTER ICMP_ECHO_IGNORE_BROADCASTS CONF_ALL_LOG_MARTIANS \
            CONF_DEFAULT_LOG_MARTIANS; do
            _ms_state_get "SYSCTL_BEFORE_NET_IPV4_$key" >/dev/null 2>&1 || return 1
        done
    fi
    for key in APT_AUTO_SHA256 APT_POLICY_SHA256; do
        value=$(_ms_state_get "$key" 2>/dev/null || true)
        [[ -z "$value" || "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
    done
    if [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED)" == "true" ]]; then
        for key in SAMBA_SERVICE_WAS_ENABLED SAMBA_SERVICE_WAS_ACTIVE SAMBA_USER_PREEXISTED \
            SAMBA_PASSDB_PREEXISTED SAMBA_GROUP_PREEXISTED SAMBA_SETUP_PENDING \
            SAMBA_PASSDB_CREATED_BY_MEDIASTACK SAMBA_GROUP_ADDED_BY_MEDIASTACK; do
            [[ "$(_ms_state_get "$key" 2>/dev/null || true)" =~ ^(true|false)$ ]] || return 1
        done
        [[ -n "$(_ms_state_get SAMBA_USER 2>/dev/null || true)" ]] || return 1
    fi
    if [[ "$(_ms_state_get SAMBA_CONFIGURED)" == "true" ]]; then
        [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || true)" == "true" ]] || return 1
        [[ "$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
        [[ "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
}

# ---------------------------------------------------------------------------
# Public orchestrator — called before the wizard
# ---------------------------------------------------------------------------

setup_hardening() {
    log_info "Applying OS hardening..."
    echo ""

    # Both are user choices (wizard prompts / day-2 toggles). Absent flag =>
    # true so existing installs stay hardened after upgrade. verify_gpu_runtime
    # is intentionally NOT here — it is a GPU check, not security hardening, and
    # is called on its own in setup.sh regardless of these toggles.
    if [[ "${UFW_ENABLED:-true}" == "true" ]]; then
        setup_ufw
    else
        log_skip "UFW firewall disabled by user choice"
    fi

    if [[ "${HARDENING_ENABLED:-true}" == "true" ]]; then
        setup_unattended_upgrades
        setup_sysctl_hardening
    else
        log_skip "System hardening (auto-updates + kernel sysctl) disabled by user choice"
    fi

    log_ok "OS hardening step complete"
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
            if [[ "$(_ms_state_get SAMBA_CONFIGURED 2>/dev/null || true)" == "true" ]]; then
                _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
            fi
            log_ok "MediaStack samba config removed (user samba config preserved)"
        fi
        return
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
            if [[ "$(_ms_state_get SAMBA_SETUP_PENDING 2>/dev/null || true)" == "true" ]]; then
                local expected_hash
                expected_hash=$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)
                if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]] \
                    || [[ "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")" != "$expected_hash" ]]; then
                    log_warn "Interrupted Samba setup has an edited or unverifiable include; leaving it unchanged"
                    return 0
                fi
                # Resume below: user/group, service, firewall, and final ledger
                # writes are idempotent and may not have completed before interruption.
            elif [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || true)" == "true" ]]; then
                _ms_state_set SAMBA_INCLUDE_SHA256 "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")"
                _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
                _ms_state_set SAMBA_CONFIGURED true
                log_skip "Samba already configured"
                return 0
            else
                log_skip "Samba already configured"
                return 0
            fi
        else
            log_warn "Samba already configured with a different MediaStack share scope; leaving existing SMB config unchanged."
            return 0
        fi
    fi

    # Same hardcoded-1000 trap as create_data_dirs: when .env hasn't been
    # generated yet, falling back to 1000 picks the wrong group on hosts
    # where the operator isn't uid 1000. Use the operator's actual gid so
    # SMB admin is added to the right group for /data access.
    local pgid="${PGID:-$(id -g)}"

    log_info "Configuring SMB file share..."

    local ownership_recorded passdb_preexisted group_preexisted gid_group
    ownership_recorded=$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || echo false)
    if [[ "$ownership_recorded" == "false" ]]; then
        local samba_was_present=false service_was_enabled=false service_was_active=false user_preexisted=false
        passdb_preexisted=false
        command -v smbd &>/dev/null && samba_was_present=true
        if $samba_was_present; then
            sudo systemctl is-enabled smbd >/dev/null 2>&1 && service_was_enabled=true
            sudo systemctl is-active smbd >/dev/null 2>&1 && service_was_active=true
            sudo pdbedit -L -u "$admin_user" >/dev/null 2>&1 && passdb_preexisted=true
        fi
        id "$admin_user" &>/dev/null && user_preexisted=true
        gid_group=$(getent group "$pgid" | cut -d: -f1)
        group_preexisted=true
        if [[ -n "$gid_group" && "$user_preexisted" == "true" ]]; then
            id -nG "$admin_user" | tr ' ' '\n' | grep -Fxq "$gid_group" || group_preexisted=false
        elif [[ -n "$gid_group" ]]; then
            group_preexisted=false
        fi
        _ms_state_set SAMBA_SERVICE_WAS_ENABLED "$service_was_enabled"
        _ms_state_set SAMBA_SERVICE_WAS_ACTIVE "$service_was_active"
        _ms_state_set SAMBA_USER "$admin_user"
        _ms_state_set SAMBA_USER_PREEXISTED "$user_preexisted"
        _ms_state_set SAMBA_PASSDB_PREEXISTED "$passdb_preexisted"
        _ms_state_set SAMBA_GROUP "$gid_group"
        _ms_state_set SAMBA_GROUP_PREEXISTED "$group_preexisted"
        _ms_state_set SAMBA_SETUP_PENDING true
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK false
        _ms_state_set SAMBA_GROUP_ADDED_BY_MEDIASTACK false
        _ms_state_set SAMBA_OWNERSHIP_RECORDED true
        if ! $samba_was_present; then
            _ms_state_set SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK true
            ui_spin "Installing samba..." sudo apt-get install -y -qq samba
        fi
    else
        if [[ "$(_ms_state_get SAMBA_USER)" != "$admin_user" ]]; then
            log_warn "Samba owner changed after setup; leaving existing Samba configuration unchanged"
            return 0
        fi
        if ! command -v smbd &>/dev/null; then
            if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK)" != "true" ]]; then
                log_warn "Recorded Samba package is missing; leaving state unchanged"
                return 0
            fi
            ui_spin "Retrying Samba installation..." sudo apt-get install -y -qq samba
        fi
        passdb_preexisted=$(_ms_state_get SAMBA_PASSDB_PREEXISTED)
        group_preexisted=$(_ms_state_get SAMBA_GROUP_PREEXISTED)
        gid_group=$(_ms_state_get SAMBA_GROUP)
    fi

    if ! id "$admin_user" &>/dev/null; then
        [[ "$(_ms_state_get SAMBA_USER_PREEXISTED)" == "false" ]] \
            || { log_warn "Pre-existing Samba OS user was removed; leaving state unchanged"; return 0; }
        sudo useradd -M -s /usr/sbin/nologin "$admin_user"
    fi
    if [[ -n "$gid_group" && "$group_preexisted" == "false" ]] \
        && ! id -nG "$admin_user" | tr ' ' '\n' | grep -Fxq "$gid_group"; then
        sudo usermod -aG "$gid_group" "$admin_user"
        _ms_state_set SAMBA_GROUP_ADDED_BY_MEDIASTACK true
    fi
    if [[ "$passdb_preexisted" == "false" ]] \
        && ! sudo pdbedit -L -u "$admin_user" >/dev/null 2>&1; then
        printf '%s\n%s\n' "$admin_pw" "$admin_pw" | sudo smbpasswd -a -s "$admin_user" >/dev/null 2>&1
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK true
    elif [[ "$passdb_preexisted" == "true" ]]; then
        log_warn "Samba user '$admin_user' already exists; preserving its existing password"
    fi

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
    _ms_state_set SAMBA_INCLUDE_SHA256 "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")"

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
    _ms_ufw_allow from 10.0.0.0/8 to any port 445 proto tcp comment MediaStack:SMB-LAN >/dev/null 2>&1
    _ms_ufw_allow from 172.16.0.0/12 to any port 445 proto tcp comment MediaStack:SMB-LAN >/dev/null 2>&1
    _ms_ufw_allow from 192.168.0.0/16 to any port 445 proto tcp comment MediaStack:SMB-LAN >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1

    _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
    _ms_state_set SAMBA_CONFIGURED true
    _ms_state_set SAMBA_SETUP_PENDING false

    log_ok "SMB share configured: \\\\<server-ip>\\${share_name} -> ${share_path}"
}

# ---------------------------------------------------------------------------
# Uninstall: reverse all MediaStack system changes
# ---------------------------------------------------------------------------

_uninstall_ufw() {
    local numbers=() number defaults incoming outgoing before current count i rule args=()
    mapfile -t numbers < <(LC_ALL=C sudo ufw status numbered 2>/dev/null \
        | sed -n '/# MediaStack:/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn)
    for number in "${numbers[@]}"; do
        sudo ufw --force delete "$number" >/dev/null || return 1
    done
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    for ((i = 1; i <= count; i++)); do
        rule=$(_ms_state_get "UFW_RULE_$i") || return 1
        read -r -a args <<<"$rule"
        sudo ufw --force delete "${args[@]}" >/dev/null 2>&1 || true
    done
    LC_ALL=C sudo ufw show added 2>/dev/null | grep -Fq 'MediaStack:' && return 1

    if sudo test -f "$MEDIASTACK_UFW_AFTER_RULES"; then
        sudo sed -i '/^# MEDIASTACK-DOCKER-RULES/,/^# END MEDIASTACK-DOCKER-RULES$/d' "$MEDIASTACK_UFW_AFTER_RULES" || return 1
    fi
    # Reverse the DOCKER-USER dedup hook — but only while our marker is still
    # present, so we never delete or edit a file an admin has since replaced.
    if sudo test -f "$MEDIASTACK_UFW_AFTER_INIT" \
        && sudo grep -q 'MEDIASTACK-DOCKER-DEDUP' "$MEDIASTACK_UFW_AFTER_INIT"; then
        if [[ "$(_ms_state_get UFW_AFTER_INIT_CREATED 2>/dev/null || true)" == "true" ]]; then
            # We wrote the whole file; drop it.
            sudo rm -f "$MEDIASTACK_UFW_AFTER_INIT" || return 1
        else
            # Injected into a pre-existing file; strip our block, restore mode.
            sudo sed -i '/^# >>> MEDIASTACK-DOCKER-DEDUP/,/^# <<< MEDIASTACK-DOCKER-DEDUP$/d' "$MEDIASTACK_UFW_AFTER_INIT" || return 1
            if [[ "$(_ms_state_get UFW_AFTER_INIT_ACTIVATED 2>/dev/null || true)" == "true" ]]; then
                sudo chmod 640 "$MEDIASTACK_UFW_AFTER_INIT" || return 1
            fi
        fi
    fi
    sudo ufw reload >/dev/null 2>&1 || return 1
    while sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1; do
        sudo iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || return 1
    done
    if sudo iptables -L MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1; then
        sudo iptables -F MEDIASTACK-DOCKER-RESTRICT \
            && sudo iptables -X MEDIASTACK-DOCKER-RESTRICT || return 1
    fi
    sudo grep -q '^# MEDIASTACK-DOCKER-RULES' "$MEDIASTACK_UFW_AFTER_RULES" 2>/dev/null && return 1
    sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1 && return 1

    defaults=$(_ufw_defaults)
    read -r incoming outgoing <<<"$defaults"
    if [[ "$(_ms_state_get UFW_DEFAULTS_APPLIED)" == "true" ]]; then
        if [[ "$incoming" == "deny" ]]; then
            sudo ufw default "$(_ms_state_get UFW_DEFAULT_INCOMING)" incoming >/dev/null || return 1
        else
            log_warn "UFW incoming default changed after install; preserving '$incoming'"
        fi
        if [[ "$outgoing" == "allow" ]]; then
            sudo ufw default "$(_ms_state_get UFW_DEFAULT_OUTGOING)" outgoing >/dev/null || return 1
        else
            log_warn "UFW outgoing default changed after install; preserving '$outgoing'"
        fi
    fi

    before=$(_ms_state_get UFW_RULES_BEFORE_SHA256)
    current=$(_ufw_rule_hash)
    if [[ "$(_ms_state_get UFW_ENABLED_BY_MEDIASTACK)" == "true" ]] \
        && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        defaults=$(_ufw_defaults)
        if [[ "$current" == "$before" \
            && "$defaults" == "$(_ms_state_get UFW_DEFAULT_INCOMING) $(_ms_state_get UFW_DEFAULT_OUTGOING)" ]]; then
            sudo ufw --force disable >/dev/null || return 1
        else
            log_warn "UFW gained user changes after install; leaving it active"
        fi
    fi

    # SSH lockout guard: we just deleted MediaStack's SSH allow rules. If UFW is
    # still active and enforcing default-deny (we did NOT disable it — the user
    # added their own rules, or the firewall pre-dates MediaStack), a remote
    # admin could lose SSH. Re-assert an allow for the current SSH session's
    # source and for the detected SSH port(s) from the private LAN ranges. These
    # are left UNTAGGED on purpose so a future uninstall/toggle never strips them
    # (which would re-introduce the lockout) — they become the user's own rules.
    if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        local ssh_incoming ssh_port ssh_cidr ssh_client ssh_sport ssh_kept=false
        read -r ssh_incoming _ < <(_ufw_defaults)
        if [[ "$ssh_incoming" == "deny" ]]; then
            if [[ -n "${SSH_CONNECTION:-}" ]]; then
                read -r ssh_client _ _ ssh_sport _ <<<"$SSH_CONNECTION"
                # Accept IPv6 sessions too (ufw_valid_ip_literal, matching the
                # install path's detect_active_ssh_client). Restricting to
                # ufw_valid_ipv4 here would skip the session allow for a remote
                # admin on an IPv6-only SSH connection and lock them out.
                if ufw_valid_ip_literal "$ssh_client" && ufw_valid_port "$ssh_sport"; then
                    sudo ufw allow from "$ssh_client" to any port "$ssh_sport" proto tcp >/dev/null 2>&1 \
                        && ssh_kept=true
                fi
            fi
            while read -r ssh_port; do
                [[ -n "$ssh_port" ]] || continue
                for ssh_cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
                    sudo ufw allow from "$ssh_cidr" to any port "$ssh_port" proto tcp >/dev/null 2>&1 \
                        && ssh_kept=true
                done
            done < <(detect_ssh_server_ports)
            [[ "$ssh_kept" == "true" ]] \
                && log_warn "UFW left active (default-deny); preserved SSH access (LAN + current session) so you are not locked out"
        fi
    fi
    log_ok "MediaStack UFW rules removed; unrelated rules preserved"
}

_uninstall_apt() {
    local path key expected
    for path in "$MEDIASTACK_APT_AUTO_CONF" "$MEDIASTACK_APT_POLICY_CONF"; do
        [[ "$path" == "$MEDIASTACK_APT_AUTO_CONF" ]] && key=APT_AUTO_SHA256 || key=APT_POLICY_SHA256
        sudo test -e "$path" || continue
        expected=$(_ms_state_get "$key") || return 1
        if [[ "$(_ms_root_sha256 "$path")" != "$expected" ]]; then
            log_error "Edited MediaStack APT file preserved: $path"
            return 1
        fi
        sudo rm -f "$path" || return 1
    done
    sudo rm -f \
        /etc/apt/sources.list.d/mediastack-nonfree.list \
        /etc/apt/sources.list.d/mediastack-backports.list \
        || true
    log_ok "MediaStack apt sources and unattended-upgrades policy removed"
}

_uninstall_sysctl() {
    [[ "$(_ms_state_get SYSCTL_FILE_CREATED)" == "true" ]] || return 0
    local conf="$MEDIASTACK_SYSCTL_CONF"
    sudo test -e "$conf" || return 0
    if [[ "$(_ms_root_sha256 "$conf")" != "$(_ms_state_get SYSCTL_FILE_SHA256)" ]]; then
        log_error "Edited MediaStack sysctl file preserved: $conf"
        return 1
    fi

    local keys=(
        net.ipv4.tcp_syncookies:1
        net.ipv4.conf.all.accept_redirects:0
        net.ipv4.conf.default.accept_redirects:0
        net.ipv4.conf.all.send_redirects:0
        net.ipv4.conf.default.send_redirects:0
        net.ipv4.conf.all.rp_filter:1
        net.ipv4.conf.default.rp_filter:1
        net.ipv4.icmp_echo_ignore_broadcasts:1
        net.ipv4.conf.all.log_martians:1
        net.ipv4.conf.default.log_martians:1
    ) item key applied state_key current
    for item in "${keys[@]}"; do
        key="${item%%:*}"; applied="${item#*:}"
        state_key="SYSCTL_BEFORE_${key^^}"; state_key="${state_key//./_}"
        local before; before=$(_ms_state_get "$state_key" 2>/dev/null || true)
        current=$(sysctl -n "$key" 2>/dev/null)   # reading sysctl needs no root
        if [[ "$current" == "$applied" ]]; then
            if [[ -n "$before" ]]; then
                sudo sysctl -w "$key=$before" >/dev/null || return 1
            fi
            # Empty before = key was at kernel default; conf removal below reverts on reboot
        else
            log_warn "sysctl $key changed after install; preserving '$current'"
        fi
    done
    sudo rm -f "$conf" || return 1
    log_ok "MediaStack kernel hardening removed"
}

_uninstall_samba() {
    [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED)" == "true" ]] || return 0
    if [[ "$(_ms_state_get SAMBA_SETUP_PENDING)" == "true" ]]; then
        log_error "Samba setup is incomplete; rerun setup to finish it before uninstalling"
        return 1
    fi
    local expected current adopted=false user group
    expected=$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)
    if sudo test -e "$SAMBA_INCLUDE_FILE"; then
        if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]] \
            || [[ "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")" != "$expected" ]]; then
            log_error "Edited or unverifiable MediaStack Samba include preserved: $SAMBA_INCLUDE_FILE"
            return 1
        fi
    fi
    current=$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)
    [[ "$current" == "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" ]] || adopted=true

    sudo rm -f "$SAMBA_INCLUDE_FILE" || return 1
    if sudo test -e "$SAMBA_MAIN_CONF"; then
        sudo sed -i '/^# MEDIASTACK include - managed by setup\.sh$/d' "$SAMBA_MAIN_CONF" \
            && sudo sed -i '\#^include = /etc/samba/smb\.conf\.d/mediastack\.conf$#d' "$SAMBA_MAIN_CONF" || return 1
    fi
    user=$(_ms_state_get SAMBA_USER)
    if [[ "$(_ms_state_get SAMBA_PASSDB_CREATED_BY_MEDIASTACK)" == "true" ]] \
        && sudo pdbedit -L -u "$user" >/dev/null 2>&1; then
        sudo smbpasswd -x "$user" >/dev/null 2>&1 || return 1
    fi
    group=$(_ms_state_get SAMBA_GROUP)
    if [[ -n "$group" && "$(_ms_state_get SAMBA_GROUP_ADDED_BY_MEDIASTACK)" == "true" ]] \
        && id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group"; then
        sudo gpasswd -d "$user" "$group" >/dev/null 2>&1 || return 1
    fi

    if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK)" == "true" ]] \
        && command -v smbd >/dev/null 2>&1; then
        if $adopted; then
            log_warn "Samba has non-MediaStack configuration; preserving the package"
        else
            sudo apt-get remove -y -qq samba >/dev/null 2>&1 || return 1
        fi
    else
        if [[ "$(_ms_state_get SAMBA_SERVICE_WAS_ENABLED)" == "false" ]] \
            && sudo systemctl is-enabled smbd >/dev/null 2>&1; then
            sudo systemctl disable smbd >/dev/null 2>&1 || return 1
        fi
        if [[ "$(_ms_state_get SAMBA_SERVICE_WAS_ACTIVE)" == "false" ]] \
            && sudo systemctl is-active smbd >/dev/null 2>&1; then
            sudo systemctl stop smbd >/dev/null 2>&1 || return 1
        else
            sudo systemctl reload smbd >/dev/null 2>&1 || true
        fi
    fi
    log_ok "MediaStack Samba configuration removed; Linux account preserved"
}

uninstall_system_cleanup() {
    validate_install_state || { log_error "Missing or invalid MediaStack ownership ledger; refusing host cleanup"; return 1; }
    local failed=0 svc
    _uninstall_ufw || { log_error "UFW cleanup failed"; failed=1; }
    _uninstall_apt || { log_error "APT cleanup failed"; failed=1; }
    _uninstall_sysctl || { log_error "sysctl cleanup failed"; failed=1; }
    _uninstall_samba || { log_error "Samba cleanup failed"; failed=1; }

    for svc in mediastack-storage-watchdog mediastack-setup; do
        if sudo test -f "/etc/systemd/system/${svc}.service"; then
            sudo systemctl stop "${svc}.service" 2>/dev/null || failed=1
            sudo systemctl disable "${svc}.service" 2>/dev/null || failed=1
            sudo rm -f "/etc/systemd/system/${svc}.service" || failed=1
        fi
    done
    sudo rm -f /etc/sudoers.d/mediastack-storage-watchdog || failed=1
    sudo rm -rf /usr/local/libexec/mediastack || failed=1
    sudo rm -f /etc/profile.d/mediastack-setup-result.sh || failed=1
    sudo systemctl daemon-reload 2>/dev/null || failed=1

    (( failed == 0 )) || { log_error "Host cleanup incomplete; ownership ledger retained for retry"; return 1; }
    log_ok "MediaStack system artefacts removed"
}

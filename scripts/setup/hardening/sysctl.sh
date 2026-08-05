# Owns: setup_* uninstall_* — kernel sysctl hardening configuration and owned-value teardown.
# Sources: hardening.sh ledger paths and common.sh state/hash helpers.
# Globals: MEDIASTACK_SYSCTL_CONF.

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
        key="${item%%:*}"
        applied="${item#*:}"
        state_key="SYSCTL_BEFORE_${key^^}"
        state_key="${state_key//./_}"
        local before
        before=$(_ms_state_get "$state_key" 2>/dev/null || true)
        current=$(sysctl -n "$key" 2>/dev/null) # reading sysctl needs no root
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

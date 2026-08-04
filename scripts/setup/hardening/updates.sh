# Owns: MediaStack's unattended security-upgrade files and their teardown.
# Sources: hardening.sh ledger paths and common.sh state/hash helpers.
# Globals: MEDIASTACK_APT_AUTO_CONF and MEDIASTACK_APT_POLICY_CONF.

setup_unattended_upgrades() {
    if ! command -v unattended-upgrade &>/dev/null; then
        ui_spin "Installing unattended-upgrades..." sudo apt-get install -y -qq unattended-upgrades
    fi

    if sudo test -e "$MEDIASTACK_APT_AUTO_CONF" \
        || sudo test -e "$MEDIASTACK_APT_POLICY_CONF"; then
        if sudo test -f "$MEDIASTACK_APT_AUTO_CONF" \
            && sudo test -f "$MEDIASTACK_APT_POLICY_CONF" \
            && [[ "$(_ms_root_sha256 "$MEDIASTACK_APT_AUTO_CONF")" == "$(_ms_state_get APT_AUTO_SHA256 2>/dev/null || true)" &&
            "$(_ms_root_sha256 "$MEDIASTACK_APT_POLICY_CONF")" == "$(_ms_state_get APT_POLICY_SHA256 2>/dev/null || true)" ]]; then
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
        || {
            log_error "MediaStack unattended-upgrades policy is not effective"
            return 1
        }

    log_ok "Automatic security updates configured"
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
    gpu_uninstall # apt sources owned by gpu.sh; removed by their owner
    log_ok "MediaStack apt sources and unattended-upgrades policy removed"
}

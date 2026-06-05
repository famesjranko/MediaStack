# =============================================================================
# MediaStack Setup — Base package and Docker installation
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

install_base_packages() {
    log_info "Installing base packages..."
    sudo apt-get update -qq
    # Self-heal an inconsistent dpkg/apt state before installing. An interrupted install or a
    # driver-mode switch (e.g. Standard<->Unlock leaving the old driver stack half-removed) can
    # leave packages half-configured, which makes the install below fail with "Unmet
    # dependencies" and no path forward for a non-technical user. Harmless no-op when healthy.
    if ! sudo apt-get check >/dev/null 2>&1; then
        log_warn "Inconsistent package state detected - repairing (dpkg --configure -a + apt --fix-broken)..."
        sudo dpkg --configure -a >/dev/null 2>&1 || true
        sudo apt-get install -f -y -qq >/dev/null 2>&1 || true
    fi
    # Note: samba is intentionally NOT installed here. setup_samba() in
    # hardening.sh installs it on-demand only when SMB_ENABLED=true, so
    # the wizard's port-445 conflict check stays meaningful (otherwise
    # we'd install samba up-front, smbd would auto-bind 445, and the
    # check would always flag a conflict — by a daemon we just installed).
    sudo apt-get install -y -qq curl ca-certificates gnupg lsb-release sudo pciutils python3-yaml python3-bcrypt gettext-base ufw unattended-upgrades git htop bind9-dnsutils smartmontools >/dev/null
    log_ok "Base packages installed"

    if ! command -v speedtest-cli &>/dev/null; then
        sudo apt-get install -y -qq speedtest-cli >/dev/null 2>&1 \
            || pip3 install speedtest-cli >/dev/null 2>&1 \
            || log_warn "Could not install speedtest-cli - speed test will be unavailable"
    fi
}

configure_docker_apt_repo() {
    # Add Docker's official GPG key and apt repository. Kept idempotent so
    # --full can also repair hosts with Docker Engine but no Compose plugin.
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
}

refresh_docker_group_membership() {
    if getent group docker >/dev/null 2>&1; then
        sudo usermod -aG docker "$USER"
    fi

    # Apply group membership immediately for this script session
    if getent group docker >/dev/null 2>&1 && ! groups | grep -qw docker; then
        log_warn "Docker group membership requires new session. Re-running with newgrp..."
        exec sg docker -c "$0"
    fi
}

install_docker() {
    local docker_present=false
    local compose_present=false

    if command -v docker &>/dev/null; then
        docker_present=true
    fi
    if $docker_present && docker compose version &>/dev/null; then
        compose_present=true
    fi

    if $docker_present && $compose_present; then
        log_ok "Docker and Docker Compose already installed, skipping"
        return
    fi

    if $docker_present; then
        log_warn "Docker is installed but Docker Compose v2 is missing. Installing Compose plugin..."
    else
        log_info "Installing Docker..."
    fi

    configure_docker_apt_repo
    sudo apt-get update -qq

    if $docker_present; then
        sudo apt-get install -y -qq docker-compose-plugin >/dev/null
        log_ok "Docker Compose plugin installed"
    else
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
        log_ok "Docker installed"
    fi

    # Add current user to docker group
    refresh_docker_group_membership
}

# =============================================================================
# MediaStack Setup — Base package and Docker installation
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

# shellcheck source=../lib/apt.sh
declare -p MS_APT_INSTALL >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/apt.sh"

install_base_packages() {
    ui_spin "Updating package lists..." sudo apt-get update -qq
    # Self-heal an inconsistent dpkg/apt state before installing. An interrupted install or a
    # driver-mode switch (e.g. Standard<->Unlock leaving the old driver stack half-removed) can
    # leave packages half-configured, which makes the install below fail with "Unmet
    # dependencies" and no path forward for a non-technical user. Harmless no-op when healthy.
    if ! sudo apt-get check >/dev/null 2>&1; then
        log_warn "Inconsistent package state detected - repairing (dpkg --configure -a + apt --fix-broken)..."
        sudo dpkg --configure -a >/dev/null 2>&1 || true
        "${MS_APT_INSTALL[@]}" -f >/dev/null 2>&1 || true
    fi
    # Note: samba and unattended-upgrades are intentionally NOT installed here.
    # setup_samba() installs samba on-demand only when SMB_ENABLED=true (so the
    # wizard's port-445 conflict check stays meaningful). setup_unattended_upgrades()
    # installs unattended-upgrades on-demand only when HARDENING_ENABLED=true —
    # installing it up-front would let Debian's postinst enable /etc/apt/apt.conf.d/
    # 20auto-upgrades, running generic auto security-updates even when the user
    # declined hardening (an incomplete opt-out).
    ui_spin "Installing base packages..." "${MS_APT_INSTALL[@]}" \
        curl ca-certificates gnupg lsb-release sudo pciutils python3-yaml python3-bcrypt \
        gettext-base ufw git htop bind9-dnsutils smartmontools mokutil inotify-tools
    log_ok "Base packages installed"

    # Optional fallback speed-test tool. The wizard's primary method is a
    # curl+Cloudflare measurement (needs no package); librespeed-cli is used
    # only if the curl method fails. (The old Ookla speedtest-cli was dropped:
    # Ookla now HTTP-403s that deprecated client.)
    if ! command -v librespeed-cli &>/dev/null; then
        "${MS_APT_INSTALL[@]}" librespeed-cli >/dev/null 2>&1 \
            || log_warn "Could not install librespeed-cli - speed test will use the built-in curl method only"
    fi
}

# Paths are variables so unit tests can point them at a fake root.
# shellcheck disable=SC2034 # consumed by the functions below and by hardening.sh callers
MEDIASTACK_DOCKER_APT_LIST=/etc/apt/sources.list.d/docker.list
MEDIASTACK_DOCKER_APT_KEY=/etc/apt/keyrings/docker.gpg
MEDIASTACK_OS_RELEASE=/etc/os-release
MEDIASTACK_APT_SOURCES_LIST=/etc/apt/sources.list
MEDIASTACK_APT_SOURCES_DIR=/etc/apt/sources.list.d
# The signed-by path inside the written line is always this literal: it is part
# of what identifies a source as MediaStack's, wherever the key file really sits.
_DOCKER_APT_KEY_LITERAL=/etc/apt/keyrings/docker.gpg

# One line MediaStack writes, for key path $1. Fields: arch, codename.
_docker_apt_line() {
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' \
        "$(dpkg --print-architecture)" "$1" "$2"
}

# Prints "<distro> <codename>" and returns 0 when file $1 is byte-identical to a
# line MediaStack writes for some distro and codename. The old writer left a run of
# spaces before the codename, so any run of spaces is accepted there.
_docker_apt_list_owned() {
    local content re
    re='^deb \[arch=[a-z0-9]+ signed-by=/etc/apt/keyrings/docker\.gpg\] https://download\.docker\.com/linux/(debian|ubuntu) +([a-z0-9._-]+) stable'$'\n''$'
    content=$(
        sudo cat "$1" 2>/dev/null
        echo x
    ) || return 1
    content=${content%x}
    [[ "$content" =~ $re ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Prints the first apt source file, other than MediaStack's own list, that names
# download.docker.com: one-line .list files, deb822 .sources files, and the main
# sources.list. Docker's documented install writes docker.sources, and apt fails
# host-wide with "Conflicting values set for option Signed-By" when a second
# source for the same repo carries a different key.
_docker_apt_foreign_source() {
    local f
    for f in "$MEDIASTACK_APT_SOURCES_LIST" "$MEDIASTACK_APT_SOURCES_DIR"/*.list "$MEDIASTACK_APT_SOURCES_DIR"/*.sources; do
        [[ "$f" != "$MEDIASTACK_DOCKER_APT_LIST" ]] && sudo test -f "$f" || continue
        if sudo grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -q 'download\.docker\.com'; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

_docker_apt_tmp_release() {
    rm -rf "$_DOCKER_APT_TMP"
    trap - INT TERM
    eval "$_DOCKER_APT_PREV_TRAPS"
}

# Transactional: the key and source are proven in a temp dir with an isolated
# apt-get update before anything under /etc/apt changes. Idempotent, so --full can
# also repair hosts with Docker Engine but no Compose plugin. A source MediaStack
# did not write is left alone with a warning (never auto-reconcile), and any other
# apt source for download.docker.com is used as is after a normal apt-get update.
configure_docker_apt_repo() {
    local list="$MEDIASTACK_DOCKER_APT_LIST" key="$MEDIASTACK_DOCKER_APT_KEY"
    local codename want tmp out foreign key_pre=false list_pre=false

    codename=$(. "$MEDIASTACK_OS_RELEASE" && echo "${VERSION_CODENAME:-}")
    if [[ -z "$codename" ]]; then
        log_error "Cannot read VERSION_CODENAME from $MEDIASTACK_OS_RELEASE; Docker apt source not added"
        return 1
    fi
    want=$(_docker_apt_line "$_DOCKER_APT_KEY_LITERAL" "$codename")

    if foreign=$(_docker_apt_foreign_source); then
        log_info "Docker apt source already present in $foreign; using it"
        out=$(sudo apt-get update 2>&1)
        if (($? != 0)) || grep -q '^\(Err:\|E:\)' <<<"$out"; then
            log_error "apt-get update fails with the existing Docker source in $foreign; fix apt, then re-run"
            log_info "$(tail -n 3 <<<"$out")"
            return 1
        fi
        return 0
    fi

    if sudo test -e "$list"; then
        list_pre=true
        if ! _docker_apt_list_owned "$list" >/dev/null; then
            log_warn "$list was not written by MediaStack; leaving it unchanged"
            return 0
        fi
        if [[ "$(sudo cat "$list")" == "${want%$'\n'}" ]] && sudo test -s "$key"; then
            return 0
        fi
    fi
    sudo test -e "$key" && key_pre=true

    tmp=$(mktemp -d) || return 1
    chmod 0755 "$tmp" # apt's unprivileged fetcher must reach the temp key
    _DOCKER_APT_TMP=$tmp
    _DOCKER_APT_PREV_TRAPS=$(trap -p INT TERM)
    trap '_docker_apt_tmp_release; kill -s INT "$BASHPID"' INT
    trap '_docker_apt_tmp_release; kill -s TERM "$BASHPID"' TERM

    if ! curl -fsSL -o "$tmp/key.asc" https://download.docker.com/linux/debian/gpg \
        || ! gpg --dearmor --yes -o "$tmp/docker.gpg" "$tmp/key.asc" \
        || [[ ! -s "$tmp/docker.gpg" ]] \
        || ! gpg --show-keys --with-colons "$tmp/docker.gpg" 2>/dev/null | grep -q '^pub:'; then
        log_error "Could not fetch a valid Docker signing key; no Docker apt source was added"
        _docker_apt_tmp_release
        return 1
    fi
    chmod 0644 "$tmp/docker.gpg"
    _docker_apt_line "$tmp/docker.gpg" "$codename" >"$tmp/docker.list"

    out=$(sudo apt-get update -o Dir::Etc::sourcelist="$tmp/docker.list" \
        -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0 2>&1)
    if (($? != 0)) || grep -q '^\(Err:\|E:\)' <<<"$out"; then
        log_error "Docker apt source failed verification for '$codename' (is this a supported Debian release?); nothing was changed"
        log_info "$(tail -n 3 <<<"$out")"
        _docker_apt_tmp_release
        return 1
    fi
    _docker_apt_line "$_DOCKER_APT_KEY_LITERAL" "$codename" >"$tmp/docker.list"

    if ! { sudo install -m 0755 -d "$(dirname "$key")" \
        && sudo install -m 0644 "$tmp/docker.gpg" "$key.new" \
        && sudo install -m 0644 "$tmp/docker.list" "$list.new" \
        && sudo mv -f "$key.new" "$key" \
        && sudo mv -f "$list.new" "$list"; }; then
        log_error "Could not install the Docker apt source; undoing this run's changes"
        sudo rm -f "$key.new" "$list.new"
        $key_pre || sudo rm -f "$key"
        $list_pre || sudo rm -f "$list"
        _docker_apt_tmp_release
        return 1
    fi
    _docker_apt_tmp_release
}

# Debian release codenames (https://www.debian.org/releases/). Docker's
# download.docker.com/linux/debian/dists carries only these. Ubuntu codenames
# never collide with them, so membership tells which distro a codename belongs to.
_DEBIAN_CODENAMES=" wheezy jessie stretch buster bullseye bookworm trixie forky duke sid "

# Contract: removes a MediaStack-written Docker apt source (and its key) only when
# it provably cannot work: the repo's codename is not a release of the repo's own
# distro (the old writer put the Ubuntu codename "noble" under linux/debian). The
# host's /etc/os-release is not the judge: Docker's documented one-line install
# writes the same bytes, and derivatives (Mint, Raspbian) or an older codename on
# a newer host work fine. Such a source is kept and the keep is logged, because
# Docker Engine stays installed after uninstall and the source keeps it patched.
# A source MediaStack did not write is warned about and left alone. A 0-byte key
# with no source is a failed-download leftover and goes. Called from
# _uninstall_host_artefacts and by the OS preflight on its refused-OS path, so
# re-running ./mediastack repairs a host the old code broke. Returns non-zero only
# when a removal fails.
remove_broken_docker_apt_source() {
    local list="$MEDIASTACK_DOCKER_APT_LIST" key="$MEDIASTACK_DOCKER_APT_KEY"
    local owned repo_distro repo_codename is_debian=false

    if ! sudo test -e "$list"; then
        if sudo test -e "$key" && ! sudo test -s "$key"; then
            sudo rm -f "$key" || return 1
            log_info "Removed empty Docker apt key left by a failed download"
        fi
        return 0
    fi
    if ! owned=$(_docker_apt_list_owned "$list"); then
        log_warn "$list was not written by MediaStack; leaving it in place"
        return 0
    fi
    read -r repo_distro repo_codename <<<"$owned"
    [[ "$_DEBIAN_CODENAMES" == *" $repo_codename "* ]] && is_debian=true
    if [[ "$repo_distro" == debian && "$is_debian" == true ]] \
        || [[ "$repo_distro" == ubuntu && "$is_debian" == false ]]; then
        log_info "Docker apt source kept: $repo_distro $repo_codename is a valid release of that repo and keeps the installed Docker Engine patched"
        return 0
    fi
    sudo rm -f "$list" "$key" || return 1
    log_ok "Removed Docker apt source for $repo_distro $repo_codename: $repo_codename is not a release of that repo"
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

    # configure_docker_apt_repo runs backgrounded under ui_spin and calls sudo
    # internally, so ui_spin's direct-`sudo` prime can't reach it — warm the
    # credential cache in the foreground here (see scripts/lib/ui.sh).
    sudo -v 2>/dev/null || true
    ui_spin "Adding Docker apt repository..." configure_docker_apt_repo || return 1
    ui_spin "Updating package lists..." sudo apt-get update -qq

    if $docker_present; then
        ui_spin "Installing Docker Compose plugin..." \
            "${MS_APT_INSTALL[@]}" docker-compose-plugin
        log_ok "Docker Compose plugin installed"
    else
        ui_spin "Installing Docker..." \
            "${MS_APT_INSTALL[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        log_ok "Docker installed"
    fi

    # Add current user to docker group
    refresh_docker_group_membership
}

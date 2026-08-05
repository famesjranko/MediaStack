#!/usr/bin/env bash
# Owns: Launcher banner-adjacent diagnostics, readiness, health, and port checks.
# Sources: launcher globals, .env, scripts/lib/ui.sh, network.sh, checks.sh, gpu.sh, and fail2ban helpers.

_compose_running_summary() {
    # Echoes "running/total" on success. Returns 1 when no containers exist for
    # this compose project. Counts include all .env-declared profiles, not just
    # default — otherwise npm/bazarr/wireguard/autoheal would be invisible.
    local profiles=()
    _build_profile_args profiles
    local total running
    total=$(docker compose "${profiles[@]}" ps --format '{{.Name}}' 2>/dev/null | wc -l)
    running=$(docker compose "${profiles[@]}" ps --filter 'status=running' --format '{{.Name}}' 2>/dev/null | wc -l)
    if [[ -z "$total" || "$total" == "0" ]]; then
        return 1
    fi
    printf '%s/%s' "$running" "$total"
}

diag_readiness() {
    source "$SCRIPT_DIR/scripts/setup/checks.sh"
    source "$SCRIPT_DIR/scripts/setup/gpu.sh"

    echo ""
    ui_log info "Running read-only readiness checks (this prompts no questions)..."
    echo ""

    # Each check exits 1 on hard failure; subshell isolates that exit.
    (check_disk_floor) || true
    (check_internet_reachability) || true
    (check_ram_warn) || true

    # GPU detection sets a global; we want the user to see what was detected
    # but don't need to keep the value (post-install reads from .env instead).
    (detect_gpu) || true

    # Sudo: don't prompt — just probe. prompt_sudo_cache would block on a
    # password input which is wrong for a readiness check.
    if command -v sudo &>/dev/null; then
        if sudo -n true 2>/dev/null; then
            log_ok "Sudo: passwordless OK"
        else
            log_warn "Sudo: requires password (install will prompt once)"
        fi
    else
        log_error "Sudo: not installed (apt-get install sudo)"
    fi

    # Docker: read-only probe.
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
    else
        log_warn "Docker: not installed (will be installed on first install run)"
    fi

    # GUM: optional binary that unlocks arrow-key menus (ui-render-gum.sh backend).
    if command -v gum &>/dev/null; then
        log_ok "GUM (optional): $(gum --version 2>/dev/null || echo installed) — arrow-key menus active"
    else
        log_info "GUM (optional): not installed — select 'Get enhanced menus' from the main menu to install"
    fi

    # Secure Boot: relevant for NVIDIA driver installs (unsigned module won't load).
    if ! command -v mokutil &>/dev/null; then
        log_warn "mokutil not installed — Secure Boot state unknown (install mokutil to verify before adding NVIDIA drivers)"
    elif mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        log_warn "Secure Boot is ENABLED — NVIDIA kernel module will not load; disable it in UEFI firmware before adding GPU support"
    else
        log_ok "Secure Boot: disabled"
    fi
}

diag_dns_check() {
    echo ""
    # bind9-dnsutils (dig) is installed by setup.sh's install_base_packages,
    # so post-install this is always present. Pre-install on a bare Debian, dig
    # may be absent — and net_dns_classify silently returns "no-a" when dig
    # is missing, which the user reads as "your A-records are wrong" instead of
    # "tool missing". Fail fast with an actionable apt hint.
    if ! command -v dig &>/dev/null; then
        ui_log error "dig is not installed (bind9-dnsutils package)."
        ui_log info "Install it with:  sudo apt-get install -y bind9-dnsutils"
        ui_log info "Or run option 1 (Install MediaStack) - setup.sh installs it automatically."
        return 0
    fi

    # When DDNS is configured, this IS the DDNS status check: show the provider and
    # the container's live health up front, then the A-record-vs-WAN comparison below
    # tells you whether the record is confirmed at your current IP.
    if _ddns_configured; then
        local _dh
        _dh=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' ddns-updater 2>/dev/null || echo "unknown")
        ui_log info "DDNS provider: ${DDNS_PROVIDER:-unknown} — updater container: ${_dh}"
    fi

    local default_domain="${DOMAIN:-}"
    [[ "$default_domain" == "example.com" ]] && default_domain=""

    local domain
    domain=$(ui_input "Domain to check (e.g. example.com)" "$default_domain")
    if [[ -z "$domain" ]]; then
        ui_log warn "No domain provided - nothing to check."
        return 0
    fi

    echo ""
    ui_log info "Detecting public IP..."
    local public_ip=""
    if net_detect_public_ip; then
        public_ip="$_NET_PUBLIC_IP"
        ui_kv "Public IP" "$public_ip"
        # Sync the launcher's banner cache so a previously-failed detection
        # doesn't leave stale "not detected" in the banner.
        _MS_PUBLIC_IP="$public_ip"
        _MS_PUBLIC_IP_CHECKED=1
    else
        ui_log error "Could not detect public IP - DNS comparison cannot run."
        return 0
    fi

    echo ""
    ui_log info "Checking jellyfin.${domain} and seerr.${domain} A-records (via 8.8.8.8)..."
    local result
    result=$(net_dns_classify "$domain" "$public_ip")
    local rc=$?

    case "$result" in
        ok)
            ui_log ok "DNS looks good - both subdomains resolve to your public IP."
            ;;
        no-a)
            ui_log error "Missing A-records: set jellyfin.${domain} and seerr.${domain} to ${public_ip} at your DNS provider."
            ;;
        apex-only)
            ui_log warn "Only the apex (${domain}) has an A-record. Add subdomain A-records for jellyfin.* and seerr.*"
            ;;
        cloudflare)
            ui_log warn "DNS points to Cloudflare. MediaStack expects the A-record to point directly at your home IP (${public_ip}). Disable Cloudflare proxying (grey cloud)."
            ;;
        mismatch:*)
            local got="${result#mismatch:}"
            ui_log error "DNS mismatch - subdomain resolves to ${got}, but your public IP is ${public_ip}. Update the A-record (or wait for DDNS propagation)."
            ;;
        *)
            ui_log warn "DNS classification: ${result} (rc=${rc})"
            ;;
    esac
}

diag_speedtest() {
    echo ""
    if ui_spin_fg "Measuring your connection speed (~15s)..." net_run_speedtest; then
        ui_log ok "Download: ${_NET_DL_MBPS} Mbps | Upload: ${_NET_UL_MBPS} Mbps"
    else
        ui_log warn "Speed test unavailable (no internet, or both curl and librespeed-cli failed)."
    fi
}

diag_test_port() {
    echo ""
    local port
    port=$(ui_input "TCP port to test (1-65535)" "")
    if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        ui_log error "Invalid port: '${port}' - enter a number from 1 to 65535."
        return 0
    fi
    if ! net_detect_public_ip 2>/dev/null; then
        ui_log warn "Could not detect public IP - cannot run an external probe."
        return 0
    fi
    local pip="$_NET_PUBLIC_IP"
    echo ""
    ui_log info "Probing TCP ${port} on ${pip} (sudo may prompt to bind privileged ports)..."
    case $(
        net_check_tcp_port_external "$port"
        echo "rc:$?"
    ) in
        rc:0) ui_log ok "TCP ${port} - reachable, lands on this host" ;;
        rc:1) ui_log error "TCP ${port} - no response (closed / not forwarded)" ;;
        rc:3) ui_log error "TCP ${port} - forwarded to another device" ;;
        rc:4) ui_log warn "TCP ${port} - a service is already bound (partial check)" ;;
        *) ui_log warn "TCP ${port} - probe unavailable (couldn't bind or external service down)" ;;
    esac
}

action_port_check() {
    # port-check.sh prints its own self-contained verdict (pass/skip/fail counts,
    # hairpin caveat, and the required-forwards box), so don't tack on the generic
    # "completed successfully" line — it contradicts a "3 of 4 checks failed"
    # result. Matches the other diagnostics, which pause straight to the menu.
    "$SCRIPT_DIR/scripts/port-check.sh" || true
    pause_for_menu
}

submenu_port_forwarding() {
    while true; do
        clear
        local _lan _gw
        _lan=$(_detect_lan_ip)
        _gw=$(_detect_gateway)
        ui_box "MediaStack - Test Port Forwarding" \
            "$(ui_kv 'This server (LAN IP)' "${_lan:-unknown}")" \
            "$(ui_kv 'Router (gateway)' "${_gw:-unknown}")" \
            "$(ui_kv 'Torrent port' "${TORRENT_PORT:-6881}")"
        echo ""
        local choice
        choice=$(ui_choose "Test port forwarding:" \
            "Test the required MediaStack ports" \
            "Test a specific port" \
            "Back")

        case "$choice" in
            "Test the required"*) action_port_check ;;
            "Test a specific port"*)
                diag_test_port
                pause_for_menu
                ;;
            *) return 0 ;;
        esac
    done
}

submenu_diagnostics() {
    while true; do
        clear
        local _dom _remote _pip
        if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then _dom="$DOMAIN"; else _dom="none (LAN only)"; fi
        case "${REMOTE_WEB_STATE:-}" in
            ready) _remote="ready" ;;
            skipped) _remote="not set up (skipped)" ;;
            *) _remote="not set up" ;;
        esac
        _pip=$(_cached_public_ip)
        ui_box "MediaStack - Diagnostics" \
            "$(ui_kv 'Public IP' "${_pip:-not detected}")" \
            "$(ui_kv 'Domain' "$_dom")" \
            "$(ui_kv 'Remote access' "$_remote")"
        echo ""
        local choice
        choice=$(ui_choose "Diagnostics:" \
            "Test port forwarding" \
            "Check domain DNS" \
            "System readiness check" \
            "Run speed test" \
            "Back")

        case "$choice" in
            "Test port forwarding"*) submenu_port_forwarding ;;
            "Check domain DNS"*)
                diag_dns_check
                pause_for_menu
                ;;
            "System readiness"*)
                diag_readiness
                pause_for_menu
                ;;
            "Run speed test"*)
                diag_speedtest
                pause_for_menu
                ;;
            *) return 0 ;;
        esac
    done
}

_health_prime_sudo() {
    sudo -n true 2>/dev/null && return 0
    ui_log info "Firewall and certificate checks need sudo access."
    sudo -v 2>/dev/null || ui_log warn "No sudo — those checks will be skipped."
}

_health_present_spin() {
    local label="$1"
    shift
    local _hc_vf
    _hc_vf=$(mktemp)
    _hc_spin_run() { "$@" >"$_hc_vf" 2>/dev/null; }
    ui_spin "$label" _hc_spin_run "$@"
    unset -f _hc_spin_run
    health_present "$(cat "$_hc_vf")"
    rm -f "$_hc_vf"
}

_health_run_all_spin() {
    _LOG_COUNTS_OK=0 _LOG_COUNTS_WARN=0 _LOG_COUNTS_ERROR=0 _LOG_COUNTS_SKIP=0
    local label fn arg
    while IFS=$'\t' read -r label fn arg; do
        _health_present_spin "Checking ${label}..." "$fn" ${arg:+"$arg"}
    done < <(_health_each)
    echo ""
    ui_log info "Summary: $(log_capture_summary)"
}

submenu_health() {
    if ! declare -F _health_each >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/scripts/lib/health.sh"
    fi
    while true; do
        clear
        ui_box "MediaStack - Health & security" \
            "$(ui_kv 'Detects' 'silent failures Docker health checks miss')"
        echo ""
        local choice
        choice=$(ui_choose "Health & security:" \
            "Run all checks" \
            "fail2ban protection (regex + jails)" \
            "TLS certificate expiry" \
            "DNS / public-IP drift" \
            "Disk space" \
            "Firewall (UFW + Docker port lock)" \
            "Back")

        case "$choice" in
            "Run all checks"*)
                _health_prime_sudo
                echo ""
                _render_service_list
                echo ""
                _health_run_all_spin
                pause_for_menu
                ;;
            "fail2ban"*)
                _health_present_spin "Checking fail2ban jails..." health_fail2ban_jails
                _health_present_spin "Checking fail2ban jellyfin filter (~15s)..." health_fail2ban_regex jellyfin
                _health_present_spin "Checking fail2ban seerr filter (~15s)..." health_fail2ban_regex seerr
                _health_present_spin "Checking fail2ban jellyfin log watch..." health_fail2ban_watching jellyfin
                pause_for_menu
                ;;
            "TLS certificate"*)
                _health_prime_sudo
                _health_present_spin "Checking TLS certificate..." health_cert_expiry
                pause_for_menu
                ;;
            "DNS"*)
                _health_present_spin "Checking DNS / public IP (~5s)..." health_dns_drift
                pause_for_menu
                ;;
            "Disk"*)
                _health_present_spin "Checking disk space..." health_disk_pct
                pause_for_menu
                ;;
            "Firewall"*)
                _health_prime_sudo
                _health_present_spin "Checking UFW firewall..." health_ufw_active
                _health_present_spin "Checking Docker port lock..." health_docker_user_restrict
                pause_for_menu
                ;;
            *) return 0 ;;
        esac
    done
}

_f2b_banned_pairs() {
    local status jails j
    status=$(docker exec fail2ban fail2ban-client status 2>/dev/null | tr -d '\r') || return 0
    jails=$(sed -n 's/.*Jail list:[[:space:]]*//p' <<<"$status" | tr ',' ' ')
    for j in $jails; do
        local jstat iplist ip
        jstat=$(docker exec fail2ban fail2ban-client status "$j" 2>/dev/null | tr -d '\r') || continue
        iplist=$(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<<"$jstat" | head -1)
        for ip in $iplist; do printf '%s\t%s\n' "$j" "$ip"; done
    done
}

_f2b_banned_now_summary() {
    local pairs ip ips=() tally n plural
    pairs=$(_f2b_banned_pairs)
    while IFS= read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(cut -f2 <<<"$pairs" | sort -u)
    n=${#ips[@]}
    ((n == 0)) && {
        printf 'none'
        return 0
    }
    tally=$(awk -F'\t' '
        NF==2 { if (!($1 in seen)) { seen[$1]=1; order[++c]=$1 } t[$1]++ }
        END   { sep=""; for (i=1;i<=c;i++) { printf "%s%s %d", sep, order[i], t[order[i]]; sep=", " } }' <<<"$pairs")
    plural=s
    ((n == 1)) && plural=""
    printf '%d IP%s  (%s)' "$n" "$plural" "$tally"
}

_f2b_wl_counts() { # echoes "<defaults> <custom>"
    local jail_file="$SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf"
    local content line tok toks=() d=0 c=0
    content=$(cat "$jail_file" 2>/dev/null)
    [[ -z "$content" ]] && content=$(sudo -n cat "$jail_file" 2>/dev/null)
    [[ -z "$content" ]] && {
        printf '? ?\n'
        return 0
    }
    line=$(grep -m1 '^ignoreip[[:space:]]*=' <<<"$content")
    read -ra toks <<<"${line#*=}"
    for tok in "${toks[@]+"${toks[@]}"}"; do
        if _f2b_wl_is_default "$tok"; then d=$((d + 1)); else c=$((c + 1)); fi
    done
    printf '%d %d\n' "$d" "$c"
}

_f2b_wl_is_default() {
    case "$1" in
        127.0.0.0/8 | 10.0.0.0/8 | 172.16.0.0/12 | 192.168.0.0/16) return 0 ;;
        *) return 1 ;;
    esac
}

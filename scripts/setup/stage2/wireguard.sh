# Owns: stage2_* — Stage 2 WireGuard opt-in and access-tier collection.
# Sources: Stage 2 defaults, network detection, WireGuard validators, and UI.

_stage2_collect_wireguard() {
    ui_section 3 5 "WireGuard"

    # Opt-in sub-toggle: WireGuard is a distinct service (the wg-easy container),
    # not mandatory for HTTPS remote access. Gate its config prompts behind an
    # enable so the "choose feature -> configure feature" flow holds. When off we
    # return early and leave WG_INIT_PASSWORD unset, so the remote WG profile
    # (gated on WG_INIT_PASSWORD alone) stays inactive.
    local wg_default="yes"
    [[ "${_WIZ_WG_ENABLED:-true}" == "true" ]] || wg_default="no"
    ui_log info "WireGuard gives you a private VPN to reach admin pages and your home LAN while away. Recommended."
    if ! ui_confirm "Also set up a WireGuard VPN for admin access?" "$wg_default"; then
        _WIZ_WG_ENABLED="false"
        ui_kv "WireGuard" "disabled"
        return 0
    fi
    _WIZ_WG_ENABLED="true"

    # WireGuard endpoint = the same hostname users already entered for
    # HTTPS in [1/5] Domain + DDNS. Asking again is friction for zero
    # value (one DDNS hostname covers both HTTPS and the VPN endpoint).
    # Power users who want a separate WG hostname can override WG_HOST
    # in .env after install.
    _WIZ_WG_HOST="${_WIZ_DOMAIN:-$_WIZ_WG_HOST}"
    ui_log info "WireGuard endpoint: ${_WIZ_WG_HOST} (using your domain - override WG_HOST in .env if you need a different one)."

    _WIZ_WG_PORT=$(ui_input_validated \
        "WireGuard UDP port" \
        "${_WIZ_WG_PORT:-51820}" \
        validate_wireguard_port)

    # Access tier replaces the old "tunnel mode" prompt. Three options surface
    # for the initial peer: Full LAN (owner), Server (co-admin, includes SSH /
    # host services), Containers (trusted household, MediaStack apps only).
    # The Streaming / Streaming + requests tiers are README templates for
    # friends/kids — not sensible initial-peer choices because the owner would
    # lock themselves out. Full tunnel is an env-only override
    # (see docs/design/architecture.md).
    local tier_choice tier
    local tier_default_index=1
    case "$_WIZ_WG_ACCESS_TIER" in
        server) tier_default_index=2 ;;
        containers) tier_default_index=3 ;;
    esac
    tier_choice=$(UI_CHOOSE_DEFAULT_INDEX="$tier_default_index" ui_choose \
        "VPN access level for your admin device" \
        "Full LAN (recommended) - reach every device on your home network" \
        "Server only - reach this MediaStack box (all ports, including SSH)" \
        "Containers only - reach MediaStack apps (no host services or other LAN devices)")
    case "$tier_choice" in
        Full*) tier="full-lan" ;;
        Server*) tier="server" ;;
        Containers*) tier="containers" ;;
        *) tier="full-lan" ;;
    esac
    _WIZ_WG_ACCESS_TIER="$tier"

    # Server LAN IP for /32 tiers comes from HOST_ADDRESS (set by Stage 1's
    # env_gen). If detection failed it'll be "localhost" — warn and keep
    # going; the user can fix HOST_ADDRESS in .env later.
    _WIZ_WG_SERVER_LAN_IP="${HOST_ADDRESS:-${_WIZ_WG_SERVER_LAN_IP:-localhost}}"
    if [[ "$_WIZ_WG_SERVER_LAN_IP" == "localhost" || "$_WIZ_WG_SERVER_LAN_IP" == "127.0.0.1" ]]; then
        ui_log warn "HOST_ADDRESS is '$_WIZ_WG_SERVER_LAN_IP' - not a real LAN IP."
        ui_log warn "VPN peers can't reach this box until you set a real LAN IP in .env."
    fi

    # Full LAN tier needs the actual LAN CIDR; auto-detect and let the user
    # confirm or override. Other tiers route only the server IP /32, so no
    # LAN CIDR question.
    if [[ "$tier" == "full-lan" ]]; then
        local detected
        detected=$(net_detect_lan_cidr 2>/dev/null || true)
        if [[ -z "$detected" ]]; then
            detected="${_WIZ_WG_LAN_CIDR:-192.168.1.0/24}"
            ui_log warn "Could not auto-detect LAN CIDR; using '$detected' as a placeholder. Verify before peers connect."
        fi
        _WIZ_WG_LAN_CIDR=$(ui_input_validated \
            "Home LAN CIDR (peers will route this through the tunnel)" \
            "${_WIZ_WG_LAN_CIDR:-$detected}" \
            validate_lan_cidr)
        # Normalize user input to network address (192.168.1.50/24 -> 192.168.1.0/24).
        _WIZ_WG_LAN_CIDR=$(python3 -c '
import sys, ipaddress
print(ipaddress.IPv4Network(sys.argv[1], strict=False))
' "$_WIZ_WG_LAN_CIDR" 2>/dev/null || printf '%s' "$_WIZ_WG_LAN_CIDR")
    else
        _WIZ_WG_LAN_CIDR=""
    fi

    local env_lines
    env_lines=$(net_wireguard_access_tier_env "$tier" "$_WIZ_WG_LAN_CIDR" "$_WIZ_WG_SERVER_LAN_IP")
    while IFS='=' read -r key raw; do
        raw="${raw#\'}"
        raw="${raw%\'}"
        case "$key" in
            WG_INIT_ALLOWED_IPS) _WIZ_WG_INIT_ALLOWED_IPS="$raw" ;;
            WG_PER_CLIENT_FIREWALL) _WIZ_WG_PER_CLIENT_FIREWALL="$raw" ;;
        esac
    done <<<"$env_lines"

    ui_log info "WireGuard admin login: ${_WIZ_ADMIN_USER} / your admin password (the same one you set earlier)."
    case "$tier" in
        full-lan)
            ui_log info "Access level: Full LAN. Initial peer reaches ${_WIZ_WG_LAN_CIDR}."
            ui_log info "Add more peers in the wg-easy UI (see README templates)."
            ;;
        server)
            ui_log info "Access level: Server. Initial peer reaches ${_WIZ_WG_SERVER_LAN_IP} (all ports, including SSH)."
            ;;
        containers)
            ui_log info "Access level: Containers. Initial peer reaches MediaStack app ports on ${_WIZ_WG_SERVER_LAN_IP}."
            ui_log info "Host services (SSH, SMB) are blocked."
            ;;
    esac
    ui_kv "WireGuard" "${_WIZ_WG_HOST}:${_WIZ_WG_PORT} (${tier})"
    # WG_INIT_PASSWORD is committed in _stage2_install (install path only), not
    # here — setting it during collection leaks it into confirm-time skips and
    # silently activates WireGuard.
}

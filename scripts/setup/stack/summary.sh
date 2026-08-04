# Owns: Remote/transcoding state labels and the final install / day-2 access-info summary for setup.sh.
# Sources: scripts/setup/stack.sh state ($SCRIPT_DIR, env vars) plus scripts/lib/common.sh and scripts/lib/ui.sh.

# Map REMOTE_WEB_STATE -> a human label. Single source of truth for the Stage 2
# row in print_final_summary AND the recovery re-entry menu's "Current setup"
# block, so the two never drift. Reads $1 (defaults to $REMOTE_WEB_STATE).
remote_state_label() {
    local remote_state="${1-${REMOTE_WEB_STATE:-}}"
    case "$remote_state" in
        ready) printf 'ready' ;;
        skipped) printf 'skipped - choose Features & settings -> Add remote access to retry' ;;
        failed) printf 'failed - choose Features & settings -> Add remote access to retry' ;;
        unchecked | "") printf 'not configured' ;;
        *) printf 'not configured' ;;
    esac
}

# Map STAGE_3_GPU_STATE (+ STAGE_3_GPU_VENDOR) -> a human label. Single source of
# truth for the Hardware-transcoding row in print_final_summary AND the recovery
# re-entry menu's "Current setup" block. Reads $1/$2 (default to the env vars).
transcoding_state_label() {
    local gpu_state="${1-${STAGE_3_GPU_STATE:-}}"
    local gpu_vendor="${2-${STAGE_3_GPU_VENDOR:-}}"
    case "$gpu_state" in
        complete)
            case "$gpu_vendor" in
                intel) printf 'complete (Intel QSV)' ;;
                amd) printf 'complete (AMD VAAPI)' ;;
                nvidia) printf 'complete (NVIDIA NVENC)' ;;
                *) printf 'complete' ;;
            esac
            ;;
        pending)
            if [[ "$gpu_vendor" == "nvidia" ]]; then
                printf 'pending reboot - NVIDIA finalization queued'
            else
                printf 'not configured'
            fi
            ;;
        skipped) printf 'skipped - software transcoding' ;;
        fallback) printf 'fallback - software transcoding' ;;
        *) printf 'not configured' ;;
    esac
}

print_final_summary() {
    if ! type ui_kv >/dev/null 2>&1; then
        ui_kv() { printf '%s: %s' "$1" "$2"; }
    fi

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi

    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    lan_ip="${lan_ip:-${HOST_ADDRESS:-localhost}}"
    # No routable IP detected - the Homepage/Jellyfin LAN rows fall back to loopback,
    # which only works on this box. Flag it so the box below carries a caveat instead
    # of silently presenting local-only links as if a phone/TV could reach them.
    local lan_local_only=false
    [[ "$lan_ip" == "localhost" ]] && lan_local_only=true

    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"
    local admin="${JELLYFIN_ADMIN_USER:-admin}"
    local email="${NPM_ADMIN_EMAIL:-}"
    local wg_init_pw="${WG_INIT_PASSWORD:-}"

    local stage1_label="not configured"
    [[ "${STAGE_1_COMPLETE:-}" == "1" ]] && stage1_label="complete"

    local stage2_label
    stage2_label="$(remote_state_label "$remote_state")"

    local transcoding_label
    transcoding_label="$(transcoding_state_label "${STAGE_3_GPU_STATE:-}" "${STAGE_3_GPU_VENDOR:-}")"

    local homepage="http://${lan_ip}:3000"
    local jellyfin_lan="http://${lan_ip}:8096"
    local remote_ready=false
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready=true
    fi

    # Labelled by name (not "Stage N") and ordered to match how setup actually
    # runs: core media server -> hardware transcoding -> remote access. The old
    # numbering was misleading (transcoding ran second but was unnumbered, remote
    # ran third but was "Stage 2").
    local rows=(
        "$(ui_kv 'Core media server' "$stage1_label")"
        "$(ui_kv 'Hardware transcoding' "$transcoding_label")"
        "$(ui_kv 'Remote access' "$stage2_label")"
        "$(ui_kv 'Homepage' "$homepage")"
        "$(ui_kv 'Jellyfin LAN' "$jellyfin_lan")"
    )
    if $remote_ready; then
        rows+=("$(ui_kv 'Jellyfin remote' "https://jellyfin.${domain}")")
        rows+=("$(ui_kv 'Seerr remote' "https://seerr.${domain}")")
    fi
    if [[ -n "$wg_init_pw" ]]; then
        rows+=("$(ui_kv 'WireGuard admin' "http://${lan_ip}:51821")")
    fi
    rows+=("$(ui_kv 'Admin user' "$admin")")
    rows+=("$(ui_kv 'Admin email' "$email")")

    if type ui_box >/dev/null 2>&1 && type ui_kv >/dev/null 2>&1; then
        ui_box "MediaStack setup complete" "${rows[@]}"
    else
        printf 'MediaStack setup complete\n'
        printf '%s\n' "${rows[@]}"
    fi

    # Loopback fallback: the Homepage/Jellyfin LAN rows above only work on this box.
    # Spell that out so a headless-server user doesn't read them as phone/TV links.
    if $lan_local_only; then
        echo ""
        echo -e "  ${YELLOW}LAN IP not detected - the localhost links above only work ON this machine.${NC}"
        echo -e "  ${YELLOW}Assign a static LAN IP (or set HOST_ADDRESS in .env), then re-run setup for${NC}"
        echo -e "  ${YELLOW}phone/TV-reachable links.${NC}"
    fi
}

# Echo the stored admin password (the single shared credential reused across every
# service) from .env, or nothing if unset. Single source of truth for the access
# summary's password line and the launcher's day-2 "reveal" so the two never drift,
# and so both always reflect the on-disk value rather than a possibly-stale env var.
_access_admin_pw() {
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    grep -oP "^JELLYFIN_ADMIN_PASSWORD='\\K[^']+" "$SCRIPT_DIR/.env" 2>/dev/null || true
}

# print_access_info [mask]
#   mask — render the admin password as a hidden placeholder instead of the value.
#   The one-time install summary calls this with no arg (shows the value, so the user
#   can save it). The re-openable day-2 launcher view passes `mask`, then offers an
#   explicit opt-in reveal — the shared credential should not be re-printed on screen
#   (or captured to a file) every time someone opens the menu.
print_access_info() {
    local mask_secret=false
    [[ "${1:-}" == "mask" ]] && mask_secret=true
    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    # Mirror print_final_summary: honour an explicit HOST_ADDRESS from .env before
    # giving up to the loopback fallback, so a headless box with HOST_ADDRESS set
    # still renders routable URLs.
    lan_ip="${lan_ip:-${HOST_ADDRESS:-localhost}}"
    # When detection failed and we fell back to loopback, every ${u}:PORT row below
    # only works ON this machine. Flag it so we can print a caveat the headless-box
    # user won't otherwise connect to the earlier Stage 1 "LAN IP not detected" warning.
    local lan_local_only=false
    [[ "$lan_ip" == "localhost" ]] && lan_local_only=true

    local u="http://${lan_ip}"
    local admin="${JELLYFIN_ADMIN_USER:-admin}"
    local email="${NPM_ADMIN_EMAIL:-admin@example.com}"
    local torrent_port="${TORRENT_PORT:-6881}"
    local wg_port="${WG_PORT:-51820}"

    local admin_pw=""
    local domain=""
    local remote_state=""
    local wg_init_pw=""
    local jellyfin_gpu="${JELLYFIN_GPU:-none}"
    local stage3_state="${STAGE_3_GPU_STATE:-}"
    local public_indexers_enabled="${PUBLIC_INDEXERS_ENABLED:-false}"
    admin_pw=$(_access_admin_pw)
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        domain=$(grep -oP '^DOMAIN=\K.*' "$SCRIPT_DIR/.env" | tr -d "'" | tr -d '"')
        remote_state=$(grep -oP '^REMOTE_WEB_STATE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        # WireGuard is gated on WG_INIT_PASSWORD alone, independent of DOMAIN (see
        # _build_profile_args' --profile remote) — so this drives the wg-easy admin
        # line below regardless of whether HTTPS/domain remote access was set up.
        wg_init_pw=$(grep -oP "^WG_INIT_PASSWORD='\\K[^']+" "$SCRIPT_DIR/.env" 2>/dev/null || true)
        jellyfin_gpu=$(grep -oP '^JELLYFIN_GPU=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        stage3_state=$(grep -oP '^STAGE_3_GPU_STATE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        public_indexers_enabled=$(grep -oP '^PUBLIC_INDEXERS_ENABLED=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
    fi
    jellyfin_gpu="${jellyfin_gpu:-none}"
    public_indexers_enabled="${public_indexers_enabled:-false}"
    local has_domain=false
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        has_domain=true
    fi
    local remote_ready=false
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready=true
    fi

    echo ""
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
    echo -e "${BOLD}  MediaStack is running!${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
    echo ""
    echo -e "  ${BOLD}Admin user:${NC}       ${GREEN}${admin}${NC}"
    if [[ -n "$admin_pw" ]]; then
        if $mask_secret; then
            echo -e "  ${BOLD}Admin password:${NC}   ${YELLOW}(hidden — confirm the reveal prompt to show it)${NC}"
        else
            echo -e "  ${BOLD}Admin password:${NC}   ${GREEN}${admin_pw}${NC}"
        fi
    fi
    echo -e "  ${BOLD}Admin email:${NC}      ${GREEN}${email}${NC}"
    if [[ "${STORAGE_MODE:-local}" == "nas" ]]; then
        if [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
            echo -e "  ${BOLD}Storage:${NC}          ${YELLOW}NAS protected, manual app paths (${STORAGE_NFS_HOST:-unknown}:${STORAGE_NFS_EXPORT:-unknown})${NC}"
        else
            echo -e "  ${BOLD}Storage:${NC}          ${GREEN}NAS (${STORAGE_NFS_HOST:-unknown}:${STORAGE_NFS_EXPORT:-unknown})${NC}"
        fi
    elif [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
        echo -e "  ${BOLD}Storage:${NC}          ${YELLOW}manual - app storage paths were not auto-configured${NC}"
    fi
    echo ""
    # Every service below logs in with the single shared admin password shown (or, in the
    # masked day-2 view, revealable) at the top of this screen. Point each row's LOGIN at it
    # rather than the bare word "password", which a non-technical user can misread as a
    # literal value to type. Mode-aware so the masked view never implies a value is on screen.
    local cred_hint="(admin password above)"
    $mask_secret && cred_hint="(your admin password)"
    if $lan_local_only; then
        echo -e "  ${YELLOW}LAN IP not detected - the http://localhost URLs below only work ON this machine.${NC}"
        echo -e "  ${YELLOW}Assign a static LAN IP (or set HOST_ADDRESS in .env), then re-run setup to get${NC}"
        echo -e "  ${YELLOW}phone/TV-reachable links.${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}SERVICE          URL                     LOGIN${NC}"
    echo -e "  ${CYAN}$(_g_repeat 61 "$_G_H")${NC}"
    echo -e "  Homepage         ${u}:3000     ${GREEN}no login${NC}"
    echo -e "  Jellyfin         ${u}:8096     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Sonarr           ${u}:8989     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Radarr           ${u}:7878     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  qBittorrent      ${u}:8080     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Jackett          ${u}:9117     ${GREEN}${cred_hint/%)/, no username)}${NC}"
    echo -e "  Seerr            ${u}:5055     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Portainer        ${u}:9000     ${GREEN}${admin} / ${cred_hint}${NC}"
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        echo -e "  Bazarr           ${u}:6767     ${GREEN}${admin} / ${cred_hint}${NC}"
    fi
    echo -e "  Uptime Kuma      ${u}:3001     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Beszel           ${u}:8090     ${GREEN}${email} / ${cred_hint}${NC}"
    if $has_domain; then
        echo -e "  NPM Admin        ${u}:81       ${GREEN}${email} / ${cred_hint}${NC}"
    fi
    echo ""

    # WireGuard is a LAN-reachable admin service whenever the remote profile is up
    # (gated on WG_INIT_PASSWORD, not on having a domain) — its wg-easy UI is the
    # only place to download VPN client configs / QR codes, so surface it here.
    if [[ -n "$wg_init_pw" ]]; then
        echo -e "  ${BOLD}WireGuard VPN${NC}    ${u}:51821     ${GREEN}admin UI — get VPN client configs / QR here${NC}"
        echo ""
    fi

    if [[ "$stage3_state" == "complete" && "$jellyfin_gpu" != "none" ]]; then
        echo -e "  ${GREEN}GPU: $(gpu_brand_label "$jellyfin_gpu") transcoding enabled${NC}"
        echo "  Configure in Jellyfin > Dashboard > Playback > Transcoding"
        echo ""
    fi

    if [[ "${SMB_ENABLED:-false}" == "true" ]]; then
        local smb_share_name="Media"
        local smb_share_path="${DATA_DIR:-/data}"
        if [[ "${SMB_SHARE_SCOPE:-data}" == "system" ]]; then
            smb_share_name="MediaStackSystem"
            smb_share_path="/"
        fi
        echo -e "  ${GREEN}SMB share: \\\\${lan_ip}\\${smb_share_name} -> ${smb_share_path}${NC}"
        echo "  Connect with admin credentials from any device on your network"
        echo ""
    fi

    if [[ "$public_indexers_enabled" != "true" ]]; then
        echo -e "  ${YELLOW}No search indexers configured${NC} - Sonarr/Radarr can't find releases yet."
        echo "  Enable them anytime from the launcher:"
        echo "    ./mediastack -> Features & settings -> Search indexers"
        echo ""
    fi

    if $has_domain; then
        echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
        echo -e "  ${BOLD}REMOTE ACCESS${NC}"
        echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
        echo ""
        if $remote_ready; then
            echo -e "  ${BOLD}Jellyfin${NC}         https://jellyfin.${domain}"
            echo -e "  ${BOLD}Seerr${NC}            https://seerr.${domain}"
        elif [[ "$remote_state" == "skipped" ]]; then
            echo "  HTTPS skipped. LAN + VPN work. Choose Features & settings -> Add remote access from the menu to try again."
        elif [[ "$remote_state" == "failed" ]]; then
            echo "  HTTPS setup failed. LAN + VPN work. Choose Features & settings -> Add remote access from the menu after fixing the issue."
        else
            echo "  Remote access: not yet configured -- choose Features & settings -> Add remote access from the menu"
        fi
        echo ""
    fi

    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo -e "  ${BOLD}PORT FORWARDING${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo ""
    echo "  Forward these ports to ${lan_ip} in your router:"
    echo ""
    echo "  TCP+UDP $(printf '%-6s' "$torrent_port")-> ${lan_ip}   (qBittorrent peer connections)"
    if $has_domain; then
        echo "  TCP 80        -> ${lan_ip}   (Let's Encrypt + HTTP redirect)"
        echo "  TCP 443       -> ${lan_ip}   (HTTPS - Jellyfin, Seerr)"
        echo "  UDP $(printf '%-6s' "$wg_port")-> ${lan_ip}   (WireGuard VPN)"
    fi
    echo ""

    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo -e "  ${BOLD}GETTING STARTED${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo ""
    echo "  Open Homepage:    ${u}:3000"
    echo ""
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}Subtitles: add a provider at ${u}:6767/settings/providers${NC}"
        echo -e "  ${YELLOW}Recommended: OpenSubtitles.com (free account required)${NC}"
        echo ""
    fi
    if ! groups 2>/dev/null | grep -qw docker; then
        echo -e "  ${YELLOW}Log out and back in (or run: newgrp docker) to use docker commands${NC}"
        echo ""
    fi

    if [[ "$remote_ready" != "true" ]]; then
        echo ""
        echo -e "  ${BOLD}You can stop here. Your media server works on the LAN.${NC}"
        echo "  To enable remote access (HTTPS, VPN), choose Features & settings -> Add remote access from the menu."
        echo ""
    fi
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
}

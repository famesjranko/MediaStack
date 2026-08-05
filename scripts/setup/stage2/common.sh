# Owns: Stage 2 shared defaults, choice labels, state helpers, and HTTPS probes.
# Sources: setup globals, scripts/lib/common.sh, scripts/lib/npm-remote.sh, and scripts/lib/ddns-providers.sh.

stage2_offer_choices() {
    printf '%s\n' "Enable remote access" "Skip for now" "Tell me more"
}

stage2_dns_retry_choices() {
    printf '%s\n' "Retry DNS check" "Skip HTTPS for now"
}

stage2_port_gate_choices() {
    printf '%s\n' "Retry" "Continue with manual verification" "Skip HTTPS for now"
}

stage2_confirm_choices() {
    printf '%s\n' "Install" "Back" "Skip remote access"
}

stage2_le_failure_choices() {
    printf '%s\n' "Skip HTTPS for now" "Exit so I can fix and retry" "Abort setup"
}

stage2_skip_summary_copy() {
    printf 'HTTPS skipped. LAN + VPN work. Choose Features & settings -> Add remote access from the menu to try again.'
}

stage2_tell_me_more_copy() {
    cat <<'COPY'
Remote access needs a domain, DNS records for Jellyfin and Seerr, router forwards for TCP 80 and 443, and one Let's Encrypt certificate attempt. A DDNS provider can keep DNS updated when your home IP changes. WireGuard gives you a VPN for admin tools and fallback access. Skipping is safe: your LAN stack keeps working, and you can add it later from Features & settings -> Add remote access in the menu.
COPY
}

_stage2_seed_wizard_defaults() {
    _WIZ_TZ="${_WIZ_TZ:-${_WIZ_PREV_TZ:-${TZ:-${_ENV_TZ:-Etc/UTC}}}}"
    _WIZ_DATA_DIR="${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-${DATA_DIR:-/data}}}"
    _WIZ_ADMIN_USER="${_WIZ_ADMIN_USER:-${_WIZ_PREV_USER:-${JELLYFIN_ADMIN_USER:-admin}}}"
    _WIZ_ADMIN_EMAIL="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-${NPM_ADMIN_EMAIL:-}}}"
    case "${_WIZ_ADMIN_EMAIL,,}" in
        admin@mediastack.local | *@example.com | *@example.net | *@example.org) _WIZ_ADMIN_EMAIL="" ;;
    esac
    _WIZ_ADMIN_PW="${_WIZ_ADMIN_PW:-${_WIZ_PREV_PW:-${JELLYFIN_ADMIN_PASSWORD:-}}}"
    # Stage 2 explicitly invokes remote-access setup, so the LAN-only sentinel
    # `example.com` is the wrong default — it'd silently pass validation and
    # then DNS-classify to apex-only forever. Let validate_domain_name reject
    # empty input on the wizard's first prompt instead.
    _WIZ_DOMAIN="${_WIZ_DOMAIN:-${_WIZ_PREV_DOMAIN:-${DOMAIN:-}}}"
    [[ "$_WIZ_DOMAIN" == "example.com" ]] && _WIZ_DOMAIN=""
    _WIZ_TORRENT_PORT="${_WIZ_TORRENT_PORT:-${_WIZ_PREV_TORRENT_PORT:-${TORRENT_PORT:-6881}}}"
    _WIZ_DL_LIMIT="${_WIZ_DL_LIMIT:-${_WIZ_PREV_DL:-${QBT_DL_LIMIT:-0}}}"
    _WIZ_UL_LIMIT="${_WIZ_UL_LIMIT:-${_WIZ_PREV_UL:-${QBT_UL_LIMIT:-0}}}"
    _WIZ_BAZARR_ENABLED="${_WIZ_BAZARR_ENABLED:-${_WIZ_PREV_BAZARR:-${BAZARR_ENABLED:-false}}}"
    _WIZ_SMB_ENABLED="${_WIZ_SMB_ENABLED:-${_WIZ_PREV_SMB:-${SMB_ENABLED:-false}}}"
    _WIZ_SMB_SHARE_SCOPE="${_WIZ_SMB_SHARE_SCOPE:-${_WIZ_PREV_SMB_SHARE_SCOPE:-${SMB_SHARE_SCOPE:-data}}}"
    # Prefer _WIZ_DOMAIN (the freshly-entered Stage 2 hostname) over a stale
    # WG_HOST=example.com left in .env from Stage 1 (when DOMAIN defaulted to
    # example.com because Stage 1 is LAN-only). Only honor a real WG_HOST.
    if [[ -n "${WG_HOST:-}" && "${WG_HOST:-}" != "example.com" ]]; then
        _WIZ_WG_HOST="${_WIZ_WG_HOST:-$WG_HOST}"
    else
        _WIZ_WG_HOST="${_WIZ_WG_HOST:-${_WIZ_DOMAIN:-}}"
    fi
    _WIZ_WG_PORT="${_WIZ_WG_PORT:-${_WIZ_PREV_WG_PORT:-${WG_PORT:-51820}}}"
    _WIZ_WG_DNS="${_WIZ_WG_DNS:-${WG_DEFAULT_DNS:-1.1.1.1}}"
    _WIZ_WG_ACCESS_TIER="${_WIZ_WG_ACCESS_TIER:-${WG_ACCESS_TIER:-full-lan}}"
    _WIZ_WG_LAN_CIDR="${_WIZ_WG_LAN_CIDR:-${WG_LAN_CIDR:-}}"
    _WIZ_WG_SERVER_LAN_IP="${_WIZ_WG_SERVER_LAN_IP:-${WG_SERVER_LAN_IP:-${HOST_ADDRESS:-}}}"
    _WIZ_WG_INIT_ALLOWED_IPS="${_WIZ_WG_INIT_ALLOWED_IPS:-${WG_INIT_ALLOWED_IPS:-}}"
    _WIZ_WG_PER_CLIENT_FIREWALL="${_WIZ_WG_PER_CLIENT_FIREWALL:-${WG_PER_CLIENT_FIREWALL:-true}}"
    # Don't fall through to _WIZ_ADMIN_PW here — _stage2_install commits it on the
    # install path (and only when WireGuard is opted in). Skip paths never set it,
    # so .env preserves WG_INIT_PASSWORD='' and the remote profile stays inactive.
    _WIZ_WG_INIT_PASSWORD="${_WIZ_WG_INIT_PASSWORD:-${WG_INIT_PASSWORD:-}}"
    # Whether the user opts into the WireGuard VPN. Default on (recommended); the
    # sub-toggle in _stage2_collect_wireguard re-asks and can turn it off.
    _WIZ_WG_ENABLED="${_WIZ_WG_ENABLED:-true}"
    if [[ "${_WIZ_DDNS_INVALIDATED:-false}" == "true" ]]; then
        _WIZ_DDNS_PROVIDER=""
        _WIZ_DDNS_FIELDS=()
        _WIZ_DDNS_PREFLIGHT_OK="false"
    else
        # Recall the provider from the non-secret .env key, then the credential
        # fields from the chmod-600 config.json (the .env no longer carries the
        # secrets). This is the DDNS analogue of the admin _WIZ_PREV_* recall: a
        # re-run pre-fills the field-loop prompts so the user presses Enter
        # through. _WIZ_DDNS_PREFLIGHT_OK is deliberately NOT resurrected here —
        # it means "the provider accepted these creds this session" and drives
        # only the messaging tier; persistence gates on shape-valid render.
        _WIZ_DDNS_PROVIDER="${_WIZ_DDNS_PROVIDER:-${DDNS_PROVIDER:-}}"
        _stage2_recall_ddns_from_config
    fi
    # Whether the user opted into DDNS (dynamic IP) vs. skipped it (static IP or
    # self-managed DNS). Set authoritatively by _stage2_offer_ddns; seeded here
    # so the DNS-failure menu's "Re-enter credentials" guard is never unset.
    _WIZ_USES_DDNS="true"
}

stage2_preserve_stage1_marker() {
    if [[ -f "$SCRIPT_DIR/.env" && "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        sed -i 's/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/' "$SCRIPT_DIR/.env"
    fi
}

_stage2_set_remote_state() {
    local state="$1"
    local env_path="$SCRIPT_DIR/.env"
    [[ -f "$env_path" ]] || return 1

    # One blessed .env writer (common.sh) — atomic, mode-preserving, quoted.
    _env_write_kv "$env_path" REMOTE_WEB_STATE "$state" >/dev/null
    export REMOTE_WEB_STATE="$state"
}

_stage2_source_env() {
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
}

_stage2_probe_https_ready() {
    local url="$1"
    local host
    local -a curl_args=(--max-time 10 -fsS)
    local le_server="${NPM_LE_SERVER:-}"

    host="${url#https://}"
    host="${host%%/*}"
    host="${host%%:*}"
    if [[ -n "$host" && "$host" != "$url" ]]; then
        # Exercise the NPM SNI vhost without depending on public DNS from the
        # setup host. DNS was already gated separately; this probe verifies
        # nginx has the cert-backed host live on the local published 443 port.
        curl_args+=(--resolve "${host}:443:127.0.0.1")
    fi

    # Only production LE's root is in the system CA bundle. Staging LE
    # ("(STAGING) Let's Encrypt", root "Fake LE Root X1"), Pebble, and any
    # custom ACME endpoint are not — without -k curl refuses to verify and
    # the probe falsely reports the host as not-ready.
    if [[ -n "$le_server" && "$le_server" != "https://acme-v02.api.letsencrypt.org/directory" ]]; then
        curl_args+=(-k)
    fi

    curl "${curl_args[@]}" "$url" >/dev/null 2>&1
}

stage2_le_status_path() {
    printf '%s\n' "$SCRIPT_DIR/config/state/npm-cert-status-last.json"
}

_stage2_is_interactive() {
    [[ -t 0 && "${MEDIASTACK_NONINTERACTIVE:-0}" != "1" && "${DEMO:-0}" != "1" ]]
}

_stage2_le_log_text() {
    local log_dir="$SCRIPT_DIR/config/npm/data/logs"
    [[ -d "$log_dir" ]] || return 0
    if [[ $(id -u) -eq 0 ]]; then
        cat "$log_dir"/letsencrypt.log* 2>/dev/null || true
    else
        cat "$log_dir"/letsencrypt.log* 2>/dev/null || sudo -n cat "$log_dir"/letsencrypt.log* 2>/dev/null || true
    fi
}

_stage2_le_request_log_text() {
    local log_dir="$SCRIPT_DIR/config/npm/data/logs"
    [[ -d "$log_dir" ]] || return 0
    if [[ $(id -u) -eq 0 ]]; then
        cat "$log_dir"/letsencrypt-requests_access.log* 2>/dev/null || true
    else
        cat "$log_dir"/letsencrypt-requests_access.log* 2>/dev/null || sudo -n cat "$log_dir"/letsencrypt-requests_access.log* 2>/dev/null || true
    fi
}

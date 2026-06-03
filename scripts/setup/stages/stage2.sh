# =============================================================================
# MediaStack Setup -- Stage 2 controller (Remote Access)
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

source "$SCRIPT_DIR/scripts/lib/npm_remote.sh"

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
    printf '%s\n' "Install" "Back" "Skip Stage 2"
}

stage2_le_failure_choices() {
    printf '%s\n' "Skip HTTPS for now" "Exit so I can fix and retry" "Abort setup"
}

stage2_skip_summary_copy() {
    printf 'HTTPS skipped. LAN + VPN work. Run ./setup.sh --remote to try again.'
}

stage2_tell_me_more_copy() {
    cat <<'COPY'
Remote access needs a domain, DNS records for Jellyfin and Jellyseerr, router forwards for TCP 80 and 443, and one Let's Encrypt certificate attempt. Dynu can keep DNS updated when your home IP changes. WireGuard gives you a VPN for admin tools and fallback access. Skipping is safe: your LAN stack keeps working, and you can retry later with ./setup.sh --remote.
COPY
}

_stage2_seed_wizard_defaults() {
    _WIZ_TZ="${_WIZ_TZ:-${_WIZ_PREV_TZ:-${TZ:-${_ENV_TZ:-Etc/UTC}}}}"
    _WIZ_DATA_DIR="${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-${DATA_DIR:-/data}}}"
    _WIZ_ADMIN_USER="${_WIZ_ADMIN_USER:-${_WIZ_PREV_USER:-${JELLYFIN_ADMIN_USER:-admin}}}"
    _WIZ_ADMIN_EMAIL="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-${NPM_ADMIN_EMAIL:-}}}"
    case "${_WIZ_ADMIN_EMAIL,,}" in
        admin@mediastack.local|*@example.com|*@example.net|*@example.org) _WIZ_ADMIN_EMAIL="" ;;
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
    # Don't fall through to _WIZ_ADMIN_PW here — _stage2_collect_wireguard sets
    # it on the install path. Skip path should leave it empty so .env preserves
    # WG_INIT_PASSWORD='' and the remote profile stays inactive.
    _WIZ_WG_INIT_PASSWORD="${_WIZ_WG_INIT_PASSWORD:-${WG_INIT_PASSWORD:-}}"
    if [[ "${_WIZ_DDNS_INVALIDATED:-false}" == "true" ]]; then
        _WIZ_DDNS_USER=""
        _WIZ_DDNS_PW=""
        _WIZ_DDNS_PREFLIGHT_OK="false"
    else
        _WIZ_DDNS_USER="${_WIZ_DDNS_USER:-${DDNS_USERNAME:-}}"
        _WIZ_DDNS_PW="${_WIZ_DDNS_PW:-${DDNS_PASSWORD:-}}"
        # Existing .env DDNS creds are recall state from a prior remote
        # attempt. Treat only that sourced state as persistable; newly-entered
        # creds are promoted separately after a live Dynu preflight succeeds.
        if [[ "${_WIZ_DDNS_PREFLIGHT_OK:-false}" != "true" \
            && -n "${DDNS_USERNAME:-}" \
            && -n "${DDNS_PASSWORD:-}" \
            && "${_WIZ_DDNS_USER:-}" == "${DDNS_USERNAME:-}" \
            && "${_WIZ_DDNS_PW:-}" == "${DDNS_PASSWORD:-}" ]]; then
            _WIZ_DDNS_PREFLIGHT_OK="true"
        fi
    fi
}

_stage2_preserve_stage1_marker() {
    if [[ -f "$SCRIPT_DIR/.env" && "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        sed -i 's/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/' "$SCRIPT_DIR/.env"
    fi
}

_stage2_set_remote_state() {
    local state="$1"
    local env_path="$SCRIPT_DIR/.env"
    [[ -f "$env_path" ]] || return 1

    ENV_PATH="$env_path" REMOTE_STATE="$state" python3 -c '
import os
import pathlib
import tempfile

path = pathlib.Path(os.environ["ENV_PATH"])
state = os.environ["REMOTE_STATE"]
lines = path.read_text().splitlines()
written = False
out = []
for line in lines:
    if line.startswith("REMOTE_WEB_STATE="):
        out.append(f"REMOTE_WEB_STATE={state}")
        written = True
    else:
        out.append(line)
if not written:
    out.append(f"REMOTE_WEB_STATE={state}")

fd, tmp = tempfile.mkstemp(prefix=".env.", dir=str(path.parent), text=True)
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
'
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

_stage2_le_ready_hosts() {
    local domain="$1" api="${2:-http://localhost:81/api}"
    local token hosts fqdn cert_id host_json host_id host_cert_id host_enabled ready=()
    token=$(npm_remote_token "$api") || return 1
    [[ -z "$token" ]] && return 1
    hosts=$(curl -sf --max-time 30 -H "Authorization: Bearer $token" \
        "$api/nginx/proxy-hosts" 2>/dev/null) || return 1

    for fqdn in "jellyfin.$domain" "jellyseerr.$domain"; do
        cert_id=$(npm_remote_usable_cert_id_by_fqdn "$token" "$api" "$fqdn") || return 1
        [[ -z "$cert_id" || "$cert_id" == "0" ]] && continue
        host_json=$(npm_remote_host_json_by_fqdn "$hosts" "$fqdn")
        [[ -z "$host_json" ]] && continue
        host_id=$(echo "$host_json" | npm_remote_json_field id)
        host_cert_id=$(echo "$host_json" | npm_remote_json_field certificate_id 0)
        host_enabled=$(echo "$host_json" | npm_remote_json_field enabled False)
        [[ "$host_enabled" =~ ^(True|true)$ ]] || continue
        [[ "$host_cert_id" == "$cert_id" ]] || continue
        npm_remote_proxy_conf_renders "$host_id" "$fqdn" "$cert_id" || continue
        _stage2_probe_https_ready "https://$fqdn" || continue
        ready+=("$fqdn")
    done
    printf '%s\n' "${ready[@]}"
}

STAGE2_LE_CLASSIFICATION="unknown"
STAGE2_LE_READY_HOSTS=""
STAGE2_LE_FAILED_HOSTS=""

stage2_le_classify() {
    local domain="$1"
    local ready_hosts ready_count=0 failed=() fqdn
    STAGE2_LE_CLASSIFICATION="unknown"
    STAGE2_LE_READY_HOSTS=""
    STAGE2_LE_FAILED_HOSTS=""

    if ! docker exec npm nginx -t >/dev/null 2>&1; then
        STAGE2_LE_CLASSIFICATION="npm-unhealthy"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 1
    fi

    ready_hosts=$(_stage2_le_ready_hosts "$domain" 2>/dev/null || true)
    STAGE2_LE_READY_HOSTS="$(printf '%s\n' "$ready_hosts" | awk 'NF { printf "%s%s", sep, $0; sep=", " }')"
    for fqdn in "jellyfin.$domain" "jellyseerr.$domain"; do
        if grep -qx "$fqdn" <<<"$ready_hosts"; then
            ((ready_count += 1))
        else
            failed+=("$fqdn")
        fi
    done
    STAGE2_LE_FAILED_HOSTS="$(IFS=', '; echo "${failed[*]}")"

    if (( ready_count == 2 )); then
        STAGE2_LE_CLASSIFICATION="ready"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 0
    fi
    if (( ready_count == 1 )); then
        STAGE2_LE_CLASSIFICATION="partial"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 1
    fi

    local dns_status="unknown" port_state="unknown" le_log req_log
    if [[ -z "${_NET_PUBLIC_IP:-}" ]]; then
        net_detect_public_ip >/dev/null 2>&1 || true
    fi
    dns_status=$(stage2_dns_classify "$domain" "${_NET_PUBLIC_IP:-}" 2>/dev/null || true)
    if [[ "$dns_status" != "ok" ]]; then
        STAGE2_LE_CLASSIFICATION="config-dns"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 1
    fi

    port_state=$(stage2_check_http_ports 2>/dev/null || printf 'unknown')
    if [[ "$port_state" == "closed:80" || "$port_state" == "closed:80,443" ]]; then
        STAGE2_LE_CLASSIFICATION="config-port"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 1
    fi

    le_log=$(_stage2_le_log_text | tail -400)
    req_log=$(_stage2_le_request_log_text | tail -400)

    if grep -Eiq 'rate.?limit|too many|urn:ietf:params:acme:error:rateLimited' <<<"$le_log"; then
        STAGE2_LE_CLASSIFICATION="rate-limited"
    elif grep -Eiq 'dns|caa|no valid|SERVFAIL|NXDOMAIN|unauthorized' <<<"$le_log"; then
        STAGE2_LE_CLASSIFICATION="config-dns"
    elif grep -Eiq 'connection|Timeout during connect|serverInternal|internal server error' <<<"$le_log"; then
        if grep -Eq '\.well-known/acme-challenge|Client ' <<<"$req_log"; then
            STAGE2_LE_CLASSIFICATION="transient"
        else
            STAGE2_LE_CLASSIFICATION="config-port"
        fi
    else
        STAGE2_LE_CLASSIFICATION="unknown"
    fi

    printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
    [[ "$STAGE2_LE_CLASSIFICATION" == "ready" ]]
}

stage2_le_failure_copy() {
    local classification="$1"
    case "$classification" in
        partial)
            printf 'Partial HTTPS setup: ready=%s; still pending=%s. Wait or fix the issue, then rerun ./setup.sh --remote.' \
                "${STAGE2_LE_READY_HOSTS:-none}" "${STAGE2_LE_FAILED_HOSTS:-unknown}"
            ;;
        transient)
            printf "Let's Encrypt partly reached this server but one validation path failed. Wait a few minutes, then rerun ./setup.sh --remote."
            ;;
        config-dns)
            printf "DNS does not point both Jellyfin and Jellyseerr hostnames at this box. Fix DNS, then rerun ./setup.sh --remote."
            ;;
        config-port)
            printf "Let's Encrypt could not reach TCP port 80 on this box. Fix router/firewall forwarding, then rerun ./setup.sh --remote."
            ;;
        rate-limited)
            printf "Let's Encrypt rate-limited this hostname or account. Wait for the limit to clear, then rerun ./setup.sh --remote."
            ;;
        npm-unhealthy)
            printf "Nginx Proxy Manager's cert/proxy state is unhealthy. The next ./setup.sh --remote run will heal NPM first, then attempt HTTPS again."
            ;;
        unknown|*)
            printf "HTTPS setup did not complete and the cause could not be classified. Check %s and NPM logs, then rerun ./setup.sh --remote." "$(stage2_le_status_path)"
            ;;
    esac
}

stage2_le_gate() {
    local domain="$1"
    local classification copy action

    stage2_le_classify "$domain" >/dev/null || true
    classification="$STAGE2_LE_CLASSIFICATION"
    if [[ "$classification" == "ready" ]]; then
        _stage2_set_remote_state ready
        _stage2_source_env
        (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only npm,jellyfin,homepage)
        log_ok "Remote access is ready: https://jellyfin.${domain} and https://jellyseerr.${domain}."
        return 0
    fi

    _stage2_set_remote_state failed
    _stage2_source_env
    (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only npm,jellyfin,homepage)

    log_info "Stage 2 LE classification: $classification"
    copy=$(stage2_le_failure_copy "$classification")
    log_warn "$copy"
    log_info "Status snapshot: $(stage2_le_status_path)"

    if ! _stage2_is_interactive; then
        return 1
    fi

    action=$(ui_choose "HTTPS is not ready. Choose how to continue:" \
        "Skip HTTPS for now" \
        "Exit so I can fix and retry" \
        "Abort setup")
    case "$action" in
        "Skip HTTPS for now")
            _stage2_set_remote_state skipped
            _stage2_source_env
            (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only npm,jellyfin,homepage)
            log_skip "$(stage2_skip_summary_copy)"
            return 0
            ;;
        "Exit so I can fix and retry"|"Abort setup"|*)
            return 1
            ;;
    esac
}

run_stage2() {
    if [[ "${DEMO:-0}" == "1" ]]; then
        return 0
    fi

    _stage2_seed_wizard_defaults

    ui_banner "MediaStack -- Stage 2: Remote Access" "HTTPS + WireGuard in 3-5 minutes"

    while true; do
        local offer_action
        # _stage2_offer prints explanatory UI to stderr and only the selected
        # answer to stdout, so command substitution does not swallow the copy.
        offer_action=$(_stage2_offer)
        case "$offer_action" in
            *"Enable remote access")
                ;;
            *"Skip for now")
                _stage2_skip_https
                return 0
                ;;
            *"Tell me more")
                _stage2_tell_me_more
                continue
                ;;
        esac

        if ! _stage2_collect_domain; then
            return 0
        fi
        if ! _stage2_port_gate; then
            return 0
        fi
        _stage2_collect_wireguard
        _stage2_collect_jellyfin_remote_bitrate

        local confirm_action
        _stage2_confirm
        confirm_action="${_STAGE2_CONFIRM_ACTION:-Back}"
        case "$confirm_action" in
            Install)
                _stage2_install
                return $?
                ;;
            Back)
                continue
                ;;
            "Skip Stage 2")
                _stage2_skip_https
                return 0
                ;;
        esac
    done
}

_stage2_offer() {
    {
        ui_section 1 6 "Remote access"
        ui_box "Remote access is not configured yet" \
            "Remote access lets you use Jellyfin at https://jellyfin.<your-domain>." \
            "It also gives you a WireGuard VPN for admin access." \
            "You need a domain and router forwards for TCP 80 and 443." \
            "You can skip this and keep LAN access."
    } >&2
    ui_choose "Set up remote access now?" \
        "Enable remote access" \
        "Skip for now" \
        "Tell me more"
}

_stage2_tell_me_more() {
    ui_section 1 6 "Remote access"
    ui_log info "You will need a domain, DNS records, and router forwards for TCP 80 and 443."
    ui_log info "Dynu is recommended because the free tier supports wildcard records."
    ui_log info "Let's Encrypt proves the domain reaches this box before HTTPS is enabled."
    ui_log info "WireGuard gives you a VPN for admin pages and fallback access."
    ui_log skip "Skipping is safe. Your LAN stack still works, and ./setup.sh --remote retries later."
}

_stage2_dns_status_message() {
    local status="$1"
    case "$status" in
        ok)
            ui_log ok "DNS matches this public IP for Jellyfin and Jellyseerr."
            ;;
        cloudflare)
            ui_log warn "Cloudflare proxy is on. Set jellyfin.${_WIZ_DOMAIN} and jellyseerr.${_WIZ_DOMAIN} to DNS-only, then retry."
            ;;
        apex-only)
            ui_log warn "Only the apex domain resolves. Add wildcard *.${_WIZ_DOMAIN} or separate records for jellyfin.${_WIZ_DOMAIN} and jellyseerr.${_WIZ_DOMAIN}."
            ;;
        no-a)
            ui_log warn "No A records found for jellyfin.${_WIZ_DOMAIN} and jellyseerr.${_WIZ_DOMAIN}."
            ;;
        mismatch:*)
            ui_log warn "DNS resolves to ${status#mismatch:}, not this public IP (${_NET_PUBLIC_IP:-unknown})."
            ;;
        *)
            ui_log warn "DNS could not be verified. Fix the record below, then retry or skip HTTPS for now."
            ;;
    esac
}

_stage2_collect_domain() {
    ui_section 2 6 "Domain + DDNS"

    # Walk a non-technical user through getting a free hostname if they
    # don't already have a domain. Dynu is what we recommend because:
    #   - free tier supports wildcards (jellyfin.X + jellyseerr.X)
    #   - same account doubles as the DDNS provider we already integrate
    #   - no DNS provider lock-in or paid tier required for home use
    # If they already have a domain (Cloudflare-managed personal domain,
    # NoIP, DuckDNS, etc.) they skip this and enter it directly.
    local has_domain
    has_domain=$(ui_choose "Do you already have a domain name (or a free DDNS hostname like yourname.mywire.org)?" \
        "Yes — I have one" \
        "No — walk me through getting a free one (Dynu)")
    local came_from_dynu_walkthrough="false"
    if [[ "$has_domain" == "No"* ]]; then
        came_from_dynu_walkthrough="true"
        cat <<'COPY'

  ──────────────────────────────────────────────────────────────────────
   Get a free hostname from Dynu (takes ~3 minutes, no credit card)
  ──────────────────────────────────────────────────────────────────────

   1. Open https://www.dynu.com/en-US in your browser
   2. Click "Sign Up" (top-right) and create a free account
        — pick a USERNAME and PASSWORD; note them, you'll need both
   3. After login: Control Panel → "DDNS Services" → "Add New Service"
   4. Pick a hostname:  e.g.  yourname.mywire.org
        (mywire.org / freeddns.org / loseyourip.com — any work)
   5. Save. That's it — no other settings to configure on Dynu's side.

   You will need three values:
        • the full hostname           (e.g.  yourname.mywire.org)
        • your Dynu account USERNAME  (the one you signed up with)
        • your Dynu account PASSWORD  (the one you signed up with)

   When you have those three values, come back to this terminal.

   (Optional security upgrade: Dynu lets you set a separate "IP Update
    Password" for the API — that also works here, but isn't required.)

  ──────────────────────────────────────────────────────────────────────

COPY
        if ! ui_confirm "Done? Ready to enter your hostname + Dynu credentials?" "yes"; then
            ui_log info "No problem — re-run ./setup.sh --remote when you're ready."
            _stage2_skip_https
            return 1
        fi
    fi

    _WIZ_DOMAIN=$(ui_input_validated \
        "Your hostname (e.g. yourname.mywire.org)" \
        "${_WIZ_DOMAIN:-${_WIZ_PREV_DOMAIN:-}}" \
        validate_domain_name)

    if [[ -z "${_NET_PUBLIC_IP:-}" ]]; then
        net_detect_public_ip >/dev/null 2>&1 || true
    fi

    # Always offer/collect DDNS creds before checking DNS. Previously this
    # was deferred until DNS resolved badly — but on a fresh install where
    # DNS already happens to point at the right IP (e.g. a previous VM at
    # this hostname is still alive, or the user pushed Dynu manually
    # earlier), the prompt was skipped, leaving config/ddns-updater/
    # config.json empty and ddns-updater dead. Asking up-front lets verified
    # creds land regardless of DNS state, but bad preflight results must not
    # be treated as a successful DDNS push.
    # Track whether DDNS was just (re-)collected. After a fresh push,
    # public DNS typically takes 30-60s to converge, so auto-retry instead
    # of asking the user to mash "Retry" through every iteration.
    local ddns_pushed="false"
    if _stage2_offer_ddns "$came_from_dynu_walkthrough"; then
        ddns_pushed="true"
    fi

    local dns_status action retry_count=0
    while true; do
        dns_status=$(stage2_dns_classify "$_WIZ_DOMAIN" "${_NET_PUBLIC_IP:-}") || true
        _stage2_dns_status_message "$dns_status"
        if [[ "$dns_status" == "ok" ]]; then
            break
        fi

        # Public DNS resolvers cache stale records for the previous TTL,
        # so even after Dynu's authoritative update, dig may keep returning
        # the old IP for up to a few minutes. Auto-retry without nagging
        # the user; only fall through to the manual menu after 2 minutes.
        if [[ "$ddns_pushed" == "true" && $retry_count -lt 12 ]]; then
            retry_count=$((retry_count + 1))
            ui_log info "Waiting 10s for Dynu propagation (attempt ${retry_count}/12)..."
            sleep 10
            continue
        fi

        action=$(ui_choose "Remote access could not be verified. Fix DNS, then choose:" \
            "Retry DNS check" \
            "Re-enter Dynu credentials" \
            "Skip HTTPS for now")
        case "$action" in
            "Retry DNS check") continue ;;
            "Re-enter Dynu credentials")
                if _stage2_offer_ddns "true"; then   # skip "Use Dynu?" prompt; go straight to creds
                    ddns_pushed="true"
                else
                    ddns_pushed="false"
                fi
                retry_count=0
                continue
                ;;
            "Skip HTTPS for now")
                _stage2_skip_https
                return 1
                ;;
        esac
    done
}

_stage2_offer_ddns() {
    # When the user came from the Dynu walkthrough, skip the redundant
    # "Use Dynu?" question — they already set up Dynu, so go straight to
    # collecting credentials.
    local skip_offer="${1:-false}"
    if [[ "$skip_offer" != "true" ]]; then
        ui_log info "Dynu is recommended because the free tier supports wildcard records."
        if ! ui_confirm "Use Dynu DDNS for this domain?" "no"; then
            _WIZ_DDNS_PREFLIGHT_OK="false"
            return 1
        fi
    fi

    local ddns_user ddns_pw
    ddns_user=$(ui_input_validated "Dynu account username" "${_WIZ_DDNS_USER:-}" validate_ddns_username)
    ddns_pw=$(_stage2_password_validated "Dynu account password (or IP Update Password if you set one)" "${_WIZ_DDNS_PW:-}" validate_ddns_password)

    local dynu_state
    dynu_state=$(stage2_dynu_preflight "$_WIZ_DOMAIN" "$ddns_user" "$ddns_pw") || true
    if [[ "$dynu_state" == "ok" ]]; then
        # The preflight is a real call to https://api.dynu.com/nic/update —
        # Dynu returned `good` or `nochg`, which means the credentials are
        # valid AND your current public IP has been pushed to the hostname.
        _WIZ_DDNS_USER="$ddns_user"
        _WIZ_DDNS_PW="$ddns_pw"
        _WIZ_DDNS_PREFLIGHT_OK="true"
        _WIZ_DDNS_INVALIDATED="false"
        ui_log ok "Verified against Dynu's API: credentials valid + current IP pushed."
        return 0
    elif [[ "$dynu_state" == "badauth" ]]; then
        _WIZ_DDNS_USER=""
        _WIZ_DDNS_PW=""
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        ui_log warn "Dynu rejected the login: $(stage2_dynu_validate_response badauth message). Re-enter when you 'Retry DNS check' below."
    else
        _WIZ_DDNS_USER=""
        _WIZ_DDNS_PW=""
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        ui_log warn "Dynu preflight returned ${dynu_state}; you can retry DNS after fixing it."
    fi
    return 1
}

_stage2_password_validated() {
    local prompt="$1"
    local default="$2"
    local validator_fn="$3"
    local result

    while true; do
        result=$(ui_password "$prompt" "$default")
        if "$validator_fn" "$result"; then
            printf '%s\n' "$result"
            return 0
        fi
    done
}

_stage2_port_gate() {
    ui_section 3 6 "Router ports"
    ui_log info "This check runs from your home network. If your router does not support hairpin NAT, closed results can be ambiguous."

    # Auto-retry the port probe a few times before bothering the user.
    # nc -z is a single SYN packet with a 5s timeout — perfectly fine to
    # randomly fail under transient conditions (NPM warming up after start,
    # NAT cache flush, dropped SYN, GCP route table churn). 3 attempts with
    # a 5s gap absorbs nearly all spurious "closed" reports without making
    # a real misconfig wait too long for the manual menu.
    local port_state failure action attempt
    while true; do
        for attempt in 1 2 3; do
            port_state=$(stage2_check_http_ports)
            if [[ "$port_state" == "ok" ]]; then
                if (( attempt == 1 )); then
                    ui_log ok "TCP ports 80 and 443 appear reachable from this host."
                else
                    ui_log ok "TCP ports 80 and 443 appear reachable (took ${attempt} attempts — first was likely transient)."
                fi
                return 0
            fi
            if (( attempt < 3 )); then
                ui_log info "Port probe ${attempt}/3 returned ${port_state} — retrying in 5s..."
                sleep 5
            fi
        done

        failure=$(stage2_classify_port_failure "${_NET_PUBLIC_IP:-}" "ok" "$port_state")
        case "$failure" in
            cgnat) ui_log warn "Your public IP looks like CGNAT. Ask your ISP for a public IPv4 or use VPN-only access." ;;
            cloudflare) ui_log warn "Cloudflare proxy is on. Set the records to DNS-only, then retry." ;;
            wrong-lan-target) ui_log warn "DNS may point at the wrong router or LAN target. Check the forwarding destination." ;;
            carrier-block) ui_log warn "Your ISP or router may be blocking TCP 80 or 443." ;;
            aaaa-mismatch) ui_log warn "IPv6/AAAA may point somewhere different from your IPv4 records." ;;
            probe-unavailable) ui_log warn "External port probe services are unavailable or blocked from this network. You can continue after manually verifying TCP 80 and 443 are forwarded to this server." ;;
            *) ui_log warn "TCP port check returned ${port_state}. Router forwarding may still be needed." ;;
        esac

        local default_index=1
        if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
            case "$failure" in
                probe-unavailable) default_index=2 ;;
                *) default_index=3 ;;
            esac
        fi

        action=$(UI_CHOOSE_DEFAULT_INDEX="$default_index" ui_choose "Fix the router forwarding, then choose:" \
            "Retry" \
            "Continue with manual verification" \
            "Skip HTTPS for now")
        case "$action" in
            Retry) continue ;;
            "Continue with manual verification")
                ui_log warn "Continuing will make one Let's Encrypt attempt. If your router or DNS is still wrong, the certificate request may fail."
                return 0
                ;;
            "Skip HTTPS for now")
                _stage2_skip_https
                return 1
                ;;
        esac
    done
}

_stage2_collect_wireguard() {
    ui_section 4 6 "WireGuard"

    # WireGuard endpoint = the same hostname users already entered for
    # HTTPS in [2/6] Domain + DDNS. Asking again is friction for zero
    # value (one DDNS hostname covers both HTTPS and the VPN endpoint).
    # Power users who want a separate WG hostname can override WG_HOST
    # in .env after install.
    _WIZ_WG_HOST="${_WIZ_DOMAIN:-$_WIZ_WG_HOST}"
    ui_log info "WireGuard endpoint: ${_WIZ_WG_HOST} (using your domain — override WG_HOST in .env if you need a different one)."

    _WIZ_WG_PORT=$(ui_input_validated \
        "WireGuard UDP port" \
        "${_WIZ_WG_PORT:-51820}" \
        validate_wireguard_port)

    # Access tier replaces the old "tunnel mode" prompt. Three options surface
    # for the initial peer: Full LAN (owner), Server (co-admin, includes SSH /
    # host services), Containers (trusted household, MediaStack apps only).
    # Streaming-only is a README template for friends/kids — not a sensible
    # initial-peer choice because the owner would lock themselves out. Full
    # tunnel is an env-only override (see docs/design/architecture.md).
    local tier_choice tier
    local tier_default_index=1
    case "$_WIZ_WG_ACCESS_TIER" in
        server) tier_default_index=2 ;;
        containers) tier_default_index=3 ;;
    esac
    tier_choice=$(UI_CHOOSE_DEFAULT_INDEX="$tier_default_index" ui_choose \
        "VPN access level for your admin device" \
        "Full LAN (recommended) — reach every device on your home network" \
        "Server only — reach this MediaStack box (all ports, including SSH)" \
        "Containers only — reach MediaStack apps (no host services or other LAN devices)")
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
        ui_log warn "HOST_ADDRESS is '$_WIZ_WG_SERVER_LAN_IP' — VPN peers will not be able to reach this box until you set a real LAN IP in .env."
    fi

    # Full LAN tier needs the actual LAN CIDR; auto-detect and let the user
    # confirm or override. Other tiers route only the server IP /32, so no
    # LAN CIDR question.
    if [[ "$tier" == "full-lan" ]]; then
        local detected
        detected=$(detect_lan_cidr 2>/dev/null || true)
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
    env_lines=$(stage2_wireguard_access_tier_env "$tier" "$_WIZ_WG_LAN_CIDR" "$_WIZ_WG_SERVER_LAN_IP")
    while IFS='=' read -r key raw; do
        raw="${raw#\'}"
        raw="${raw%\'}"
        case "$key" in
            WG_INIT_ALLOWED_IPS) _WIZ_WG_INIT_ALLOWED_IPS="$raw" ;;
            WG_PER_CLIENT_FIREWALL) _WIZ_WG_PER_CLIENT_FIREWALL="$raw" ;;
        esac
    done <<< "$env_lines"

    ui_log info "WireGuard admin login: ${_WIZ_ADMIN_USER} / your admin password."
    case "$tier" in
        full-lan)
            ui_log info "Access level: Full LAN. Initial peer reaches ${_WIZ_WG_LAN_CIDR}. Add family peers in the wg-easy UI using the README templates."
            ;;
        server)
            ui_log info "Access level: Server. Initial peer reaches ${_WIZ_WG_SERVER_LAN_IP} (all ports, including SSH)."
            ;;
        containers)
            ui_log info "Access level: Containers. Initial peer reaches MediaStack app ports on ${_WIZ_WG_SERVER_LAN_IP}. Host services (SSH, SMB) are blocked."
            ;;
    esac
    _WIZ_WG_INIT_PASSWORD="${_WIZ_ADMIN_PW}"
}

_stage2_collect_jellyfin_remote_bitrate() {
    ui_section 5 6 "Jellyfin remote streaming"

    # Jellyfin's RemoteClientBitrateLimit is a PER-STREAM cap (not a global
    # aggregate). We surface a reference table so the user can pick their
    # own value rather than accept/reject a single recommendation. The
    # table covers (a) typical per-stream Mbps budgets at common quality
    # levels, and (b) per-viewer budget across plausible concurrent-viewer
    # counts, computed at 70% of detected upload bandwidth.
    local upload_mbps="${_NET_UL_MBPS:-}"
    if [[ -z "$upload_mbps" || ! "$upload_mbps" =~ ^[0-9]+$ ]]; then
        upload_mbps=$(ui_input "Your upload bandwidth in Mbps (used for the recommendation table)" "100")
        if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]]; then
            ui_log warn "Couldn't parse upload bandwidth; leaving Jellyfin remote bitrate unlimited."
            _WIZ_JELLYFIN_BITRATE=0
            return 0
        fi
    else
        ui_log info "Detected upload bandwidth: ${upload_mbps} Mbps."
    fi

    echo
    echo "  Per-stream bitrate by quality (Jellyfin transcodes to fit):"
    echo "    720p HD            3-7 Mbps"
    echo "    1080p HD           5-15 Mbps"
    echo "    4K HEVC (H.265)    25-40 Mbps"
    echo "    4K H.264           50-100 Mbps"
    echo
    echo "  Recommended per-viewer cap (45% of upload, capped to keep your home"
    echo "  network responsive — Jellyfin won't try to use the whole line):"
    # Compute table values + suggested-default in one python pass.
    # Heuristic: usable = upload * 0.45; raw = usable / viewers; clamp [2, max_cap]
    #   max_cap (1-2 viewers): 8 if upload>=250, 7 if >=100, else 6
    #   max_cap (3-4 viewers): 7 if upload>=500, else 6
    #   max_cap (5+ viewers):  6 if upload>=500, 5 if >=250, else 4
    # 1-2 col borderline: fall back to "1 viewer alone" (floor for safety)
    local suggested_default
    suggested_default=$(UPLOAD="$upload_mbps" python3 <<'PY'
import math, os, sys

def compute_cell(upload, viewers):
    usable = upload * 0.45
    raw = usable / viewers
    if viewers <= 2:
        max_cap = 8 if upload >= 250 else (7 if upload >= 100 else 6)
    elif viewers <= 4:
        max_cap = 7 if upload >= 500 else 6
    else:
        max_cap = 6 if upload >= 500 else (5 if upload >= 250 else 4)
    if viewers == 2 and raw < 3:
        solo = usable
        if solo >= 2:
            return f"{int(min(max_cap, solo))} (1 viewer)"
        return "—"
    if raw < 1.5:
        return "—"
    return str(max(2, min(max_cap, math.ceil(raw))))

upload_speeds = [10, 20, 40, 100, 250, 500]
columns = [(2, "1-2 viewers"), (4, "3-4 viewers"), (6, "5+ viewers")]
print("  ┌──────────┬──────────────┬─────────────┬────────────┐", file=sys.stderr)
print("  │  Upload  │ {:<12s} │ {:<11s} │ {:<10s} │".format(*[c[1] for c in columns]), file=sys.stderr)
print("  ├──────────┼──────────────┼─────────────┼────────────┤", file=sys.stderr)
for up in upload_speeds:
    cells = [compute_cell(up, c[0]) for c in columns]
    print("  │ {:<8s} │ {:<12s} │ {:<11s} │ {:<10s} │".format(f"{up} Mbps", *cells), file=sys.stderr)
print("  └──────────┴──────────────┴─────────────┴────────────┘", file=sys.stderr)

# Default = recommendation for user's upload at 4 viewers (most common case).
# Strip the "(1 viewer)" annotation if present and fall back to "0" on "—".
default_cell = compute_cell(int(os.environ["UPLOAD"]), 4)
if default_cell == "—":
    default_cell = compute_cell(int(os.environ["UPLOAD"]), 2)
    if default_cell == "—" or "(1 viewer)" in default_cell:
        default_cell = "0"
    else:
        default_cell = default_cell.split()[0]
else:
    default_cell = default_cell.split()[0]
print(default_cell)
PY
)
    echo

    local custom
    custom=$(ui_input "Per-viewer cap in Mbps (decimals OK, e.g. 3.5 or 7.0; 0 = unlimited)" "$suggested_default")
    if [[ "$custom" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        _WIZ_JELLYFIN_BITRATE="$custom"
    else
        ui_log warn "Couldn't parse '${custom}' as a number — leaving unlimited."
        _WIZ_JELLYFIN_BITRATE=0
    fi
}

_stage2_confirm() {
    ui_section 6 6 "Confirm install"
    ui_box "Stage 2: Install Plan" \
        "$(ui_kv 'Domain' "$_WIZ_DOMAIN")" \
        "$(ui_kv 'HTTPS' "jellyfin.${_WIZ_DOMAIN}, jellyseerr.${_WIZ_DOMAIN}")" \
        "$(ui_kv 'WireGuard' "${_WIZ_WG_HOST}:${_WIZ_WG_PORT}")" \
        "$(ui_kv 'Remote streaming cap' "$( [[ "${_WIZ_JELLYFIN_BITRATE:-0}" == "0" ]] && echo 'unlimited' || echo "${_WIZ_JELLYFIN_BITRATE} Mbps/viewer" )")" \
        "$(ui_kv 'Access' 'LAN remains available if HTTPS fails')"

    _STAGE2_CONFIRM_ACTION=$(ui_choose "Proceed with Stage 2 installation?" \
        "Install" \
        "Back" \
        "Skip Stage 2")
}

_stage2_skip_https() {
    _stage2_seed_wizard_defaults
    _WIZ_REMOTE_WEB_STATE="skipped"
    write_env || return 1
    _stage2_preserve_stage1_marker
    ui_log skip "$(stage2_skip_summary_copy)"
}

_stage2_install() {
    log_info "Stage 2: installing remote access..."

    _stage2_seed_wizard_defaults
    _WIZ_REMOTE_WEB_STATE="unchecked"
    write_env || return 1
    _stage2_preserve_stage1_marker

    _stage2_source_env

    # Apply chosen Jellyfin remote-streaming cap to config.yml so the
    # post-LE-gate `configure.sh --only npm,jellyfin,homepage` run picks
    # it up via configure_jellyfin_streaming. Skip when no value was set
    # (e.g. wizard not run interactively, or user kept the default 0).
    if [[ -n "${_WIZ_JELLYFIN_BITRATE:-}" ]]; then
        sed -i "s/^  remote_bitrate_limit:.*/  remote_bitrate_limit: ${_WIZ_JELLYFIN_BITRATE}    # Mbps per remote viewer (0 = unlimited). Set by Stage 2 wizard./" "$SCRIPT_DIR/config.yml"
        log_info "Jellyfin remote streaming cap: $( [[ "$_WIZ_JELLYFIN_BITRATE" == "0" ]] && echo unlimited || echo "${_WIZ_JELLYFIN_BITRATE} Mbps per viewer" )"
    fi

    echo ""
    pull_images

    echo ""
    start_stack
    wait_all_healthy

    echo ""
    log_info "Running remote-access auto-configuration..."
    local remote_config_rc=0
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=1 ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    elif type ui_spin >/dev/null 2>&1; then
        ui_spin "Requesting Let's Encrypt certificates..." \
            bash -c "cd '$SCRIPT_DIR' && MEDIASTACK_NPM_ATTEMPT_REMOTE=1 ./scripts/configure.sh --only npm,ddns-updater,wireguard" || remote_config_rc=$?
    else
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=1 ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    fi
    if (( remote_config_rc != 0 )); then
        log_warn "Remote-access auto-configuration returned a warning or error; checking HTTPS postconditions anyway."
    fi

    stage2_le_gate "$_WIZ_DOMAIN"
    local gate_rc=$?

    print_access_info
    return "$gate_rc"
}

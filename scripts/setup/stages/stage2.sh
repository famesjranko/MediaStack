# =============================================================================
# MediaStack Setup -- Stage 2 controller (Remote Access)
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

source "$SCRIPT_DIR/scripts/lib/npm_remote.sh"
source "$SCRIPT_DIR/scripts/lib/ddns_providers.sh"

: "${STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS:=12}"
: "${STAGE2_DNS_PROPAGATION_SLEEP_SECONDS:=10}"
: "${STAGE2_PORT_PROBE_MAX_ATTEMPTS:=3}"
: "${STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS:=5}"
readonly STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS STAGE2_DNS_PROPAGATION_SLEEP_SECONDS
readonly STAGE2_PORT_PROBE_MAX_ATTEMPTS STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS

# DDNS credential fields for the chosen provider (name -> value). MUST be a real
# associative array: assigning arr[key]=val to an undeclared name creates a plain
# indexed array (key -> arithmetic 0) and silently drops every field. Declared
# here (the always-sourced module) so both production and the flow units get an
# assoc; `declare -gA` on an existing assoc preserves its contents (idempotent).
declare -gA _WIZ_DDNS_FIELDS

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

_stage2_preserve_stage1_marker() {
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

_stage2_le_ready_hosts() {
    local domain="$1" api="${2:-$(service_local_url npm)/api}"
    local token hosts fqdn cert_id host_json host_id host_cert_id host_enabled ready=()
    token=$(npm_remote_token "$api") || return 1
    [[ -z "$token" ]] && return 1
    hosts=$(curl -sf --max-time 30 -H "Authorization: Bearer $token" \
        "$api/nginx/proxy-hosts" 2>/dev/null) || return 1

    for fqdn in "jellyfin.$domain" "seerr.$domain"; do
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
    for fqdn in "jellyfin.$domain" "seerr.$domain"; do
        if grep -qx "$fqdn" <<<"$ready_hosts"; then
            ((ready_count += 1))
        else
            failed+=("$fqdn")
        fi
    done
    STAGE2_LE_FAILED_HOSTS="$(
        IFS=', '
        echo "${failed[*]}"
    )"

    if ((ready_count == 2)); then
        STAGE2_LE_CLASSIFICATION="ready"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 0
    fi
    if ((ready_count == 1)); then
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
            printf 'Partial HTTPS setup: ready=%s; still pending=%s. Wait or fix the issue, then choose Features & settings -> Add remote access from the menu.' \
                "${STAGE2_LE_READY_HOSTS:-none}" "${STAGE2_LE_FAILED_HOSTS:-unknown}"
            ;;
        transient)
            printf "Let's Encrypt partly reached this server but one validation path failed. Wait a few minutes, then choose Features & settings -> Add remote access from the menu."
            ;;
        config-dns)
            printf "DNS does not point both Jellyfin and Seerr hostnames at this box. Fix DNS, then choose Features & settings -> Add remote access from the menu."
            ;;
        config-port)
            printf "Let's Encrypt could not reach TCP port 80 on this box. Fix router/firewall forwarding, then choose Features & settings -> Add remote access from the menu."
            ;;
        rate-limited)
            printf "Let's Encrypt rate-limited this hostname or account. Wait for the limit to clear, then choose Features & settings -> Add remote access from the menu."
            ;;
        npm-unhealthy)
            printf "Nginx Proxy Manager's cert/proxy state is unhealthy. Choose Features & settings -> Add remote access again from the menu; it will heal NPM first, then attempt HTTPS again."
            ;;
        unknown | *)
            printf "HTTPS setup did not complete and the cause could not be classified. Check %s and NPM logs, then choose Features & settings -> Add remote access from the menu." "$(stage2_le_status_path)"
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
        log_ok "Remote access is ready: https://jellyfin.${domain} and https://seerr.${domain}."
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
        "Exit so I can fix and retry" | "Abort setup" | *)
            return 1
            ;;
    esac
}

run_stage2() {
    seed_root_config # ensure live config.yml exists before the bitrate write (env_gen.sh)
    if [[ "${DEMO:-0}" == "1" ]]; then
        return 0
    fi

    _stage2_seed_wizard_defaults

    ui_banner "MediaStack - Remote Access" "HTTPS + WireGuard in a few minutes (longer on first DNS setup)"

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
            "Skip remote access")
                _stage2_skip_https
                return 0
                ;;
        esac
    done
}

# Trim leading/trailing whitespace (e.g. from a pasted credential).
_stage2_trim_ws() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Title-case display name for a provider key (the registry key is lowercase, but
# user-facing copy reads better as "DuckDNS" than "duckdns"). Falls back to the
# raw key for an unknown provider.
_stage2_ddns_provider_label() {
    case "$1" in
        dynu) printf 'Dynu' ;;
        duckdns) printf 'DuckDNS' ;;
        desec) printf 'deSEC' ;;
        dynv6) printf 'dynv6' ;;
        cloudflare) printf 'Cloudflare' ;;
        porkbun) printf 'Porkbun' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Human prompt copy for a provider's credential field. Dynu keeps its exact
# PTY-tested strings; other providers get generic per-field copy.
_stage2_ddns_field_prompt() {
    local provider="$1" name="$2" label
    if [[ "$provider" == "dynu" ]]; then
        case "$name" in
            # Dynu no longer collects a username (Dynu ignores it; the
            # placeholder is auto-filled in ddns_providers.sh). Password only.
            password)
                printf 'Dynu account password (or IP Update Password if you set one)'
                return
                ;;
        esac
    fi
    label=$(_stage2_ddns_provider_label "$provider")
    case "$name" in
        token)
            # DuckDNS tokens are account UUIDs; hint the shape here (a strict
            # input validator would trap a user who can't produce one — the verify
            # step rejects a bad token and the retry menu is the escape).
            if [[ "$provider" == "duckdns" ]]; then
                printf '%s API token (the UUID from your DuckDNS account page)' "$label"
            else
                printf '%s API token' "$label"
            fi
            ;;
        api_key) printf '%s API key' "$label" ;;
        secret_api_key) printf '%s secret API key' "$label" ;;
        zone_identifier) printf '%s Zone ID (32 hex chars, from the domain Overview page)' "$label" ;;
        username) printf '%s account username' "$label" ;;
        password) printf '%s account password' "$label" ;;
        *) printf '%s %s' "$label" "$name" ;;
    esac
}

# True when DDNS is configured but the ephemeral verify did NOT accept the
# credentials this session — PREFLIGHT_OK is not "true" (a degrade, or verify not
# run). The caller uses this to skip the DNS-propagation loop and the live Let's
# Encrypt attempt, landing at the honest REMOTE_WEB_STATE=unchecked terminal
# instead of nagging or gambling a cert on an IP that isn't live yet. A verify
# ACCEPT for ANY provider sets PREFLIGHT_OK=true (and a real push already
# happened), so this is false and the caller proceeds to the DNS loop + LE gate.
_stage2_ddns_unverified() {
    [[ "${_WIZ_USES_DDNS:-false}" == "true" &&
        -n "${_WIZ_DDNS_PROVIDER:-}" &&
        "${_WIZ_DDNS_PREFLIGHT_OK:-false}" != "true" ]]
}

# Repopulate _WIZ_DDNS_FIELDS from the persisted config.json on a re-run so the
# field-loop prompts pre-fill (press Enter to keep) — the DDNS analogue of the
# admin _WIZ_PREV_* recall. Only fills when the assoc is empty; never fatal.
# ponytail: config.json is chmod-600 owned by the ddns-updater uid (1000 by
# default). On the common single-user box PUID==$(id -u)==1000 so a plain read
# works; a non-1000 invoking uid falls back to non-interactive `sudo -n cat`
# (never prompts). If both fail we degrade to empty and the user re-types —
# recall is convenience, not correctness.
_stage2_recall_ddns_from_config() {
    # ${arr[*]+x} is the set -u-safe "assoc has >=1 element" test: ${#arr[@]} on
    # an empty declared associative array trips `unbound variable` under nounset.
    [[ -n "${_WIZ_DDNS_FIELDS[*]+x}" ]] && return 0
    local provider="${_WIZ_DDNS_PROVIDER:-}"
    [[ -n "$provider" ]] || return 0
    local config="$SCRIPT_DIR/config/ddns-updater/config.json"
    [[ -f "$config" ]] || return 0

    local json field_names
    json=$(cat "$config" 2>/dev/null) || json=""
    [[ -n "$json" ]] || json=$(sudo -n cat "$config" 2>/dev/null || true)
    [[ -n "$json" ]] || return 0
    field_names=$(ddns_provider_fields "$provider" 2>/dev/null) || return 0
    # Strip the :validator half; keep just the field names for the python filter.
    local spec names=""
    for spec in $field_names; do names+=" ${spec%%:*}"; done

    local name val
    while IFS=$'\t' read -r name val; do
        [[ -n "$name" && -n "$val" ]] && _WIZ_DDNS_FIELDS["$name"]="$val"
    done < <(DDNS_JSON="$json" DDNS_NAMES="$names" python3 -c '
import os, json
try:
    s = json.loads(os.environ["DDNS_JSON"])["settings"][0]
except Exception:
    raise SystemExit(0)
for name in os.environ["DDNS_NAMES"].split():
    v = s.get(name)
    if isinstance(v, str) and v:
        print(f"{name}\t{v}")
')
    return 0
}

# The remote-access offer is a yes/no gate, not a data-collection step, so it
# carries no [n/n] counter; the real steps below are numbered [1/5]..[5/5].
_stage2_offer() {
    {
        ui_box "Remote access is not configured yet" \
            "Remote access lets you use Jellyfin at https://jellyfin.media.yourdomain.com." \
            "It also gives you a WireGuard VPN for admin access." \
            "You need a domain and router forwards for TCP 80 and 443." \
            "You can skip this and keep LAN access."
    } >&2
    UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Set up remote access now?" \
        "Enable remote access" \
        "Skip for now" \
        "Tell me more"
}

# Comma-join the display names for a registry category (free | byo) so copy can
# name the provider sets from the registry, not a second hardcoded list.
_stage2_provider_list() {
    local out="" n
    while IFS= read -r n; do out+="${out:+, }$n"; done < <(ddns_category_names "$1")
    printf '%s' "$out"
}

_stage2_tell_me_more() {
    ui_log info "You will need a domain, DNS records, and router forwards for TCP 80 and 443."
    ui_log info "No domain yet? Free-hostname providers ($(_stage2_provider_list free)) give you one; you can also bring your own ($(_stage2_provider_list byo))."
    ui_log info "Let's Encrypt proves the domain reaches this box before HTTPS is enabled."
    ui_log info "WireGuard gives you a VPN for admin pages and fallback access."
    ui_log skip "Skipping is safe. Your LAN stack still works, and you can add remote access later from Features & settings -> Add remote access."
}

_stage2_dns_status_message() {
    local status="$1"
    case "$status" in
        ok)
            ui_log ok "DNS matches this public IP for Jellyfin and Seerr."
            ;;
        cloudflare)
            ui_log warn "Cloudflare proxy is on. Set jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} to DNS-only, then retry."
            ;;
        apex-only)
            ui_log warn "Only the apex domain resolves. Add wildcard *.${_WIZ_DOMAIN} or separate records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN}."
            ;;
        no-a)
            ui_log warn "No A records found for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN}."
            ;;
        mismatch:*)
            ui_log warn "DNS resolves to ${status#mismatch:}, not this public IP (${_NET_PUBLIC_IP:-unknown})."
            ;;
        *)
            ui_log warn "DNS could not be verified yet. Fix the A record, then retry or skip HTTPS using the menu below."
            ;;
    esac
}

_stage2_collect_domain() {
    ui_section 1 5 "Domain + dynamic DNS"

    # If the user has no domain yet, don't push a single provider — explain what
    # a domain / DDNS hostname is and route them into the standard 6-provider
    # picker below (skipping the static/dynamic question, since "no domain"
    # implies they need DDNS). Users who already have one skip the copy and enter
    # it directly (Cloudflare-managed personal domain, NoIP, an existing DDNS
    # hostname, etc.).
    local has_domain
    has_domain=$(ui_choose "Do you already have a domain name (or a free DDNS hostname like yourname.mywire.org)?" \
        "Yes - I have one" \
        "No - show me the free options")
    local skip_static_q="false" ddns_pick_mode=""
    if [[ "$has_domain" == "No"* ]]; then
        # Reach the provider picker below without the static/dynamic gate, and
        # don't pre-force a provider — the picker offers all free and
        # bring-your-own options and pre-selects any recalled choice.
        skip_static_q="true"
        ddns_pick_mode="pick"
        ui_log info "A domain (or free DDNS hostname) is what jellyfin.<domain> and seerr.<domain> resolve to, so you can reach them from outside your home."
        ui_log info "Free hostname, nothing to buy: $(_stage2_provider_list free). Bring your own domain: $(_stage2_provider_list byo)."
        ui_log info "MediaStack keeps the hostname pointed at your home IP. See the README \"Remote Access\" section for each provider's sign-up steps."
        if ! ui_confirm "Ready to pick a provider and enter your hostname?" "yes"; then
            ui_log info "No problem - your LAN stack still works. Set up a domain or free hostname first, then come back and choose Features & settings -> Add remote access from the menu to finish remote setup."
            _stage2_skip_https
            return 1
        fi
    fi

    # The domain is required for remote HTTPS; make it escapable so a user who
    # answered "Yes - I have one" but can't produce a hostname isn't trapped (an
    # empty submission would otherwise hit ui_input_validated's 5x-empty valve and
    # abort the whole installer). Empty / repeatedly-invalid -> skip remote access.
    local _dom _dom_rc
    _dom=$(_stage2_escapable_input \
        "Your domain or hostname (e.g. media.yourdomain.com)" \
        "${_WIZ_DOMAIN:-${_WIZ_PREV_DOMAIN:-}}" \
        validate_domain_name \
        "Skip remote access for now")
    _dom_rc=$?
    if ((_dom_rc == 130)); then
        return 130
    elif ((_dom_rc != 0)); then
        ui_log info "No domain entered — skipping remote access for now. Your LAN stack still works; add it later from Features & settings -> Add remote access."
        _stage2_skip_https
        return 1
    fi
    _WIZ_DOMAIN="$_dom"

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
    if _stage2_offer_ddns "$skip_static_q" "$ddns_pick_mode"; then
        if _stage2_ddns_unverified; then
            # The ephemeral verify degraded (docker/image unavailable): shape-valid
            # creds are saved but nothing was pushed synchronously, so the
            # DNS-propagation loop below would only nag. Land at the honest
            # "unchecked" terminal and proceed to install: the stack comes up,
            # ddns-updater pushes the IP, and HTTPS is completed via day-2 "Add
            # remote access" once DNS resolves.
            ui_log info "DDNS configured for $(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER"); it will update ${_WIZ_DOMAIN} once the stack starts. Verify HTTPS later via Features & settings -> Add remote access."
            return 0
        fi
        # Verify accepted: the ephemeral container already pushed the current IP,
        # so wait for public DNS to converge and attempt Let's Encrypt.
        ddns_pushed="true"
    fi

    local dns_status action retry_count=0 reject_blocked
    while true; do
        reject_blocked=false
        dns_status=$(stage2_dns_classify "$_WIZ_DOMAIN" "${_NET_PUBLIC_IP:-}") || true
        if [[ "$dns_status" == "ok" ]]; then
            # Don't declare success on a coincidental DNS-ok (e.g. a re-run where the
            # record already points here) if DDNS is wanted but its credentials were
            # just rejected and cleared — breaking here would leave ddns-updater
            # unconfigured and remote access would break on the next IP change. Fall
            # through to the menu so the user re-enters (or explicitly skips).
            # ${arr[*]+x} is the set -u-safe "assoc has >=1 element" test.
            if [[ "${_WIZ_USES_DDNS:-true}" != "true" || -n "${_WIZ_DDNS_FIELDS[*]+x}" ]]; then
                _stage2_dns_status_message ok
                break
            fi
            # Reject-blocked: DNS resolves but the login wasn't accepted. Don't print
            # the "DNS matches" success line here — it would contradict the warning.
            reject_blocked=true
            ui_log warn "DNS resolves, but the login above wasn't accepted, so nothing will keep ${_WIZ_DOMAIN} pointed here when your IP changes. Re-enter the login or skip below."
        else
            _stage2_dns_status_message "$dns_status"
        fi

        # Public DNS resolvers cache stale records for the previous TTL, so even
        # after the provider's authoritative update, dig may keep returning the
        # old IP for up to a few minutes. Auto-retry without nagging the user;
        # only fall through to the manual menu after 2 minutes.
        if [[ "$ddns_pushed" == "true" && $retry_count -lt "$STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS" ]]; then
            retry_count=$((retry_count + 1))
            if ((retry_count == 1)); then
                ui_log info "This is normal - public DNS can take 1-2 min to update. Setup is waiting, not stuck."
            fi
            ui_log info "Waiting ${STAGE2_DNS_PROPAGATION_SLEEP_SECONDS}s for DNS propagation (attempt ${retry_count}/${STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS})..."
            sleep "$STAGE2_DNS_PROPAGATION_SLEEP_SECONDS"
            continue
        fi

        # Only offer credential re-entry / provider change when DDNS is actually
        # in use. A static-IP / self-managed-DNS user has no creds to re-enter;
        # they fix their own A record and retry (or skip).
        if [[ "${_WIZ_USES_DDNS:-true}" == "true" ]]; then
            if [[ "$reject_blocked" == "true" ]]; then
                # DNS already resolves, so "Retry DNS check" would only re-hit the
                # same reject warning. Drop it and lead with the productive fix.
                action=$(ui_choose "The login wasn't accepted. What next?" \
                    "Re-enter credentials" \
                    "Change provider" \
                    "Change domain" \
                    "Skip HTTPS for now")
            else
                action=$(ui_choose "Remote access isn't verified yet (see the message above). What next?" \
                    "Retry DNS check" \
                    "Re-enter credentials" \
                    "Change provider" \
                    "Change domain" \
                    "Skip HTTPS for now")
            fi
        else
            action=$(ui_choose "Remote access could not be verified. Fix your DNS A record, then choose:" \
                "Retry DNS check" \
                "Change domain" \
                "Skip HTTPS for now")
        fi
        case "$action" in
            "Retry DNS check") continue ;;
            "Re-enter credentials" | "Change provider" | "Change domain")
                # "Change provider" re-runs the picker; "Change domain" re-collects
                # the hostname (e.g. a DuckDNS user who typed a non-duckdns.org
                # domain, which the verify rejects — or a static-IP user who typo'd
                # it); "Re-enter credentials" keeps both. All skip the static gate.
                if [[ "$action" == "Change domain" ]]; then
                    # Escapable (like the first domain prompt) so a user who can't
                    # produce a valid hostname drops back to this retry menu instead
                    # of the ui_input_validated 5x-empty valve that aborts the whole
                    # installer. Capture into a temp: a skip (rc 2) prints nothing,
                    # which would otherwise blank the valid current domain.
                    # skip_label is "Go back" (not "Skip HTTPS for now") because a
                    # skip here returns to the retry menu — which itself carries a
                    # real "Skip HTTPS for now" — rather than skipping HTTPS directly.
                    local _newdom _newdom_rc
                    _newdom=$(_stage2_escapable_input \
                        "Your domain or hostname (e.g. media.yourdomain.com)" \
                        "${_WIZ_DOMAIN:-}" \
                        validate_domain_name \
                        "Go back")
                    _newdom_rc=$?
                    if ((_newdom_rc == 130)); then
                        return 130
                    elif ((_newdom_rc != 0)); then
                        continue # backed out of the change -> back to the retry menu
                    fi
                    _WIZ_DOMAIN="$_newdom"
                    # A static-IP / self-managed-DNS user has no creds to re-verify;
                    # just re-check DNS with the corrected hostname.
                    if [[ "${_WIZ_USES_DDNS:-true}" != "true" ]]; then
                        retry_count=0
                        continue
                    fi
                fi
                local _reenter_pick=""
                [[ "$action" == "Change provider" ]] && _reenter_pick="pick"
                if _stage2_offer_ddns "true" "$_reenter_pick"; then
                    if _stage2_ddns_unverified; then
                        ui_log info "DDNS configured for $(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER"); it will update ${_WIZ_DOMAIN} once the stack starts. Verify HTTPS later via Features & settings -> Add remote access."
                        return 0
                    fi
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

# Collect a required input (a domain, a DDNS credential) WITH a graceful escape
# hatch. On a TTY, an empty submission on a no-default field OR three consecutive
# validation failures (the natural "I can't do this, get me out" gestures) offers
# a small menu — try again, or <skip_label> — instead of the shared
# ui_input_validated 5x-empty valve, which kills the whole installer, and instead
# of a Ctrl-C-only trap when a bad recalled default keeps re-appearing. Prints the
# trimmed value; returns 0 = collected · 2 = user chose skip · 130 = Ctrl-C.
_stage2_escapable_input() {
    local prompt="$1" def="$2" validator="$3" skip_label="${4:-Skip}"
    # Non-interactive (CI / PTY-less / DEMO): delegate to ui_input_validated for
    # the existing deterministic fallback. Only a real interactive TTY gets the
    # escape menu (an empty submission there is a deliberate "get me out").
    if ! _stage2_is_interactive || [[ "${UI_DEMO:-0}" == "1" ]]; then
        local v rc
        v=$(ui_input_validated "$prompt" "$def" "$validator")
        rc=$?
        ((rc == 0)) && printf '%s' "$(_stage2_trim_ws "$v")"
        return "$rc"
    fi
    local val rejects=0
    while true; do
        val=$(ui_input "$prompt" "$def")
        (($? == 130)) && return 130
        # Trim first so a stray leading/trailing space from a paste is auto-fixed
        # (a trailing space silently fails auth on every provider) rather than
        # rejected — the validator still catches internal spaces and empties.
        val=$(_stage2_trim_ws "$val")
        # Empty with NO default is the escape gesture (a field with a default
        # returns that default on Enter, so it never lands here).
        if [[ -z "$val" && -z "$def" ]]; then
            [[ "$(ui_choose "Nothing entered — what would you like to do?" "Try again" "$skip_label")" == "$skip_label" ]] && return 2
            continue
        fi
        if "$validator" "$val"; then
            printf '%s' "$val"
            return 0
        fi
        # Validator rejected (it warned). After a few tries — a recalled or
        # hand-edited value that can't pass — offer the escape and drop the bad
        # default, so the loop is never a Ctrl-C-only trap.
        rejects=$((rejects + 1))
        if ((rejects >= 3)); then
            [[ "$(ui_choose "That value still isn't valid — what would you like to do?" "Try again" "$skip_label")" == "$skip_label" ]] && return 2
            rejects=0
            def=""
        fi
    done
}

_stage2_offer_ddns() {
    # skip_offer=true skips the static/dynamic question (the walkthrough, or the
    # "Re-enter credentials"/"Change provider" re-entry). pick_mode="pick" forces
    # the provider picker even under skip_offer (the "Change provider" action).
    local skip_offer="${1:-false}"
    local pick_mode="${2:-}"
    if [[ "$skip_offer" != "true" ]]; then
        # DDNS is only needed when the home IP changes. Static-IP users (and
        # users who keep their own DNS updated) skip it entirely. Default to
        # dynamic/DDNS interactively (residential ISPs almost always change IP);
        # in demo/non-interactive mode default to skip so no live provider call
        # fires (mirrors _stage2_port_gate's demo-default idiom below).
        local di=1
        [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]] && di=2
        ui_log info "Most home connections have a changing (dynamic) IP - if unsure, pick the first option."
        local ip_kind
        ip_kind=$(UI_CHOOSE_DEFAULT_INDEX="$di" ui_choose \
            "Does your home internet have a static (unchanging) public IP?" \
            "No - my IP changes (set up DDNS to keep ${_WIZ_DOMAIN} updated)" \
            "Yes - static IP, or I keep my own DNS updated (skip DDNS)")
        if [[ "$ip_kind" == "Yes"* ]]; then
            # Neutralize ALL DDNS recall state. Leaving _WIZ_DDNS_FIELDS populated
            # lets a re-run resurrect it; setting INVALIDATED routes the seed into
            # its clear branch so the user's "skip DDNS" choice actually sticks.
            _WIZ_USES_DDNS="false"
            _WIZ_DDNS_PROVIDER=""
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            if [[ -n "${DDNS_PROVIDER:-}" ]]; then
                # A previous install's config.json is preserved (env_gen never
                # leaves a config-less dead remote), so the old updater keeps
                # running — be honest that "skip" doesn't turn it off here.
                ui_log info "Not changing DDNS: your existing $(_stage2_ddns_provider_label "$DDNS_PROVIDER") setup keeps running. (Changing or removing it is coming to Features & settings.)"
            else
                ui_log info "Skipping DDNS. Point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP."
            fi
            return 1
        fi
        pick_mode="pick" # the dynamic-IP path always chooses a provider
    fi
    _WIZ_USES_DDNS="true"

    # Choose the provider, or keep the current one. Under skip_offer the re-enter
    # path ("Re-enter credentials") keeps the already-set _WIZ_DDNS_PROVIDER;
    # "Change provider" forces pick_mode=pick. The :-duckdns fallback is defensive
    # only (that path always has a provider set) and tracks the picker default.
    local prev_provider="${_WIZ_DDNS_PROVIDER:-}"
    if [[ "$pick_mode" == "pick" ]]; then
        _WIZ_DDNS_PROVIDER=$(ddns_provider_pick "${_WIZ_DDNS_PROVIDER:-}")
    else
        _WIZ_DDNS_PROVIDER="${_WIZ_DDNS_PROVIDER:-duckdns}"
    fi

    # Escape hatch: the user chose "Skip for now" in the picker. Neutralize all
    # DDNS state (same as the static-IP path) so a re-run doesn't resurrect it,
    # and return 1 so the caller lands on the skip/retry menu, not the field loop.
    if [[ "$_WIZ_DDNS_PROVIDER" == "${_DDNS_SKIP:-__skip__}" ]]; then
        _WIZ_USES_DDNS="false"
        _WIZ_DDNS_PROVIDER=""
        _WIZ_DDNS_FIELDS=()
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        ui_log info "Skipping DDNS for now. If you're not setting up remote access yet, choose 'Skip HTTPS for now' at the next prompt — otherwise point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP yourself, then retry."
        return 1
    fi

    local fields_spec
    if ! fields_spec=$(ddns_provider_fields "$_WIZ_DDNS_PROVIDER"); then
        ui_log warn "Unknown DDNS provider '${_WIZ_DDNS_PROVIDER}'; skipping DDNS."
        _WIZ_USES_DDNS="false"
        _WIZ_DDNS_PROVIDER=""
        _WIZ_DDNS_FIELDS=()
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        return 1
    fi

    # Snapshot prior field values for prompt defaults, then CLEAR-then-refill
    # _WIZ_DDNS_FIELDS. Only reuse the snapshot when the provider is unchanged —
    # a shared field name (e.g. `token`) must never carry one provider's value
    # into another provider's prompt.
    local -A _prev=()
    local k
    for k in "${!_WIZ_DDNS_FIELDS[@]}"; do _prev["$k"]="${_WIZ_DDNS_FIELDS[$k]}"; done
    _WIZ_DDNS_FIELDS=()
    local carry="false"
    [[ "$_WIZ_DDNS_PROVIDER" == "$prev_provider" ]] && carry="true"

    # Collect each field VISIBLE (a long pasted token is verifiable on screen)
    # and whitespace-trimmed (a stray trailing space silently fails auth on every
    # provider), through the escapable collector so a user who picked a provider
    # they aren't ready for can back out gracefully instead of being trapped.
    local spec name validator def val rc
    for spec in $fields_spec; do
        name="${spec%%:*}"
        validator="${spec#*:}"
        def=""
        [[ "$carry" == "true" ]] && def="${_prev[$name]:-}"
        val=$(_stage2_escapable_input "$(_stage2_ddns_field_prompt "$_WIZ_DDNS_PROVIDER" "$name")" "$def" "$validator" "Skip DDNS for now")
        rc=$?
        if ((rc == 130)); then
            return 130 # Ctrl-C: let the pending SIGINT trap abort cleanly
        elif ((rc != 0)); then
            # The user backed out of DDNS mid-collection. Neutralize all state
            # (same as the static-IP / picker skip) so a re-run doesn't resurrect it.
            _WIZ_USES_DDNS="false"
            _WIZ_DDNS_PROVIDER=""
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            ui_log info "Skipping DDNS for now. If you're not setting up remote access yet, choose 'Skip HTTPS for now' at the next prompt — otherwise point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP yourself, then retry."
            return 1
        fi
        _WIZ_DDNS_FIELDS["$name"]="$val"
    done

    # Verify the credentials for ANY provider with the ephemeral blackhole
    # container: render the config to a throwaway path, run it through a one-shot
    # ddns-updater whose record resolver is blackholed so it does a REAL provider
    # push at the current IP, and map GET /update. This is a REJECTION channel:
    #   exit 0 = 202 accepted (or provider-masked) -> tiered message
    #   exit 1 = 500 rejected  -> clear fields, re-prompt (like Dynu badauth before)
    #   exit 2 = degrade (no docker / image unavailable) -> keep shape-valid creds,
    #            land the honest "unchecked" tier, never re-prompt good creds.
    # Build the render assoc = collected fields + the shared media domain (domain
    # is rendered as a reserved key, not a collected field), mirroring env_gen's
    # persist render so verify and persist agree.
    local -A _verify_fields=()
    local _vk
    for _vk in "${!_WIZ_DDNS_FIELDS[@]}"; do _verify_fields["$_vk"]="${_WIZ_DDNS_FIELDS[$_vk]}"; done
    _verify_fields[domain]="$_WIZ_DOMAIN"

    local pname
    pname=$(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER")

    local verify_config verify_body verify_rc=2
    verify_config=$(mktemp 2>/dev/null) || verify_config=""
    verify_body=$(mktemp 2>/dev/null) || verify_body=""
    if [[ -n "$verify_config" ]] \
        && ddns_render_config_json "$_WIZ_DDNS_PROVIDER" _verify_fields >"$verify_config" 2>/dev/null; then
        # The helper is exit-code-valued (writes the 500 body to a file, not
        # stdout), so it can ride ui_spin — which runs it in a background subshell,
        # so the body MUST be surfaced via the file, never a shell global.
        if type ui_spin >/dev/null 2>&1; then
            ui_spin "Checking your ${pname} login (this can take a minute)..." \
                ddns_verify_via_container "$verify_config" "$verify_body"
            verify_rc=$?
        else
            ddns_verify_via_container "$verify_config" "$verify_body"
            verify_rc=$?
        fi
    fi
    [[ -n "$verify_config" ]] && rm -f "$verify_config"

    case "$verify_rc" in
        0)
            # A real /update 202: credentials accepted (or the record already
            # matched the current IP). The push happened, so the caller can wait
            # for DNS to converge and attempt Let's Encrypt.
            _WIZ_DDNS_PREFLIGHT_OK="true"
            _WIZ_DDNS_INVALIDATED="false"
            local tier
            tier=$(ddns_provider_verify_tier "$_WIZ_DDNS_PROVIDER" 2>/dev/null || printf 'token')
            if [[ "$tier" == "token" ]]; then
                ui_log ok "Verified: ${pname} accepted your login and updated ${_WIZ_DOMAIN} to this IP."
            else
                ui_log ok "${pname} accepted the update. If the login turns out wrong, the day-2 Health check will flag it later."
            fi
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            return 0
            ;;
        1)
            # A real /update 500 OR a startup config fail-fast (bad token shape,
            # bad domain eTLD): the config is wrong. Clear the fields so the
            # shape-valid persist gate refuses them (config.json is not written)
            # and the user re-enters (or fixes the domain). Cap the raw provider /
            # validation body so a long regex message doesn't fill the screen.
            local vbody=""
            # ${v:0:160} is character-based (won't split a multibyte char, unlike head -c).
            [[ -n "$verify_body" ]] && vbody=$(tr '\n' ' ' <"$verify_body" 2>/dev/null) && vbody="${vbody:0:160}"
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            ui_log warn "${pname} did not accept these details${vbody:+ — ${vbody}}. Check for a typo, a trailing space, or a hostname that doesn't match ${pname}, then choose 'Re-enter credentials' or 'Change domain' below."
            return 1
            ;;
        *)
            # Degrade: docker or the image was unavailable, or the container never
            # answered. Keep the shape-valid creds (they persist to config.json)
            # and land the honest "unchecked" tier — never re-prompt good creds. The
            # caller prints the "it will update once the stack starts" terminal line,
            # so keep this to just the verify outcome (no duplicate).
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="false"
            ui_log warn "Couldn't check your ${pname} login right now (Docker, the image, or a temporary network/provider hiccup) — your details will be saved and ddns-updater will push your IP when the stack starts."
            return 0
            ;;
    esac
}

_stage2_port_gate() {
    ui_section 2 5 "Router ports"
    ui_log info "Runs from your home network - if your router lacks hairpin NAT, closed results can be misleading."

    # Auto-retry the port probe a few times before bothering the user.
    # nc -z is a single SYN packet with a 5s timeout — perfectly fine to
    # randomly fail under transient conditions (NPM warming up after start,
    # NAT cache flush, dropped SYN, GCP route table churn). 3 attempts with
    # a 5s gap absorbs nearly all spurious "closed" reports without making
    # a real misconfig wait too long for the manual menu.
    local port_state failure action attempt
    while true; do
        for attempt in $(seq 1 "$STAGE2_PORT_PROBE_MAX_ATTEMPTS"); do
            port_state=$(stage2_check_http_ports)
            if [[ "$port_state" == "ok" ]]; then
                if ((attempt == 1)); then
                    ui_log ok "TCP ports 80 and 443 appear reachable from this host."
                else
                    ui_log ok "TCP ports 80 and 443 appear reachable (took ${attempt} attempts - first was likely transient)."
                fi
                return 0
            fi
            if ((attempt < STAGE2_PORT_PROBE_MAX_ATTEMPTS)); then
                ui_log info "Port probe ${attempt}/${STAGE2_PORT_PROBE_MAX_ATTEMPTS} returned ${port_state} - retrying in ${STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS}s..."
                sleep "$STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS"
            fi
        done

        failure=$(stage2_classify_port_failure "${_NET_PUBLIC_IP:-}" "ok" "$port_state")
        case "$failure" in
            cgnat) ui_log warn "Your public IP looks like CGNAT. Ask your ISP for a public IPv4 or use VPN-only access." ;;
            cloudflare) ui_log warn "Cloudflare proxy is on. Set the records to DNS-only, then retry." ;;
            wrong-lan-target) ui_log warn "DNS may point at the wrong router or LAN target. Check the forwarding destination." ;;
            carrier-block) ui_log warn "Your ISP or router may be blocking TCP 80 or 443." ;;
            aaaa-mismatch) ui_log warn "IPv6/AAAA may point somewhere different from your IPv4 records." ;;
            probe-unavailable) ui_log warn "External port-probe services are unavailable or blocked from this network; continue after manually verifying TCP 80 and 443 are forwarded here." ;;
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

_stage2_collect_jellyfin_remote_bitrate() {
    ui_section 4 5 "Jellyfin remote streaming"

    # Jellyfin's RemoteClientBitrateLimit is a PER-STREAM cap (not a global
    # aggregate). We surface a reference table so the user can pick their
    # own value rather than accept/reject a single recommendation. The
    # table covers (a) typical per-stream Mbps budgets at common quality
    # levels, and (b) per-viewer budget across plausible concurrent-viewer
    # counts, computed at 45% of detected upload bandwidth.
    local upload_mbps="${_NET_UL_MBPS:-}"
    if [[ -z "$upload_mbps" || ! "$upload_mbps" =~ ^[0-9]+$ ]]; then
        upload_mbps=$(ui_input_validated "Your upload bandwidth in Mbps (used for the recommendation table)" "100" validate_mbps_whole)
    else
        ui_log info "Detected upload bandwidth: ${upload_mbps} Mbps."
    fi

    ui_box "Per-stream bitrate by quality (Jellyfin transcodes to fit)" \
        "720p HD           3-7 Mbps" \
        "1080p HD          5-15 Mbps" \
        "4K HEVC (H.265)   20-40 Mbps" \
        "4K H.264          40-80 Mbps"

    # Compute the recommendation matrix + suggested-default in one python pass.
    # Python returns the borderless, column-formatted rows on stdout (ui_box
    # supplies the frame) with the suggested default as the LAST line; bash pops
    # that off and renders the rest through ui_box so gum and fallback match.
    # Heuristic: usable = upload * 0.45; raw = usable / viewers; clamp [2, max_cap]
    #   max_cap (1-2 viewers): 8 if upload>=250, 7 if >=100, else 6
    #   max_cap (3-4 viewers): 7 if upload>=500, else 6
    #   max_cap (5+ viewers):  6 if upload>=500, 5 if >=250, else 4
    # 1-2 col borderline: fall back to "1 viewer alone" (floor for safety)
    local _cap_out _cap_rows=() suggested_default
    # Bare assignment (not `local x=$(...)`) so a python failure still aborts the
    # wizard under `set -e`, exactly as before. Capture first, then split with a
    # here-string: `mapfile < <(python3 ...)` would swallow the python exit status
    # AND could leave an empty array for the `[-1]` deref below (unbound abort).
    _cap_out=$(
        UPLOAD="$upload_mbps" python3 <<'PY'
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
        return "-"
    if raw < 1.5:
        return "-"
    return str(max(2, min(max_cap, math.ceil(raw))))

upload_speeds = [10, 20, 40, 100, 250, 500]
columns = [(2, "1-2 viewers"), (4, "3-4 viewers"), (6, "5+ viewers")]
# Borderless rows (no +---+, no leading indent) — ui_box draws the frame.
fmt = "{:<8s}  {:<12s} {:<11s} {:<10s}"
header = fmt.format("Upload", *[c[1] for c in columns])
print(header)
print("-" * len(header))
for up in upload_speeds:
    cells = [compute_cell(up, c[0]) for c in columns]
    print(fmt.format(f"{up} Mbps", *cells))

# Default = recommendation for user's upload at 4 viewers (most common case).
# Strip the "(1 viewer)" annotation if present and fall back to "0" on "-".
# Printed LAST so bash can pop it off the row list.
default_cell = compute_cell(int(os.environ["UPLOAD"]), 4)
if default_cell == "-":
    default_cell = compute_cell(int(os.environ["UPLOAD"]), 2)
    if default_cell == "-" or "(1 viewer)" in default_cell:
        default_cell = "0"
    else:
        default_cell = default_cell.split()[0]
else:
    default_cell = default_cell.split()[0]
print(default_cell)
PY
    )
    mapfile -t _cap_rows <<<"$_cap_out"
    suggested_default="${_cap_rows[-1]}"
    unset '_cap_rows[-1]'

    ui_box "Recommended per-viewer cap (Mbps)" \
        "45% of your upload, capped so your home network stays responsive" \
        "(Jellyfin won't try to use the whole line):" \
        "" \
        "${_cap_rows[@]}"

    # Defensive: the validated prompt trusts its default on the DEMO/non-TTY
    # path, so the default MUST be a valid number. The python heredoc always
    # prints one; guard anyway so a future change can't feed an invalid default
    # into the re-prompt loop.
    [[ "$suggested_default" =~ ^[0-9]+(\.[0-9]+)?$ ]] || suggested_default="0"
    local custom
    custom=$(ui_input_validated "Per-viewer cap in Mbps (decimals OK, e.g. 3.5 or 7.0; 0 = unlimited)" "$suggested_default" validate_mbps_decimal)
    _WIZ_JELLYFIN_BITRATE="$custom"

    # This value is Jellyfin's server-wide default; the admin can retune it or
    # override it per user later, so say so rather than imply it's fixed.
    ui_log info "This sets Jellyfin's global remote-streaming cap. Change it anytime in the"
    ui_log info "Jellyfin dashboard under Networking (Remote Client Bitrate Limit), or set a"
    ui_log info "different limit per user in each user's profile."
}

_stage2_confirm() {
    ui_section 5 5 "Confirm install"
    # Honest DDNS summary: what was chosen this run, OR — on a day-2 re-run where
    # the user skipped but a previously-configured provider's config.json is
    # preserved (env_gen keeps it rather than leaving a config-less dead remote) —
    # say we're keeping it, not "skipped" (which would be a lie while it still runs).
    local ddns_summary
    if [[ "${_WIZ_USES_DDNS:-false}" == "true" && -n "${_WIZ_DDNS_PROVIDER:-}" ]]; then
        ddns_summary=$(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER")
    elif [[ -n "${DDNS_PROVIDER:-}" ]]; then
        ddns_summary="keeping your existing $(_stage2_ddns_provider_label "$DDNS_PROVIDER") setup"
    else
        ddns_summary="skipped (you manage DNS)"
    fi
    ui_box "Remote Access: Install Plan" \
        "$(ui_kv 'Domain' "$_WIZ_DOMAIN")" \
        "$(ui_kv 'DDNS' "$ddns_summary")" \
        "$(ui_kv 'HTTPS' "jellyfin.${_WIZ_DOMAIN}, seerr.${_WIZ_DOMAIN}")" \
        "$(ui_kv 'WireGuard' "$([[ "${_WIZ_WG_ENABLED:-true}" == "true" ]] && echo "${_WIZ_WG_HOST}:${_WIZ_WG_PORT}" || echo 'disabled')")" \
        "$(ui_kv 'Remote streaming cap' "$([[ "${_WIZ_JELLYFIN_BITRATE:-0}" == "0" ]] && echo 'unlimited' || echo "${_WIZ_JELLYFIN_BITRATE} Mbps/viewer")")" \
        "$(ui_kv 'Access' 'LAN remains available if HTTPS fails')"

    _STAGE2_CONFIRM_ACTION=$(ui_choose "Proceed with remote access installation?" \
        "Install" \
        "Back" \
        "Skip remote access")
}

_stage2_skip_https() {
    _stage2_seed_wizard_defaults
    _WIZ_REMOTE_WEB_STATE="skipped"
    write_env || return 1
    _stage2_preserve_stage1_marker
    ui_log skip "$(stage2_skip_summary_copy)"
}

_stage2_install() {
    log_info "Installing remote access..."

    _stage2_seed_wizard_defaults
    # Commit the WireGuard init password here (install path only) and only when
    # the user opted in — this is what activates the remote WG profile. Doing it
    # here rather than during collection means every skip path leaves it as-is
    # (empty on a fresh setup), so a confirm-time "Skip remote access" can't
    # silently enable WireGuard. Explicitly clear it when WG is declined so an
    # existing install's WG is turned off when the user says no.
    if [[ "${_WIZ_WG_ENABLED:-true}" == "true" ]]; then
        _WIZ_WG_INIT_PASSWORD="${_WIZ_ADMIN_PW}"
    else
        _WIZ_WG_INIT_PASSWORD=""
    fi
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
        log_info "Jellyfin remote streaming cap: $([[ "$_WIZ_JELLYFIN_BITRATE" == "0" ]] && echo unlimited || echo "${_WIZ_JELLYFIN_BITRATE} Mbps per viewer")"
    fi

    echo ""
    pull_images

    echo ""
    start_stack
    wait_all_healthy

    # fail2ban only runs on remote-access (proxy-profile) installs, which is a
    # Stage 2 decision — hence installed here, not in Stage 1 beside the storage
    # watchdog. Install the log-rotation reload watcher when fail2ban is up; tear
    # it down otherwise (LAN-only re-run). Gated on ground truth, not a wizard var.
    if container_running fail2ban; then
        f2b_install_reload_watcher
    else
        f2b_uninstall_reload_watcher || true
    fi

    echo ""
    log_info "Running remote-access auto-configuration..."
    local remote_config_rc=0
    # DDNS verify degraded (docker/image unavailable at collection): creds are
    # saved but nothing was pushed and a fresh install's DNS is not live yet.
    # Don't gamble a Let's Encrypt attempt (rate-limit risk + a scary "failed"):
    # still bring ddns-updater up so it pushes the IP, but leave remote HTTPS at
    # "unchecked" and let day-2 "Add remote access" finish it once DNS resolves.
    local attempt_remote=1 spin_msg="Requesting Let's Encrypt certificates..."
    if _stage2_ddns_unverified; then
        attempt_remote=0
        spin_msg="Configuring DDNS + WireGuard (HTTPS deferred until DNS resolves)..."
    fi
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    elif type ui_spin >/dev/null 2>&1; then
        # configure.sh --only npm runs sudo internally (configure_npm), but it is
        # wrapped in `bash -c` here so ui_spin's direct-`sudo` prime can't reach it —
        # warm the credential cache in the foreground first (see scripts/lib/ui.sh).
        sudo -v 2>/dev/null || true
        ui_spin "$spin_msg" \
            bash -c "cd '$SCRIPT_DIR' && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard" || remote_config_rc=$?
    else
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    fi
    if ((remote_config_rc != 0)); then
        log_warn "Remote-access auto-configuration returned a warning or error; checking HTTPS postconditions anyway."
    fi

    if _stage2_ddns_unverified; then
        # REMOTE_WEB_STATE stays "unchecked" (set above); no LE gate to run.
        log_info "DDNS is set up for $(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER"). Once jellyfin.${_WIZ_DOMAIN} resolves to this box, choose Features & settings -> Add remote access to enable HTTPS."
        print_access_info
        return 0
    fi

    stage2_le_gate "$_WIZ_DOMAIN"
    local gate_rc=$?

    print_access_info
    return "$gate_rc"
}

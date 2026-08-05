# Owns: Stage 2 domain, DNS, and remote-access collection flow.
# Sources: Stage 2 DDNS and input helpers, network helpers, and interactive UI.

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
        dns_status=$(net_dns_classify "$_WIZ_DOMAIN" "${_NET_PUBLIC_IP:-}") || true
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

# Owns: npm_* — NPM public-domain proxy publication and certificate-backed host setup.
# Sources: main.sh/certs.sh/rendered.sh/stale.sh; globals: SCRIPT_DIR, DOMAIN, REMOTE_WEB_STATE, MEDIASTACK_NPM_ATTEMPT_REMOTE, NPM_*; hidden caller locals: npm_api, npm_token, rate_enabled, rate_burst, http_top_created.

# shellcheck disable=SC2154
_npm_configure_publication() {
    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"
    local remote_ready="false"
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready="true"
    fi
    local remote_attempt_allowed="$remote_ready"
    if [[ "$remote_ready" != "true" && -n "$domain" && "$domain" != "example.com" && "${MEDIASTACK_NPM_ATTEMPT_REMOTE:-}" == "1" ]]; then
        remote_attempt_allowed="true"
        log_info "Stage 2 remote attempt allowed -- requesting/verifying public proxy hosts before REMOTE_WEB_STATE=ready"
    fi

    # Only proxy user-facing services (Jellyfin + Seerr). Admin tools
    # (Sonarr, Radarr, Jackett, qBittorrent) stay LAN/VPN-only.
    # Fail2ban protects these via the NPM access log jail (401/403 responses).
    # subdomain|forward_host|forward_port|websocket(0/1)
    local proxy_hosts=(
        "jellyfin|jellyfin|8096|1"
        "seerr|seerr|5055|1"
    )

    local existing_hosts="[]"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        if ! existing_hosts=$(api_fetch "NPM proxy hosts" -H "Authorization: Bearer $npm_token" "$npm_api/nginx/proxy-hosts"); then
            existing_hosts="[]"
        fi
        _npm_warn_stale_managed_hosts "$npm_token" "$npm_api" "$domain" "$existing_hosts"
    fi

    # --- Public proxy publication (requires REMOTE_WEB_STATE=ready) ---
    if [[ "$remote_attempt_allowed" == "true" ]]; then
        local fqdn_list=()
        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<<"$entry"
            fqdn_list+=("${subdomain}.${domain}")
        done

        # Disable any previously-created certless hosts before we wait on DNS or
        # attempt ACME. This closes the old exposure window on re-runs.
        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<<"$entry"
            local fqdn="${subdomain}.${domain}"
            local existing_host_json
            existing_host_json=$(echo "$existing_hosts" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
for host in json.load(sys.stdin):
    if fqdn in host.get("domain_names", []):
        print(json.dumps(host))
        break
' 2>/dev/null)
            [[ -z "$existing_host_json" ]] && continue

            local existing_cert_id existing_enabled
            existing_cert_id=$(echo "$existing_host_json" | json_get certificate_id 0)
            existing_enabled=$(echo "$existing_host_json" | json_get enabled False)
            if [[ "${existing_cert_id:-0}" == "0" && "$existing_enabled" =~ ^(True|true)$ ]]; then
                local disable_http
                disable_http=$(_npm_disable_host "$npm_token" "$npm_api" "$(echo "$existing_host_json" | json_get id)" "$existing_host_json")
                if [[ "$disable_http" =~ ^2 ]]; then
                    log_warn "Disabled certless proxy host: $fqdn until certificate issuance succeeds"
                else
                    log_warn "Could not disable certless proxy host: $fqdn (HTTP $disable_http)"
                fi
            fi
        done

        # --- DNS propagation gate ---
        # On first run the DDNS updater may not have propagated the new IP yet.
        # Let's Encrypt HTTP-01 will fail if the public hostnames still point
        # elsewhere. The gate compares getent ahosts vs the host's real public
        # IP. This is required for BOTH Let's Encrypt production and staging:
        # staging relaxes rate limits, but it still performs the normal public
        # DNS + HTTP-01 validation. Only truly custom/local ACME endpoints
        # (Pebble, internal CAs) should skip the public-DNS gate.
        local _le_server="${NPM_LE_SERVER:-}"
        local _needs_public_dns_gate="false"
        if [[ -z "$_le_server" || "$_le_server" == *"letsencrypt.org/directory" ]]; then
            _needs_public_dns_gate="true"
        fi

        local _public_ip="" _dns_ok=""
        if [[ "$_needs_public_dns_gate" != "true" ]]; then
            log_info "Custom ACME endpoint (${_le_server:-unset}) - skipping public DNS propagation gate"
        else
            _public_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null) \
                || _public_ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null) \
                || _public_ip=""
        fi

        if [[ -n "$_public_ip" ]]; then
            log_info "Public IP: $_public_ip - waiting for DNS propagation..."
            local _dns_wait=0 _dns_max="$NPM_DNS_PROPAGATION_TIMEOUT_SECONDS" _dns_status_line=""
            while ((_dns_wait < _dns_max)); do
                local _all_dns_ok="yes"
                local _dns_status=()
                for fqdn in "${fqdn_list[@]}"; do
                    local _dns_ip
                    _dns_ip=$(getent ahosts "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')
                    if [[ "$_dns_ip" != "$_public_ip" ]]; then
                        _all_dns_ok=""
                        _dns_status+=("${fqdn}=${_dns_ip:-unresolvable}")
                    fi
                done
                _dns_status_line=$(
                    IFS=', '
                    echo "${_dns_status[*]}"
                )
                if [[ -n "$_all_dns_ok" ]]; then
                    _dns_ok="yes"
                    log_ok "DNS propagated: ${fqdn_list[*]} -> $_public_ip (${_dns_wait}s)"
                    break
                fi
                sleep "$NPM_DNS_PROPAGATION_INTERVAL_SECONDS"
                ((_dns_wait += NPM_DNS_PROPAGATION_INTERVAL_SECONDS))
                echo -ne "."
            done
            [[ -z "$_dns_ok" ]] && echo "" \
                && log_warn "DNS did not resolve to $_public_ip after ${_dns_max}s (${_dns_status_line:-unresolvable}) - public proxy hosts may be deferred"
        else
            log_info "Could not detect public IP - skipping DNS propagation check"
        fi

        # --- Certificate issuance + proxy publication ---
        _npm_cert_status_init "$domain"

        # Re-fetch after any disable operations so final writes start from fresh state.
        if ! existing_hosts=$(api_fetch "NPM proxy hosts (publish)" -H "Authorization: Bearer $npm_token" "$npm_api/nginx/proxy-hosts"); then
            existing_hosts="[]"
        fi

        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<<"$entry"
            local fqdn="${subdomain}.${domain}"
            local ws_val="false"
            [[ "$websocket" == "1" ]] && ws_val="true"

            local adv_config=""
            # Rate limiting is opt-in (config.yml rate_limiting.enabled); the
            # security headers below are always applied.
            if [[ "$rate_enabled" == "true" ]]; then
                adv_config="limit_req zone=mediastack_ratelimit burst=${rate_burst} nodelay;
limit_req_status 429;
"
            fi
            # Security headers use more_set_headers, NOT add_header. NPM's
            # bundled proxy.conf emits `add_header X-Served-By` inside `location
            # /`, and nginx drops ALL inherited server-level add_header directives
            # the moment a location declares its own — so server-level add_header
            # security headers never reach the response. more_set_headers (the
            # openresty headers_more module NPM ships) is not subject to that
            # inheritance rule and emits regardless of the location's add_header.
            adv_config+='more_set_headers "X-Content-Type-Options: nosniff";
more_set_headers "Strict-Transport-Security: max-age=31536000; includeSubDomains";
more_set_headers "Permissions-Policy: accelerometer=(), ambient-light-sensor=(), battery=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), microphone=()";'
            # Jellyfin-specific additions from its official nginx reverse-proxy
            # guide (jellyfin.org). proxy_buffering off keeps streaming responsive;
            # client_max_body_size 20M allows subtitle/avatar/plugin uploads; the
            # Content-Security-Policy is Jellyfin's exact recommended string
            # (connect-src 'self' covers the same-origin /socket websocket;
            # gstatic/youtube/blob are whitelisted for the built-in web player).
            # CSP uses more_set_headers for the same reason as above; CSP +
            # client_max_body_size are Jellyfin-only — upstream Seerr ships
            # neither.
            if [[ "$subdomain" == "jellyfin" ]]; then
                adv_config+=$'\nproxy_buffering off;'
                adv_config+=$'\nclient_max_body_size 20M;'
                local jf_csp="default-src https: data: blob: ; img-src 'self' https://* ; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' https://www.gstatic.com https://www.youtube.com blob:; worker-src 'self' blob:; connect-src 'self'; object-src 'none'; font-src 'self'"
                adv_config+=$'\nmore_set_headers "Content-Security-Policy: '"$jf_csp"$'";'
            fi

            local host_json
            host_json=$(echo "$existing_hosts" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
for host in json.load(sys.stdin):
    if fqdn in host.get("domain_names", []):
        print(json.dumps(host))
        break
' 2>/dev/null)

            local host_id host_cert_id target_cert_id
            host_id=""
            host_cert_id="0"
            local cert_post_attempted="false" cert_post_http="" latest_cert_id="" cert_outcome="pending" proxy_published="false"
            if [[ -n "$host_json" ]]; then
                host_id=$(echo "$host_json" | json_get id)
                host_cert_id=$(echo "$host_json" | json_get certificate_id 0)
            fi

            # Site 1: existing host's cert_id. Adopt only when the cert
            # material is actually on disk — NPM may have a stale row from
            # a prior aborted issuance (orphan FK).
            target_cert_id="${host_cert_id:-0}"
            if [[ "${target_cert_id:-0}" != "0" ]] \
                && ! _npm_cert_material_ready "$target_cert_id"; then
                log_warn "Existing $fqdn cert_id=$target_cert_id has no key+chain on disk - re-issuing"
                target_cert_id="0"
            fi

            # Site 2: any pre-existing cert in NPM's list for this FQDN —
            # again gated on disk truth.
            if [[ "${target_cert_id:-0}" == "0" ]]; then
                target_cert_id=$(_npm_usable_cert_id_by_fqdn "$npm_token" "$npm_api" "$fqdn") || target_cert_id=""
            fi

            if [[ -z "$target_cert_id" || "$target_cert_id" == "0" ]]; then
                # ----------------------------------------------------------
                # Cert issuance: AT MOST ONE POST per FQDN per heal cycle.
                # ----------------------------------------------------------
                # The previous design (cert_max=5 retries × 180s reconcile
                # each) produced multi-cert burn on every flaky run: a POST
                # that "timed out" (HTTP 000) while certbot was still
                # working would trigger another POST, NPM would allocate a
                # new cert row, and so on. On LE production the rate limit
                # is 5 duplicate certs / 168h / identifier set — three POSTs
                # per heal would burn the weekly budget in two heal cycles.
                #
                # New invariant: we ask NPM for what's already in flight
                # before POSTing. If a cert row already exists for this
                # FQDN, OR certbot is currently running, we DO NOT POST.
                # We just wait long enough (up to ~20 min) for the existing
                # in-flight issuance to land disk material. Only if we know
                # for sure (a) NPM has no cert row for this FQDN and (b)
                # certbot isn't busy do we issue a POST — exactly one,
                # never retried. A second issuance attempt is a NEW heal
                # cycle, not an inner retry, and is the operator's choice.
                local cert_body
                cert_body=$(FQDN="$fqdn" python3 -c '
import os, json
print(json.dumps({
    "provider": "letsencrypt",
    "domain_names": [os.environ["FQDN"]],
    "meta": {"dns_challenge": False},
}))')

                local existing_latest existing_rc
                existing_latest=$(_npm_latest_cert_id_by_fqdn "$npm_token" "$npm_api" "$fqdn")
                existing_rc=$?
                latest_cert_id="$existing_latest"

                if ((existing_rc == 2)); then
                    log_warn "Cert pre-flight: NPM API unreachable for $fqdn - refusing to POST (would risk duplicate issuance); deferring"
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "${target_cert_id:-0}" "false" "false" "$host_id" "npm-api-unreachable"
                    continue
                fi

                local should_post="false"
                if [[ -z "$existing_latest" || "$existing_latest" == "0" ]]; then
                    if _npm_certbot_busy; then
                        log_info "Cert pre-flight: certbot is currently running; not POSTing for $fqdn - will wait"
                    else
                        should_post="true"
                    fi
                else
                    if _npm_cert_material_ready "$existing_latest"; then
                        log_info "Cert pre-flight: NPM already has usable cert_id=$existing_latest for $fqdn - waiting on disk material instead of POSTing"
                    elif _npm_certbot_busy; then
                        log_info "Cert pre-flight: NPM has incomplete cert_id=$existing_latest for $fqdn and certbot is still running - not POSTing"
                    else
                        log_warn "Cert pre-flight: NPM has stale/incomplete cert_id=$existing_latest for $fqdn with no key+chain on disk and certbot is idle - issuing a fresh cert request"
                        should_post="true"
                    fi
                fi

                if [[ "$should_post" == "true" ]]; then
                    local cert_resp cert_http
                    cert_post_attempted="true"
                    cert_resp=$(curl -s -w "\n%{http_code}" --max-time "$NPM_CERT_POST_TIMEOUT_SECONDS" -X POST "$npm_api/nginx/certificates" \
                        -H "Authorization: Bearer $npm_token" \
                        -H "Content-Type: application/json" \
                        -d "$cert_body" 2>/dev/null)
                    cert_http=$(echo "$cert_resp" | tail -1)
                    cert_post_http="$cert_http"
                    log_info "Cert POST for $fqdn -> HTTP ${cert_http:-000} (single POST per heal cycle)"
                fi

                # Wait up to ~20 min for any matching cert row to become
                # disk-usable. Iterates newest-first across all matching
                # ids, so an older ready cert isn't masked by a newer
                # not-yet-finished row.
                local found_cert_id wait_rc
                found_cert_id=$(_npm_wait_usable_cert "$npm_token" "$npm_api" "$fqdn" "$NPM_CERT_WAIT_MAX_POLLS" "$NPM_CERT_WAIT_INTERVAL_SECONDS")
                wait_rc=$?
                if ((wait_rc == 0)) && [[ -n "$found_cert_id" && "$found_cert_id" != "0" ]]; then
                    target_cert_id="$found_cert_id"
                    latest_cert_id="${latest_cert_id:-$found_cert_id}"
                else
                    case "$wait_rc" in
                        2) log_warn "Cert wait: NPM API unreachable throughout the window for $fqdn - public proxy host deferred" ;;
                        *) log_warn "Cert wait: no usable cert for $fqdn after ~20 min - public proxy host deferred" ;;
                    esac
                    cert_outcome="cert-wait-failed"
                    [[ "$wait_rc" == "2" ]] && cert_outcome="npm-api-unreachable"
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "${target_cert_id:-0}" "false" "false" "$host_id" "$cert_outcome"
                    continue
                fi
            fi

            # Idempotent skip MUST verify rendered state on disk, not just
            # DB field match. A historical orphan (DB row matches desired
            # JSON, but no proxy_host/$id.conf and no cert material) would
            # otherwise survive every re-run forever — the skip path here
            # was the gap that let the GCP-staging orphan persist past
            # multiple `configure.sh --only npm` invocations.
            if [[ -n "$host_json" ]] && echo "$host_json" \
                | FQDN="$fqdn" FH="$forward_host" FP="$forward_port" WS="$ws_val" \
                    ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import sys, json, os
host = json.load(sys.stdin)
matches = (
    host.get("domain_names", []) == [os.environ["FQDN"]] and
    host.get("forward_scheme") == "http" and
    host.get("forward_host") == os.environ["FH"] and
    int(host.get("forward_port", 0)) == int(os.environ["FP"]) and
    bool(host.get("allow_websocket_upgrade")) == (os.environ["WS"] == "true") and
    int(host.get("certificate_id") or 0) == int(os.environ["CERT_ID"]) and
    bool(host.get("ssl_forced")) and
    bool(host.get("http2_support")) and
    bool(host.get("enabled")) and
    (host.get("advanced_config", "") or "") == os.environ["ADV"]
)
sys.exit(0 if matches else 1)
' 2>/dev/null && _npm_proxy_conf_renders "$host_id" "$fqdn" "$target_cert_id"; then
                log_skip "Proxy host: $fqdn already published"
                _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                continue
            fi

            # Publish, then verify by host-mounted disk truth — NPM's API
            # returns 2xx even when it can't render the .conf, so we cannot
            # treat HTTP 2xx as success on its own. If the .conf doesn't
            # appear with the expected (server_name, cert_id), roll the
            # host back to enabled=False cert=0 so it doesn't sit in DB
            # forever as an "enabled but invisible" orphan.
            if [[ -n "$host_json" ]]; then
                local update_body update_http
                update_body=$(echo "$host_json" \
                    | FQDN="$fqdn" FH="$forward_host" FP="$forward_port" WS="$ws_val" \
                        ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import sys, json, os
host = json.load(sys.stdin)
host["domain_names"] = [os.environ["FQDN"]]
host["forward_scheme"] = "http"
host["forward_host"] = os.environ["FH"]
host["forward_port"] = int(os.environ["FP"])
host["block_exploits"] = True
host["allow_websocket_upgrade"] = os.environ["WS"] == "true"
host["access_list_id"] = 0
host["certificate_id"] = int(os.environ["CERT_ID"])
host["ssl_forced"] = True
host["http2_support"] = True
host["meta"] = host.get("meta") or {}
host["advanced_config"] = os.environ["ADV"]
host["locations"] = host.get("locations") or []
host["caching_enabled"] = False
host["hsts_enabled"] = False
host["hsts_subdomains"] = False
host["enabled"] = True
for k in ("id", "created_on", "modified_on", "owner_user_id", "owner",
          "use_default_location", "ipv6"):
    host.pop(k, None)
print(json.dumps(host))
' 2>/dev/null)
                update_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$NPM_API_WRITE_TIMEOUT_SECONDS" -X PUT \
                    "$npm_api/nginx/proxy-hosts/$host_id" \
                    -H "Authorization: Bearer $npm_token" \
                    -H "Content-Type: application/json" \
                    -d "$update_body")

                if [[ "$update_http" =~ ^2 ]]; then
                    if _npm_wait_proxy_conf "$host_id" "$fqdn" "$target_cert_id"; then
                        proxy_published="true"
                        log_ok "Proxy host: $fqdn published (cert_id=$target_cert_id, SSL forced, HTTP/2)"
                    else
                        log_warn "Proxy host: $fqdn updated in NPM API but proxy_host/$host_id.conf did not render with cert_id=$target_cert_id - disabling to avoid orphan"
                        _npm_disable_host "$npm_token" "$npm_api" "$host_id" "$host_json" >/dev/null 2>&1 || true
                    fi
                else
                    log_warn "Proxy host update failed: $fqdn (HTTP $update_http)"
                fi
                if [[ "$proxy_published" == "true" ]]; then
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                else
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "false" "$host_id" "proxy-render-failed"
                fi
            else
                local proxy_body proxy_resp proxy_http new_host_id
                proxy_body=$(FQDN="$fqdn" FH="$forward_host" FP="$forward_port" \
                    WS="$ws_val" ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import os, json
print(json.dumps({
    "domain_names": [os.environ["FQDN"]],
    "forward_scheme": "http",
    "forward_host": os.environ["FH"],
    "forward_port": int(os.environ["FP"]),
    "block_exploits": True,
    "allow_websocket_upgrade": os.environ["WS"] == "true",
    "access_list_id": 0,
    "certificate_id": int(os.environ["CERT_ID"]),
    "ssl_forced": True,
    "http2_support": True,
    "meta": {},
    "advanced_config": os.environ["ADV"],
    "locations": [],
    "caching_enabled": False,
    "hsts_enabled": False,
    "hsts_subdomains": False,
    "enabled": True,
}))')
                # Capture the response body so we can read the new host id
                # for the disk-render postcondition check.
                proxy_resp=$(curl -s -w "\n%{http_code}" --max-time "$NPM_API_WRITE_TIMEOUT_SECONDS" -X POST \
                    "$npm_api/nginx/proxy-hosts" \
                    -H "Authorization: Bearer $npm_token" \
                    -H "Content-Type: application/json" \
                    -d "$proxy_body")
                proxy_http=$(echo "$proxy_resp" | tail -1)
                proxy_resp=$(echo "$proxy_resp" | sed '$d')
                if [[ "$proxy_http" == "201" ]]; then
                    new_host_id=$(echo "$proxy_resp" | json_get id)
                    if [[ -n "$new_host_id" ]] \
                        && _npm_wait_proxy_conf "$new_host_id" "$fqdn" "$target_cert_id"; then
                        proxy_published="true"
                        host_id="$new_host_id"
                        log_ok "Proxy host: $fqdn published (cert_id=$target_cert_id, SSL forced, HTTP/2)"
                    else
                        log_warn "Proxy host: $fqdn created in NPM API but proxy_host/${new_host_id:-?}.conf did not render with cert_id=$target_cert_id - disabling to avoid orphan"
                        [[ -n "$new_host_id" ]] \
                            && _npm_disable_host "$npm_token" "$npm_api" "$new_host_id" "" >/dev/null 2>&1 || true
                    fi
                else
                    log_warn "Proxy host create failed: $fqdn (HTTP $proxy_http)"
                fi
                if [[ "$proxy_published" == "true" ]]; then
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                else
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "false" "${new_host_id:-$host_id}" "proxy-render-failed"
                fi
            fi
        done
    else
        log_skip "Remote web state is ${remote_state:-unset} -- skipping public proxy hosts"
        if [[ -n "$domain" && "$domain" != "example.com" ]]; then
            for entry in "${proxy_hosts[@]}"; do
                IFS='|' read -r subdomain forward_host forward_port websocket <<<"$entry"
                local fqdn="${subdomain}.${domain}"
                local existing_host_json
                existing_host_json=$(echo "$existing_hosts" | FQDN="$fqdn" FH="$forward_host" FP="$forward_port" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
forward_host = os.environ["FH"]
forward_port = int(os.environ["FP"])
for host in json.load(sys.stdin):
    if (
        host.get("domain_names", []) == [fqdn] and
        host.get("forward_host") == forward_host and
        int(host.get("forward_port", 0)) == forward_port
    ):
        print(json.dumps(host))
        break
' 2>/dev/null)
                [[ -z "$existing_host_json" ]] && continue

                local existing_enabled
                existing_enabled=$(echo "$existing_host_json" | json_get enabled False)
                if [[ "$existing_enabled" =~ ^(True|true)$ ]]; then
                    local host_id disable_http
                    host_id=$(echo "$existing_host_json" | json_get id)
                    if [[ "$remote_state" == "failed" ]]; then
                        local existing_cert_id
                        existing_cert_id=$(echo "$existing_host_json" | json_get certificate_id 0)
                        if [[ "${existing_cert_id:-0}" != "0" ]] \
                            && _npm_cert_material_ready "$existing_cert_id" \
                            && _npm_proxy_conf_renders "$host_id" "$fqdn" "$existing_cert_id"; then
                            log_skip "Preserved ready proxy host after failed Stage 2: $fqdn"
                            continue
                        fi
                    fi
                    disable_http=$(_npm_disable_host "$npm_token" "$npm_api" "$host_id" "$existing_host_json")
                    if [[ "$disable_http" =~ ^2 ]]; then
                        log_warn "Disabled non-ready proxy host: $fqdn"
                    else
                        log_warn "Could not disable non-ready proxy host: $fqdn (HTTP $disable_http)"
                    fi
                fi
            done
        fi
    fi

}

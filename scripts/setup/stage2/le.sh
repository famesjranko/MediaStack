# Owns: stage2_* — Stage 2 Let's Encrypt readiness classification and failure gate.
# Sources: Stage 2 shared helpers, NPM remote helpers, and network/stack helpers.

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
    dns_status=$(net_dns_classify "$domain" "${_NET_PUBLIC_IP:-}" 2>/dev/null || true)
    if [[ "$dns_status" != "ok" ]]; then
        STAGE2_LE_CLASSIFICATION="config-dns"
        printf '%s\n' "$STAGE2_LE_CLASSIFICATION"
        return 1
    fi

    port_state=$(net_check_http_ports 2>/dev/null || printf 'unknown')
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
        _stage2_set_remote_state ready || return 1
        _stage2_source_env
        (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only npm,jellyfin,homepage)
        log_ok "Remote access is ready: https://jellyfin.${domain} and https://seerr.${domain}."
        return 0
    fi

    # Unlike the ready/skipped writes below, this one records a state the user
    # is about to be told about anyway. Warn (the writer already did) and carry
    # on: the classification copy, the status snapshot and the recovery menu are
    # what the operator actually needs here, and returning now would replace a
    # certificate diagnosis with an .env error.
    _stage2_set_remote_state failed || log_warn "Continuing without a saved remote-access state."
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
            _stage2_set_remote_state skipped || return 1
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

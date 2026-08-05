# Owns: Stage 2 router port reachability gate and retry flow.
# Sources: Stage 2 skip helper, network port probes, and interactive UI.

_stage2_port_gate() {
    ui_section 2 5 "Router ports"
    ui_log info "Runs from your home network - if your router lacks hairpin NAT, closed results can be misleading."

    # Auto-retry the port probe a few times before bothering the user.
    # nc -z is a single SYN packet with a 5s timeout — perfectly fine to
    # randomly fail under transient conditions (NPM warming up after start,
    # NAT cache flush, dropped SYN, GCP route table churn). 3 attempts with a
    # 5s gap absorbs nearly all spurious "closed" reports without making
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

        failure=$(net_classify_port_failure "${_NET_PUBLIC_IP:-}" "ok" "$port_state")
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

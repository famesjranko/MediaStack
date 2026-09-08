# Owns: setup_* — post-wizard UFW rules for configurable torrent and WireGuard ports.
# Sources: hardening.sh globals and ledger helpers, and firewall.sh's _ms_ufw_allow.
# Globals: TORRENT_PORT, DOMAIN, and WG_PORT (optional .env inputs).

# These ports are user-configurable, so a re-run after a change would otherwise
# leave the previous port allowed forever. Revoke the rule we own for the old
# port before allowing the new one: match on the exact MediaStack comment tag,
# so an admin's own rule on the same port is never touched. Deleting by rule
# number renumbers what follows, hence descending order.
_setup_ufw_revoke_tag() {
    local tag="$1" keep="$2" numbers=() number count i rule failed=false
    # An inactive ufw lists no rules, so revocation would see nothing while the
    # old rule still exists in the backend; a ledger rewritten then would name
    # only the new port when both go live at the next `ufw enable`. Leave both
    # the rules and the ledger alone until ufw is active.
    LC_ALL=C sudo ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    mapfile -t numbers < <(LC_ALL=C sudo ufw status numbered 2>/dev/null \
        | sed -n "/# ${tag}[[:space:]]*\$/s/^\[[[:space:]]*\([0-9][0-9]*\)\][[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1 \2/p" \
        | awk -v keep="$keep" '$2 != keep {print $1}' | sort -rn)
    for number in "${numbers[@]}"; do
        sudo ufw --force delete "$number" >/dev/null 2>&1 || failed=true
    done
    # A failed delete leaves the old rule live; keep its ledger entry so
    # uninstall still knows about it rather than replaying only the new port.
    if [[ "$failed" == "true" ]]; then
        return 0
    fi

    # Keep the ledger honest: _uninstall_ufw replays UFW_RULE_* verbatim, so a
    # stale port there would outlive the rule it names. One tag owns one rule,
    # so rewriting in place is the whole update — and it leaves _ms_ufw_allow's
    # dedup to recognise the rule it is about to add.
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    for ((i = 1; i <= count; i++)); do
        rule=$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)
        [[ "$rule" == *" comment $tag" ]] || continue
        [[ "$rule" == "allow $keep comment $tag" ]] && continue
        _ms_state_set "UFW_RULE_$i" "allow $keep comment $tag" || return 1
    done
}

setup_ufw_service_ports() {
    command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]] || return

    local torrent_port="${TORRENT_PORT:-6881}"
    _setup_ufw_revoke_tag MediaStack:Torrent-TCP "$torrent_port/tcp"
    _setup_ufw_revoke_tag MediaStack:Torrent-UDP "$torrent_port/udp"
    _ms_ufw_allow "$torrent_port/tcp" comment MediaStack:Torrent-TCP >/dev/null 2>&1
    _ms_ufw_allow "$torrent_port/udp" comment MediaStack:Torrent-UDP >/dev/null 2>&1

    local domain="${DOMAIN:-example.com}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        local wg_port="${WG_PORT:-51820}"
        _setup_ufw_revoke_tag MediaStack:WireGuard "$wg_port/udp"
        _ms_ufw_allow "$wg_port/udp" comment MediaStack:WireGuard >/dev/null 2>&1
    fi

    sudo ufw reload >/dev/null 2>&1
    local port_msg="torrent ${torrent_port}"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        port_msg="${port_msg}, VPN ${WG_PORT:-51820}"
    fi
    log_ok "Firewall: service ports opened (${port_msg})"
}

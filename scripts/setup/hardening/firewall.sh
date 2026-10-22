# Owns: UFW firewall policy and its teardown. The admin-port filter is not UFW's: see admin-filter.sh.
# Sources: hardening.sh globals and common.sh logging helpers.
# Globals: MEDIASTACK_STATE_FILE and LAN_CIDRS.

# Root-tool lookup (ufw_installed, host_tool_installed); callers source this file directly, not only via common.sh.
# shellcheck source=../../lib/host-tools.sh
declare -F host_tool_installed >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/host-tools.sh"

# shellcheck source=../../lib/apt.sh
declare -p MS_APT_INSTALL >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/apt.sh"

_ms_ufw_allow() {
    # ufw prints "Rule added"/"Skipping adding existing rule" to stdout on each
    # call; suppress that per-rule noise (the caller logs a single summary line).
    # stderr is preserved so genuine ufw errors still surface.
    sudo ufw allow "$@" >/dev/null || return 1
    sudo test -f "$MEDIASTACK_STATE_FILE" || return 0
    local rule="allow $*" count i
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    for ((i = 1; i <= count; i++)); do
        [[ "$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)" == "$rule" ]] && return 0
    done
    count=$((count + 1))
    _ms_state_set "UFW_RULE_$count" "$rule" && _ms_state_set UFW_RULE_COUNT "$count"
}

# ---------------------------------------------------------------------------
# UFW firewall
# ---------------------------------------------------------------------------

setup_ufw() {
    if ! ufw_installed; then
        ui_spin "Installing ufw..." "${MS_APT_INSTALL[@]}" ufw
    fi

    if [[ "$(_ms_state_get UFW_DEFAULTS_APPLIED 2>/dev/null || true)" == "true" &&
    "$(_ufw_defaults)" != "deny allow" ]]; then
        log_warn "UFW default policy changed after setup; leaving UFW unchanged"
        return 0
    fi

    if sudo ufw status 2>/dev/null | grep -q 'MediaStack:Beszel-agent'; then
        if [[ "$(_ufw_defaults)" == "deny allow" ]]; then
            log_skip "UFW already configured"
        else
            log_warn "UFW default policy changed after setup; leaving it unchanged"
        fi
        return 0
    fi

    log_info "Configuring UFW firewall..."
    sudo ufw default deny incoming >/dev/null
    sudo ufw default allow outgoing >/dev/null
    _ms_state_set UFW_DEFAULTS_APPLIED true

    setup_ufw_ssh_rules
    _ms_ufw_allow 80/tcp comment MediaStack:HTTP-ACME >/dev/null
    _ms_ufw_allow 443/tcp comment MediaStack:HTTPS >/dev/null
    # Configurable ports (TORRENT_PORT, WG_PORT) are opened by
    # setup_ufw_service_ports() after the wizard sets their values.
    _ms_ufw_allow from 172.16.0.0/12 to any port 45876 proto tcp comment MediaStack:Beszel-agent >/dev/null

    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw --force enable >/dev/null
        _ms_state_set UFW_ENABLED_BY_MEDIASTACK true
    fi

    # The admin-port filter is not UFW's: setup_admin_filter owns it, UFW on or off.
    log_ok "UFW firewall enabled"
}

# ---------------------------------------------------------------------------
# Uninstall: reverse MediaStack UFW changes
# ---------------------------------------------------------------------------

# Reverses MediaStack's UFW changes only. The admin-port filter is not UFW's:
# admin_filter_disable removes it (and any legacy after.rules block).
_uninstall_ufw() {
    local numbers=() number defaults incoming outgoing before current count i rule args=()
    mapfile -t numbers < <(LC_ALL=C sudo ufw status numbered 2>/dev/null \
        | sed -n '/# MediaStack:/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn)
    for number in "${numbers[@]}"; do
        sudo ufw --force delete "$number" >/dev/null || return 1
    done
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    for ((i = 1; i <= count; i++)); do
        rule=$(_ms_state_get "UFW_RULE_$i") || return 1
        read -r -a args <<<"$rule"
        sudo ufw --force delete "${args[@]}" >/dev/null 2>&1 || true
    done
    LC_ALL=C sudo ufw show added 2>/dev/null | grep -Fq 'MediaStack:' && return 1

    # A hook left by an earlier version would delete the admin-port filter's
    # jump on the next UFW load; admin-filter.sh owns taking it out.
    _admin_filter_strip_dedup_hook || return 1
    sudo ufw reload >/dev/null 2>&1 || return 1

    defaults=$(_ufw_defaults)
    read -r incoming outgoing <<<"$defaults"
    if [[ "$(_ms_state_get UFW_DEFAULTS_APPLIED)" == "true" ]]; then
        if [[ "$incoming" == "deny" ]]; then
            sudo ufw default "$(_ms_state_get UFW_DEFAULT_INCOMING)" incoming >/dev/null || return 1
        else
            log_warn "UFW incoming default changed after install; preserving '$incoming'"
        fi
        if [[ "$outgoing" == "allow" ]]; then
            sudo ufw default "$(_ms_state_get UFW_DEFAULT_OUTGOING)" outgoing >/dev/null || return 1
        else
            log_warn "UFW outgoing default changed after install; preserving '$outgoing'"
        fi
    fi

    before=$(_ms_state_get UFW_RULES_BEFORE_SHA256)
    current=$(_ufw_rule_hash)
    if [[ "$(_ms_state_get UFW_ENABLED_BY_MEDIASTACK)" == "true" ]] \
        && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        defaults=$(_ufw_defaults)
        if [[ "$current" == "$before" &&
            "$defaults" == "$(_ms_state_get UFW_DEFAULT_INCOMING) $(_ms_state_get UFW_DEFAULT_OUTGOING)" ]]; then
            sudo ufw --force disable >/dev/null || return 1
        else
            log_warn "UFW gained user changes after install; leaving it active"
        fi
    fi

    # SSH lockout guard: we just deleted MediaStack's SSH allow rules. If UFW is
    # still active and enforcing default-deny (we did NOT disable it — the user
    # added their own rules, or the firewall pre-dates MediaStack), a remote
    # admin could lose SSH. Re-assert an allow for the current SSH session's
    # source and for the detected SSH port(s) from the private LAN ranges. These
    # are left UNTAGGED on purpose so a future uninstall/toggle never strips them
    # (which would re-introduce the lockout) — they become the user's own rules.
    if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
        local ssh_incoming ssh_port ssh_cidr ssh_client ssh_sport ssh_kept=false
        read -r ssh_incoming _ < <(_ufw_defaults)
        if [[ "$ssh_incoming" == "deny" ]]; then
            if [[ -n "${SSH_CONNECTION:-}" ]]; then
                read -r ssh_client _ _ ssh_sport _ <<<"$SSH_CONNECTION"
                # Accept IPv6 sessions too (ufw_valid_ip_literal, matching the
                # install path's detect_active_ssh_client). Restricting to
                # ufw_valid_ipv4 here would skip the session allow for a remote
                # admin on an IPv6-only SSH connection and lock them out.
                if ufw_valid_ip_literal "$ssh_client" && ufw_valid_port "$ssh_sport"; then
                    sudo ufw allow from "$ssh_client" to any port "$ssh_sport" proto tcp >/dev/null 2>&1 \
                        && ssh_kept=true
                fi
            fi
            while read -r ssh_port; do
                [[ -n "$ssh_port" ]] || continue
                for ssh_cidr in "${LAN_CIDRS[@]}"; do
                    sudo ufw allow from "$ssh_cidr" to any port "$ssh_port" proto tcp >/dev/null 2>&1 \
                        && ssh_kept=true
                done
            done < <(detect_ssh_server_ports)
            [[ "$ssh_kept" == "true" ]] \
                && log_warn "UFW left active (default-deny); preserved SSH access (LAN + current session) so you are not locked out"
        fi
    fi
    log_ok "MediaStack UFW rules removed; unrelated rules preserved"
}

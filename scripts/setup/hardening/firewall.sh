# Owns: UFW firewall policy, Docker restriction rules, and their teardown.
# Sources: hardening.sh globals and common.sh logging helpers.
# Globals: MEDIASTACK_STATE_FILE, MEDIASTACK_UFW_AFTER_RULES, MEDIASTACK_UFW_AFTER_INIT, and LAN_CIDRS.

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
    if ! command -v ufw &>/dev/null; then
        ui_spin "Installing ufw..." sudo apt-get install -y -qq ufw
    fi

    if [[ "$(_ms_state_get UFW_DEFAULTS_APPLIED 2>/dev/null || true)" == "true" &&
    "$(_ufw_defaults)" != "deny allow" ]]; then
        log_warn "UFW default policy changed after setup; leaving UFW unchanged"
        return 0
    fi

    # Install/refresh the DOCKER-USER jump dedup hook (idempotent, marker-guarded).
    # After the drift guard above so a "leaving UFW unchanged" box is untouched;
    # before the skip guard below so existing installs pick it up on a re-run.
    setup_ufw_docker_dedup_hook

    if sudo ufw status 2>/dev/null | grep -q 'MediaStack:Beszel-agent' \
        && ufw_docker_rules_installed; then
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

    setup_ufw_docker_rules || return 1

    log_ok "UFW firewall enabled"
}

# Docker bypasses UFW via direct iptables manipulation. Inject rules into
# the DOCKER-USER chain via /etc/ufw/after.rules to restrict management
# ports to LAN-only access.
ufw_docker_rules_persisted() {
    sudo grep -q '# MEDIASTACK-DOCKER-RULES' /etc/ufw/after.rules 2>/dev/null
}

ufw_docker_jump_live() {
    sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1
}

ufw_docker_rules_installed() {
    ufw_docker_rules_persisted && ufw_docker_jump_live
}

setup_ufw_docker_rules() {
    local after_rules="/etc/ufw/after.rules"
    local rules_persisted=false

    if ufw_docker_rules_persisted; then
        rules_persisted=true
    fi

    if [[ "$rules_persisted" == "true" ]] && ufw_docker_jump_live; then
        return
    fi

    if [[ "$rules_persisted" == "true" ]]; then
        log_info "Reloading Docker/UFW restriction rules..."
    else
        log_info "Adding Docker/UFW restriction rules..."

        sudo tee -a "$after_rules" >/dev/null <<'RULES'

# MEDIASTACK-DOCKER-RULES — restrict Docker management ports to LAN
*filter
:MEDIASTACK-DOCKER-RESTRICT - [0:0]

# Jump from DOCKER-USER into our chain
-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT

# Allow private networks to all Docker ports
-A MEDIASTACK-DOCKER-RESTRICT -s 127.0.0.0/8 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 10.0.0.0/8 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 172.16.0.0/12 -j RETURN
-A MEDIASTACK-DOCKER-RESTRICT -s 192.168.0.0/16 -j RETURN

# DROP non-private traffic to LAN-only Docker ports.
# Split into two multiport rules — iptables -m multiport caps at 15 ports
# per match (kernel limit). Going over yields:
#     iptables-restore: too many ports specified
# which silently breaks ufw reload, leaves UFW in a half-loaded state, and
# cascades through Docker bridge networking on the next boot.
-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 8989,7878,9117,8080,5055,9000,81,51821 -j DROP
-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 8000,8090,3001,45876,8191,6767,8096,3000 -j DROP

# Allow everything else (public ports like 80 and 443 pass through)
-A MEDIASTACK-DOCKER-RESTRICT -j RETURN

COMMIT
# END MEDIASTACK-DOCKER-RULES
RULES
    fi

    # Surface ufw-init failures instead of silently swallowing them.
    # ufw reload returns 0 even when /etc/ufw/after.rules is broken — the
    # iptables-restore error only shows up at next ufw-init or system boot,
    # far from where the bad rule was added. Capture stderr explicitly.
    local ufw_err
    ufw_err=$(sudo ufw reload 2>&1 >/dev/null)
    if [[ -n "$ufw_err" ]] && echo "$ufw_err" | grep -qiE 'error|problem'; then
        log_warn "ufw reload reported issues:"
        echo "$ufw_err" | sed 's/^/  /' | head -5
        return 1
    fi

    if sudo iptables -L DOCKER-USER -n >/dev/null 2>&1 && ! ufw_docker_jump_live; then
        log_warn "Docker LAN-only restriction jump is still missing from DOCKER-USER after UFW reload."
        return 1
    fi
}

# The after.rules block appends `-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT`
# on every full UFW load (iptables-restore --noflush never flushes DOCKER-USER),
# so the jump accumulates one copy per `ufw reload`. We cannot flush DOCKER-USER
# (fail2ban parks its own f2b-* jumps there) and cannot delete-before-add inside
# after.rules (iptables-restore aborts the whole batch on an absent rule). So the
# jump stays in after.rules (fail-closed: it always exists after a load) and this
# after.init hook — run by ufw-init at the end of every start/reload — trims any
# duplicates back to one. Emitted as literal text for /etc/ufw/after.init.
_ufw_docker_dedup_block() {
    cat <<'DEDUP'
# >>> MEDIASTACK-DOCKER-DEDUP — keep exactly one DOCKER-USER→RESTRICT jump
    while [ "$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT')" -gt 1 ]; do
        iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || break
    done
# <<< MEDIASTACK-DOCKER-DEDUP
DEDUP
}

setup_ufw_docker_dedup_hook() {
    local after_init="$MEDIASTACK_UFW_AFTER_INIT"

    # Idempotent: our marker already present -> nothing to do.
    if sudo test -f "$after_init" && sudo grep -q 'MEDIASTACK-DOCKER-DEDUP' "$after_init"; then
        log_skip "Docker jump dedup hook already installed"
        return
    fi

    local created=false was_executable=false
    if sudo test -f "$after_init"; then
        sudo test -x "$after_init" && was_executable=true
    else
        created=true
    fi

    if [[ "$created" == "true" ]]; then
        # No stock sample present — write a minimal MediaStack-owned hook.
        {
            printf '%s\n' '#!/bin/sh' \
                '# after.init — MediaStack-managed; trims duplicate DOCKER-USER jumps.' \
                'set -e' \
                'case "$1" in' \
                'start)'
            _ufw_docker_dedup_block
            printf '%s\n' '    ;;' 'esac'
        } | sudo tee "$after_init" >/dev/null
        _ms_state_set UFW_AFTER_INIT_CREATED true
    else
        # Existing after.init (stock Canonical sample on a normal install):
        # inject inside the existing start) arm. Injecting there — rather than
        # appending a second case block — keeps us safe from a trailing exit and
        # from a second exiting *) default. Refuse to edit a file without a clean
        # stock start) arm (re-run invariant: warn + skip, never auto-reconcile).
        if ! sudo grep -qE '^[[:space:]]*start\)[[:space:]]*$' "$after_init"; then
            log_warn "Custom /etc/ufw/after.init present; skipping the DOCKER-USER dedup hook."
            log_warn "Add the MEDIASTACK-DOCKER-DEDUP snippet to its start) arm by hand if you want it."
            return
        fi
        local block_file tmp
        block_file=$(mktemp)
        tmp=$(mktemp)
        _ufw_docker_dedup_block >"$block_file"
        # Insert the block after the first start) line only. sudo reads the
        # root-owned file; awk and the redirect stay unprivileged (bf and tmp
        # are our own temp files).
        sudo cat "$after_init" | awk -v bf="$block_file" '
            { print }
            /^[[:space:]]*start\)[[:space:]]*$/ && !done {
                while ((getline line < bf) > 0) print line
                close(bf)
                done = 1
            }
        ' >"$tmp"
        # Never overwrite the live hook unless the block actually landed.
        if ! grep -q 'MEDIASTACK-DOCKER-DEDUP' "$tmp"; then
            rm -f "$block_file" "$tmp"
            log_warn "Could not inject the DOCKER-USER dedup block into /etc/ufw/after.init; skipping."
            return
        fi
        sudo tee "$after_init" >/dev/null <"$tmp"
        rm -f "$block_file" "$tmp"
        # We injected into a pre-existing file — we did NOT create the whole
        # thing. Record that so a later uninstall strips only our block instead
        # of rm-ing the file (clears any stale =true left by an earlier
        # created-install whose file was since replaced out-of-band).
        _ms_state_set UFW_AFTER_INIT_CREATED false
    fi

    # Make it runnable only if it wasn't already — never re-mode an admin's
    # executable hook. The state flag mirrors "we flipped the exec bit".
    if [[ "$was_executable" == "false" ]]; then
        sudo chmod 750 "$after_init"
        [[ "$created" == "false" ]] && _ms_state_set UFW_AFTER_INIT_ACTIVATED true
    fi

    # Normalize any duplicates that already accumulated, without waiting for the
    # next reload. Safe any time: it only ever deletes surplus copies of our jump.
    sudo "$after_init" start >/dev/null 2>&1 || true

    log_ok "Docker jump dedup hook installed"
}

# ---------------------------------------------------------------------------
# Uninstall: reverse MediaStack UFW changes
# ---------------------------------------------------------------------------

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

    if sudo test -f "$MEDIASTACK_UFW_AFTER_RULES"; then
        sudo sed -i '/^# MEDIASTACK-DOCKER-RULES/,/^# END MEDIASTACK-DOCKER-RULES$/d' "$MEDIASTACK_UFW_AFTER_RULES" || return 1
    fi
    # Reverse the DOCKER-USER dedup hook — but only while our marker is still
    # present, so we never delete or edit a file an admin has since replaced.
    if sudo test -f "$MEDIASTACK_UFW_AFTER_INIT" \
        && sudo grep -q 'MEDIASTACK-DOCKER-DEDUP' "$MEDIASTACK_UFW_AFTER_INIT"; then
        if [[ "$(_ms_state_get UFW_AFTER_INIT_CREATED 2>/dev/null || true)" == "true" ]]; then
            # We wrote the whole file; drop it.
            sudo rm -f "$MEDIASTACK_UFW_AFTER_INIT" || return 1
        else
            # Injected into a pre-existing file; strip our block, restore mode.
            sudo sed -i '/^# >>> MEDIASTACK-DOCKER-DEDUP/,/^# <<< MEDIASTACK-DOCKER-DEDUP$/d' "$MEDIASTACK_UFW_AFTER_INIT" || return 1
            if [[ "$(_ms_state_get UFW_AFTER_INIT_ACTIVATED 2>/dev/null || true)" == "true" ]]; then
                sudo chmod 640 "$MEDIASTACK_UFW_AFTER_INIT" || return 1
            fi
        fi
    fi
    sudo ufw reload >/dev/null 2>&1 || return 1
    while sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1; do
        sudo iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT || return 1
    done
    if sudo iptables -L MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1; then
        sudo iptables -F MEDIASTACK-DOCKER-RESTRICT \
            && sudo iptables -X MEDIASTACK-DOCKER-RESTRICT || return 1
    fi
    sudo grep -q '^# MEDIASTACK-DOCKER-RULES' "$MEDIASTACK_UFW_AFTER_RULES" 2>/dev/null && return 1
    sudo iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT >/dev/null 2>&1 && return 1

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

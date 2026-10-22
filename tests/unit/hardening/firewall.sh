# Owns: UFW, SSH, and Docker firewall behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/firewall.sh.

# ===========================================================================
# setup_ufw — skip path repairs SSH policy when service + Docker markers exist
# ===========================================================================

UFW_CALLS=()
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "2222/tcp                   ALLOW       Anywhere"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        if [[ "$*" == *"# MEDIASTACK-DOCKER-RULES"* ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "tee" ]]; then
        UFW_CALLS+=("$*")
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}

UFW_CALLS=()
SSH_CONNECTION="198.51.100.10 55123 192.0.2.20 2222"
setup_ufw
found_reset=false
found_tee=false
found_ssh_10=false
found_ssh_172=false
found_ssh_192=false
found_ssh_broad_delete=false
found_active_client=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"reset"* ]] && found_reset=true
    [[ "$c" == *"tee"* ]] && found_tee=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 2222 proto tcp"* ]] && found_ssh_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 2222 proto tcp"* ]] && found_ssh_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 2222 proto tcp"* ]] && found_ssh_192=true
    [[ "$c" == *"allow from 198.51.100.10 to any port 2222 proto tcp"* ]] && found_active_client=true
    [[ "$c" == *"delete allow 2222/tcp"* ]] && found_ssh_broad_delete=true
done
assert_eq "false" "$found_reset" "setup_ufw: skip path — no reset when active + service/Docker markers"
assert_eq "false" "$found_tee" "setup_ufw: skip path — no after.rules write"
assert_eq "true" "$found_ssh_10" "setup_ufw: skip path — repairs active SSH port allow for 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: skip path — repairs active SSH port allow for 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: skip path — repairs active SSH port allow for 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: skip path — preserves current non-private SSH client IP"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: skip path — preserves pre-existing broad SSH allow"
unset -f sudo ufw
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — never writes the admin-port filter into after.rules/after6.rules
# (the filter is admin-filter.sh's, UFW on or off)
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
DOCKER6_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "22/tcp                     ALLOW       Anywhere"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        UFW_CALLS+=("$*")
        if [[ "$*" == *after6.rules* ]]; then
            DOCKER6_RULES="$(cat)"
        elif [[ "$*" == *after.rules* ]]; then
            DOCKER_RULES="$(cat)"
        fi
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}

UFW_CALLS=()
setup_ufw

found_reset=false
found_ssh_broad_delete=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"reset"* ]] && found_reset=true
    [[ "$c" == *"delete allow 22/tcp"* ]] && found_ssh_broad_delete=true
done
assert_eq "false" "$found_reset" "setup_ufw: active marker repair — no firewall reset"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: active marker repair — preserves broad SSH allow"
# Given UFW is active and neither after file carries a MediaStack block
# When setup_ufw runs
# Then it writes neither file: the admin-port filter is not UFW's
assert_eq "" "$DOCKER_RULES" "setup_ufw: writes no admin-port block to after.rules"
assert_eq "" "$DOCKER6_RULES" "setup_ufw: writes no admin-port block to after6.rules"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — does not reload UFW or look at DOCKER-USER
# ===========================================================================

# Given UFW is configured and Docker's chain has no MediaStack jump
# When setup_ufw runs
# Then it neither reloads UFW (a reload appends jumps behind Docker's RETURN) nor touches iptables
UFW_TRACE=$(mktemp)
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    [[ "${1:-}" == "grep" ]] && return 1
    [[ "${1:-}" == "iptables" && "${2:-}" == "-C" ]] && return 1
    [[ "${1:-}" == "tee" ]] && cat >/dev/null
    return 0
}
ufw() { :; }
setup_ufw >/dev/null 2>&1
ufw_trace_text=$(cat "$UFW_TRACE")
assert_not_contains "$ufw_trace_text" "ufw reload" "setup_ufw: never reloads UFW for the admin-port filter"
assert_not_contains "$ufw_trace_text" "iptables" "setup_ufw: never reads or edits DOCKER-USER"
assert_not_contains "$ufw_trace_text" "after.rules" "setup_ufw: never writes after.rules"
assert_not_contains "$ufw_trace_text" "after6.rules" "setup_ufw: never writes after6.rules"
rm -f "$UFW_TRACE"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — reentrancy (day-2 OFF -> ON): the mediastack UFW toggle resets
# UFW_DEFAULTS_APPLIED on the OFF path precisely so a later ON reconfigures.
# A stale "true" latch + non-'deny allow' defaults (what a full _uninstall_ufw
# leaves behind) trips the early-return guard and the firewall never comes back.
# ===========================================================================

# Case A: post-reset ledger (UFW_DEFAULTS_APPLIED=false) -> setup_ufw proceeds.
UFW_CALLS=()
_ms_state_get() { echo false; } # reset latch
_ufw_defaults() { echo ""; }    # inactive UFW reports no defaults
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        [[ "${2:-}" == "status" ]] && echo "Status: inactive"
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}
# shellcheck disable=SC2034
SSH_CONNECTION=""
setup_ufw
found_configure=false
for c in "${UFW_CALLS[@]}"; do [[ "$c" == *"default deny incoming"* ]] && found_configure=true; done
assert_eq "true" "$found_configure" "setup_ufw: reentrancy — reset latch (DEFAULTS_APPLIED=false) lets a re-enable reconfigure"
unset -f sudo ufw _ms_state_get _ufw_defaults

# Case B: stale latch (UFW_DEFAULTS_APPLIED=true) + non-'deny allow' defaults
# -> early return, no reconfigure (this is the bug the OFF-path reset avoids).
UFW_CALLS=()
_ms_state_get() { [[ "$1" == "UFW_DEFAULTS_APPLIED" ]] && echo true || echo false; }
_ufw_defaults() { echo "allow allow"; }
sudo() {
    [[ "${1:-}" == "ufw" ]] && UFW_CALLS+=("$*")
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}
setup_ufw
ufw_rc=$?
found_configure=false
for c in "${UFW_CALLS[@]}"; do [[ "$c" == *"default deny incoming"* ]] && found_configure=true; done
assert_eq "0" "$ufw_rc" "setup_ufw: reentrancy — stale latch returns cleanly (leaves UFW unchanged)"
assert_eq "false" "$found_configure" "setup_ufw: reentrancy — stale latch (DEFAULTS_APPLIED=true) blocks reconfigure (why OFF must reset it)"
unset -f sudo ufw _ms_state_get _ufw_defaults
# Restore the module-level ledger stubs for the tests below.
_ms_state_set() { :; }
_ms_state_get() { echo false; }

# ===========================================================================
# setup_ufw — fresh path (verify correct ufw commands called)
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
DOCKER6_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: inactive"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        if [[ "$*" == *after6.rules* ]]; then
            DOCKER6_RULES="$(cat)"
        elif [[ "$*" == *after.rules* ]]; then
            DOCKER_RULES="$(cat)"
        fi
        return 0
    fi
    return 0
}

UFW_CALLS=()
setup_ufw

found_reset=false
found_enable=false
found_8096=false
found_3000=false
found_45876=false
found_ssh_broad=false
found_ssh_10=false
found_ssh_172=false
found_ssh_192=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"--force reset"* ]] && found_reset=true
    [[ "$c" == *"--force enable"* ]] && found_enable=true
    [[ "$c" == *"8096/tcp"* ]] && found_8096=true
    [[ "$c" == *"3000/tcp"* ]] && found_3000=true
    [[ "$c" == *"45876"* ]] && found_45876=true
    [[ "$c" == "ufw allow 22/tcp"* ]] && found_ssh_broad=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 22 proto tcp"* ]] && found_ssh_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 22 proto tcp"* ]] && found_ssh_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 22 proto tcp"* ]] && found_ssh_192=true
done
assert_eq "false" "$found_reset" "setup_ufw: fresh path — preserves pre-existing UFW rules"
assert_eq "true" "$found_enable" "setup_ufw: fresh path — ufw enable called"
assert_eq "false" "$found_8096" "setup_ufw: fresh path — Jellyfin 8096 not directly allowed"
assert_eq "false" "$found_3000" "setup_ufw: fresh path — Homepage 3000 not directly allowed"
assert_eq "true" "$found_45876" "setup_ufw: fresh path — Beszel bridge marker allowed"
assert_eq "false" "$found_ssh_broad" "setup_ufw: fresh path — SSH is not open to all sources"
assert_eq "true" "$found_ssh_10" "setup_ufw: fresh path — SSH allows 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: fresh path — SSH allows 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: fresh path — SSH allows 192.168.0.0/16"
assert_eq "" "$DOCKER_RULES$DOCKER6_RULES" "setup_ufw: fresh path — no admin-port rules written to the after files"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================

# The admin-port filter (rule source, systemd path, apply script, handover).
source "$HARDENING_TEST_DIR/hardening/admin-filter.sh"

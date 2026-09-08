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
assert_eq "false" "$found_tee" "setup_ufw: skip path — no Docker rule rewrite when persisted and live"
assert_eq "true" "$found_ssh_10" "setup_ufw: skip path — repairs active SSH port allow for 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: skip path — repairs active SSH port allow for 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: skip path — repairs active SSH port allow for 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: skip path — preserves current non-private SSH client IP"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: skip path — preserves pre-existing broad SSH allow"
unset -f sudo ufw
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — active service marker repairs missing Docker after.rules block
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
        else
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
assert_contains "$DOCKER_RULES" "# MEDIASTACK-DOCKER-RULES" "setup_ufw: active marker repair — writes missing Docker rules block"
assert_contains "$DOCKER_RULES" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "setup_ufw: active marker repair — writes DOCKER-USER jump"
assert_contains "$DOCKER_RULES" "-p udp -m multiport --dports 7359 -j DROP" \
    "setup_ufw: IPv4 block DROPs the published UDP admin port (Jellyfin discovery)"

# The IPv6 mirror. after6.rules is loaded by ip6tables-restore from its own
# file, so an absent mirror means every admin port is unfiltered the moment
# Docker gains an IPv6 bridge.
assert_contains "$DOCKER6_RULES" "# MEDIASTACK-DOCKER-RULES" \
    "setup_ufw: writes the Docker rules block to after6.rules"
assert_contains "$DOCKER6_RULES" ":MEDIASTACK-DOCKER-RESTRICT - [0:0]" \
    "setup_ufw: IPv6 block declares the same chain name"
assert_contains "$DOCKER6_RULES" ":DOCKER-USER - [0:0]" \
    "setup_ufw: IPv6 block declares DOCKER-USER (ip6tables-restore aborts on a missing chain)"
assert_contains "$DOCKER6_RULES" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" \
    "setup_ufw: IPv6 block writes the DOCKER-USER jump"
assert_contains "$DOCKER6_RULES" "-A MEDIASTACK-DOCKER-RESTRICT -s ::1/128 -j RETURN" \
    "setup_ufw: IPv6 block RETURNs loopback"
assert_contains "$DOCKER6_RULES" "-A MEDIASTACK-DOCKER-RESTRICT -s fc00::/7 -j RETURN" \
    "setup_ufw: IPv6 block RETURNs unique-local"
assert_contains "$DOCKER6_RULES" "-A MEDIASTACK-DOCKER-RESTRICT -s fe80::/10 -j RETURN" \
    "setup_ufw: IPv6 block RETURNs link-local"
assert_contains "$DOCKER6_RULES" "-p tcp -m multiport --dports 8989,7878,9117,8080,5055,9000,81,51821 -j DROP" \
    "setup_ufw: IPv6 block DROPs the first TCP admin-port group"
assert_contains "$DOCKER6_RULES" "-p tcp -m multiport --dports 8000,8090,3001,45876,8191,6767,8096,3000 -j DROP" \
    "setup_ufw: IPv6 block DROPs the second TCP admin-port group"
assert_contains "$DOCKER6_RULES" "-p udp -m multiport --dports 7359 -j DROP" \
    "setup_ufw: IPv6 block DROPs the published UDP admin port"
assert_contains "$DOCKER6_RULES" "# END MEDIASTACK-DOCKER-RULES" \
    "setup_ufw: IPv6 block carries the teardown end marker"
# The DROP list is the thing that must not drift between families.
assert_eq "$(grep -c -- '-j DROP' <<<"$DOCKER_RULES")" "$(grep -c -- '-j DROP' <<<"$DOCKER6_RULES")" \
    "setup_ufw: IPv4 and IPv6 blocks DROP the same number of port groups"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — active service marker reloads persisted rules when live jump is missing
# ===========================================================================

UFW_TRACE=$(mktemp)
UFW_RELOADED="$UFW_TRACE.reloaded"
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        elif [[ "${2:-}" == "reload" ]]; then
            touch "$UFW_RELOADED"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        if [[ "${2:-}" == "-L" ]]; then
            return 0
        fi
        if [[ "${2:-}" == "-C" ]]; then
            [[ -f "$UFW_RELOADED" ]]
            return $?
        fi
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() { :; }

setup_ufw
ufw_trace_text=$(cat "$UFW_TRACE")

if echo "$ufw_trace_text" | grep -Fq "ufw --force reset"; then
    fail "setup_ufw: live jump repair — no firewall reset" "$ufw_trace_text"
else
    pass "setup_ufw: live jump repair — no firewall reset"
fi
if echo "$ufw_trace_text" | grep -Fq "tee -a /etc/ufw/after.rules"; then
    fail "setup_ufw: live jump repair — reuses persisted Docker rules" "$ufw_trace_text"
else
    pass "setup_ufw: live jump repair — reuses persisted Docker rules"
fi
if echo "$ufw_trace_text" | grep -Fq "ufw reload"; then
    pass "setup_ufw: live jump repair — reloads UFW to restore DOCKER-USER jump"
else
    fail "setup_ufw: live jump repair — reloads UFW to restore DOCKER-USER jump" "$ufw_trace_text"
fi
rm -f "$UFW_TRACE" "$UFW_RELOADED"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — active service marker surfaces UFW reload errors
# ===========================================================================

UFW_TRACE=$(mktemp)
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        elif [[ "${2:-}" == "reload" ]]; then
            echo "ERROR: problem running ufw-init" >&2
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    return 0
}
ufw() { :; }

ufw_output=$(setup_ufw 2>&1)
ufw_rc=$?
assert_eq "1" "$ufw_rc" "setup_ufw: reload error repair — surfaces failure"
assert_contains "$ufw_output" "ERROR: problem running ufw-init" "setup_ufw: reload error repair — reports ufw-init failure"
if grep -Fq "ufw --force reset" "$UFW_TRACE"; then
    fail "setup_ufw: reload error repair — no firewall reset" "$(cat "$UFW_TRACE")"
else
    pass "setup_ufw: reload error repair — no firewall reset"
fi
rm -f "$UFW_TRACE"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — active service marker surfaces a missing live jump after reload
# ===========================================================================

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
    if [[ "${1:-}" == "grep" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        if [[ "${2:-}" == "-L" ]]; then
            return 0
        fi
        if [[ "${2:-}" == "-C" ]]; then
            return 1
        fi
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() { :; }
log_warn() { echo "$*"; }

ufw_output=$(setup_ufw 2>&1)
ufw_rc=$?
assert_eq "1" "$ufw_rc" "setup_ufw: missing jump after reload — surfaces failure"
assert_contains "$ufw_output" "Docker LAN-only restriction jump is still missing" "setup_ufw: missing jump after reload — reports missing jump"
if grep -Fq "ufw reload" "$UFW_TRACE"; then
    pass "setup_ufw: missing jump after reload — attempted UFW reload"
else
    fail "setup_ufw: missing jump after reload — attempted UFW reload" "$(cat "$UFW_TRACE")"
fi
rm -f "$UFW_TRACE"
log_warn() { :; }
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
        else
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
assert_contains "$DOCKER_RULES" "8096,3000 -j DROP" "setup_ufw: Docker rules block Jellyfin and Homepage from WAN"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================

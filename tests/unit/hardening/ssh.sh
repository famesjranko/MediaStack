# Owns: SSH-focused UFW behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/ssh.sh.

# setup_ufw — fresh path preserves the active public SSH client
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
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
        # shellcheck disable=SC2034
        DOCKER_RULES="$(cat)"
        : "$DOCKER_RULES"
        return 0
    fi
    return 0
}

SSH_CONNECTION="198.51.100.10 55123 192.0.2.20 2222"
UFW_CALLS=()
setup_ufw

found_2222_broad=false
found_2222_10=false
found_2222_172=false
found_2222_192=false
found_active_client=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == "ufw allow 2222/tcp"* ]] && found_2222_broad=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 2222 proto tcp"* ]] && found_2222_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 2222 proto tcp"* ]] && found_2222_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 2222 proto tcp"* ]] && found_2222_192=true
    [[ "$c" == *"allow from 198.51.100.10 to any port 2222 proto tcp"* ]] && found_active_client=true
done
assert_eq "false" "$found_2222_broad" "setup_ufw: active public SSH — server port is not open to all sources"
assert_eq "true" "$found_2222_10" "setup_ufw: active public SSH — non-standard port allows 10.0.0.0/8"
assert_eq "true" "$found_2222_172" "setup_ufw: active public SSH — non-standard port allows 172.16.0.0/12"
assert_eq "true" "$found_2222_192" "setup_ufw: active public SSH — non-standard port allows 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: active public SSH — preserves current non-private client IP"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — fresh path does not add redundant exact rules for LAN SSH clients
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
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
        DOCKER_RULES="$(cat)"
        return 0
    fi
    return 0
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SSH_CONNECTION="192.168.1.50 55123 192.168.1.20 2222"
UFW_CALLS=()
setup_ufw

found_lan_exact=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"allow from 192.168.1.50 to any port 2222 proto tcp"* ]] && found_lan_exact=true
done
assert_eq "false" "$found_lan_exact" "setup_ufw: active LAN SSH — RFC1918 rule covers client without exact host allow"
unset -f sudo
unset SSH_CONNECTION

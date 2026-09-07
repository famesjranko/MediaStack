# Owns: configurable UFW service-port behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/ports.sh.

# ===========================================================================
# setup_ufw_service_ports — opens torrent + VPN ports from .env
# ===========================================================================

UFW_CALLS=()
ufw() { :; }
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        return 0
    fi
    return 0
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
TORRENT_PORT="50000"
DOMAIN="media.example.com"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
WG_PORT="51999"

UFW_CALLS=()
setup_ufw_service_ports

found_torrent_tcp=false
found_torrent_udp=false
found_wg=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"50000/tcp"* ]] && found_torrent_tcp=true
    [[ "$c" == *"50000/udp"* ]] && found_torrent_udp=true
    [[ "$c" == *"51999/udp"* ]] && found_wg=true
done
assert_eq "true" "$found_torrent_tcp" "setup_ufw_service_ports: opens custom torrent TCP port"
assert_eq "true" "$found_torrent_udp" "setup_ufw_service_ports: opens custom torrent UDP port"
assert_eq "true" "$found_wg" "setup_ufw_service_ports: opens custom WireGuard port when domain set"

# Without domain — WireGuard port should not be opened
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DOMAIN="example.com"
UFW_CALLS=()
setup_ufw_service_ports

found_wg_nodomain=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"51999/udp"* ]] && found_wg_nodomain=true
done
assert_eq "false" "$found_wg_nodomain" "setup_ufw_service_ports: skips WireGuard port without domain"
unset -f sudo ufw

# ===========================================================================
# setup_ufw_service_ports — changing TORRENT_PORT revokes the rule we own for
# the old port. Guards the defect: the allow was only ever added, so every
# re-run after a port change left the previous port open forever.
# ===========================================================================

# A stub that models the rule table rather than just recording calls: revocation
# is only correct if the table ends up with one rule per tag, and a call log
# cannot show that.
UFW_TABLE=("9999/tcp|user backup port")
UFW_CALLS=()
ufw() { :; }
sudo() {
    [[ "${1:-}" == "ufw" ]] || return 0
    UFW_CALLS+=("${*:2}")
    local i=1 entry kept=()
    case "${2:-}" in
        allow)
            UFW_TABLE+=("$3|${*:5}")
            ;;
        status)
            [[ "${3:-}" == "numbered" ]] || return 0
            for entry in "${UFW_TABLE[@]}"; do
                printf '[%2d] %-26s ALLOW IN    Anywhere                   # %s\n' \
                    "$i" "${entry%%|*}" "${entry##*|}"
                i=$((i + 1))
            done
            ;;
        --force)
            [[ "${3:-}" == "delete" ]] || return 0
            for entry in "${UFW_TABLE[@]}"; do
                [[ "$i" == "${4:-}" ]] || kept+=("$entry")
                i=$((i + 1))
            done
            UFW_TABLE=("${kept[@]}")
            ;;
    esac
    return 0
}

# Fixtures consumed by the sourced product code under test.
# shellcheck disable=SC2034
DOMAIN="example.com"
# shellcheck disable=SC2034
TORRENT_PORT="50000"
setup_ufw_service_ports

# shellcheck disable=SC2034
TORRENT_PORT="50001"
UFW_CALLS=()
setup_ufw_service_ports

found_delete=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == "--force delete "* ]] && found_delete=true
done
assert_eq "true" "$found_delete" \
    "setup_ufw_service_ports: deletes the tagged rule for the superseded torrent port"

table_text=$(printf '%s\n' "${UFW_TABLE[@]}")
assert_eq "1" "$(grep -c '^50001/tcp|MediaStack:Torrent-TCP$' <<<"$table_text")" \
    "setup_ufw_service_ports: exactly one Torrent-TCP rule, on the current port"
assert_eq "1" "$(grep -c '^50001/udp|MediaStack:Torrent-UDP$' <<<"$table_text")" \
    "setup_ufw_service_ports: exactly one Torrent-UDP rule, on the current port"
assert_eq "0" "$(grep -c '^50000/' <<<"$table_text")" \
    "setup_ufw_service_ports: no rule remains for the superseded torrent port"
assert_contains "$table_text" "9999/tcp|user backup port" \
    "setup_ufw_service_ports: untagged user rules are never deleted"
unset -f sudo ufw

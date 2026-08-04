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

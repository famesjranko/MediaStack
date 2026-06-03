#!/usr/bin/env bash
# tests/unit/stage2-wireguard.sh
#
# Contract tests for Stage 2 WireGuard access-tier env mapping (ADR-29).
# Tiers map to (a) WG_INIT_ALLOWED_IPS — what the client routes through the
# tunnel, and (b) wg_firewall_ips_for_tier output — what wg-easy enforces
# server-side. Per-client firewall is on for every tier.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-wireguard"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/lib/network.sh" ]] && source "$REPO_ROOT/scripts/lib/network.sh"
[[ -f "$REPO_ROOT/scripts/setup/stages/stage2.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

set +e
set +u

if ! type stage2_wireguard_access_tier_env >/dev/null 2>&1; then
    stage2_wireguard_access_tier_env() { printf '__not_implemented__'; }
fi
if ! type wg_firewall_ips_for_tier >/dev/null 2>&1; then
    wg_firewall_ips_for_tier() { printf '__not_implemented__'; }
fi

# -----------------------------------------------------------------------------
# stage2_wireguard_access_tier_env — env-line emission per tier
# -----------------------------------------------------------------------------

full_lan_env="$(stage2_wireguard_access_tier_env full-lan "192.168.1.0/24" "192.168.1.50")"
assert_contains "$full_lan_env" "WG_ACCESS_TIER='full-lan'" "ADR-29: full-lan persists tier"
assert_contains "$full_lan_env" "WG_LAN_CIDR='192.168.1.0/24'" "ADR-29: full-lan persists LAN CIDR"
assert_contains "$full_lan_env" "WG_SERVER_LAN_IP='192.168.1.50'" "ADR-29: full-lan persists server IP"
assert_contains "$full_lan_env" "WG_INIT_ALLOWED_IPS='192.168.1.0/24'" "ADR-29: full-lan routes LAN CIDR"
assert_contains "$full_lan_env" "WG_PER_CLIENT_FIREWALL='true'" "ADR-29: full-lan keeps firewall on"

server_env="$(stage2_wireguard_access_tier_env server "" "192.168.1.50")"
assert_contains "$server_env" "WG_ACCESS_TIER='server'" "ADR-29: server persists tier"
assert_contains "$server_env" "WG_INIT_ALLOWED_IPS='192.168.1.50/32'" "ADR-29: server routes only server /32"
assert_contains "$server_env" "WG_PER_CLIENT_FIREWALL='true'" "ADR-29: server keeps firewall on"

containers_env="$(stage2_wireguard_access_tier_env containers "" "192.168.1.50")"
assert_contains "$containers_env" "WG_ACCESS_TIER='containers'" "ADR-29: containers persists tier"
assert_contains "$containers_env" "WG_INIT_ALLOWED_IPS='192.168.1.50/32'" "ADR-29: containers routes only server /32"
assert_contains "$containers_env" "WG_PER_CLIENT_FIREWALL='true'" "ADR-29: containers keeps firewall on"

streaming_env="$(stage2_wireguard_access_tier_env streaming "" "192.168.1.50")"
assert_contains "$streaming_env" "WG_ACCESS_TIER='streaming'" "ADR-29: streaming persists tier"
assert_contains "$streaming_env" "WG_INIT_ALLOWED_IPS='192.168.1.50/32'" "ADR-29: streaming routes only server /32"
assert_contains "$streaming_env" "WG_PER_CLIENT_FIREWALL='true'" "ADR-29: streaming keeps firewall on"

# Unknown tier rejected.
if stage2_wireguard_access_tier_env bogus "" "" 2>/dev/null; then
    fail "ADR-29: stage2_wireguard_access_tier_env rejects unknown tier"
else
    pass "ADR-29: stage2_wireguard_access_tier_env rejects unknown tier"
fi

# full-lan requires lan_cidr.
if stage2_wireguard_access_tier_env full-lan "" "192.168.1.50" 2>/dev/null; then
    fail "ADR-29: full-lan requires non-empty LAN CIDR"
else
    pass "ADR-29: full-lan requires non-empty LAN CIDR"
fi

# server tier requires server_ip.
if stage2_wireguard_access_tier_env server "" "" 2>/dev/null; then
    fail "ADR-29: server tier requires non-empty server IP"
else
    pass "ADR-29: server tier requires non-empty server IP"
fi

# -----------------------------------------------------------------------------
# wg_firewall_ips_for_tier — server-side firewallIps shape per tier
# -----------------------------------------------------------------------------

fw_full_lan="$(wg_firewall_ips_for_tier full-lan "192.168.1.0/24" "192.168.1.50")"
assert_eq "192.168.1.0/24" "$fw_full_lan" "ADR-29: full-lan firewallIps = LAN CIDR (all ports)"

fw_server="$(wg_firewall_ips_for_tier server "" "192.168.1.50")"
assert_eq "192.168.1.50/32" "$fw_server" "ADR-29: server firewallIps = server /32 (all ports incl. host services)"

fw_streaming="$(wg_firewall_ips_for_tier streaming "" "192.168.1.50")"
assert_eq "192.168.1.50:8096/tcp,192.168.1.50:5055/tcp,192.168.1.50:3000/tcp" "$fw_streaming" \
    "ADR-29: streaming firewallIps = Jellyfin+Jellyseerr+Homepage only"

fw_containers="$(wg_firewall_ips_for_tier containers "" "192.168.1.50")"
# containers tier exposes 17 MediaStack ports — assert key ones are present and 51821 (wg-easy admin) is excluded.
assert_contains "$fw_containers" "192.168.1.50:8096/tcp" "ADR-29: containers exposes Jellyfin"
assert_contains "$fw_containers" "192.168.1.50:5055/tcp" "ADR-29: containers exposes Jellyseerr"
assert_contains "$fw_containers" "192.168.1.50:3000/tcp" "ADR-29: containers exposes Homepage"
assert_contains "$fw_containers" "192.168.1.50:8989/tcp" "ADR-29: containers exposes Sonarr"
assert_contains "$fw_containers" "192.168.1.50:7878/tcp" "ADR-29: containers exposes Radarr"
assert_contains "$fw_containers" "192.168.1.50:7359/udp" "ADR-29: containers exposes Jellyfin auto-discovery UDP"
assert_contains "$fw_containers" "192.168.1.50:81/tcp" "ADR-29: containers exposes NPM admin"
if [[ "$fw_containers" == *":51821/"* ]]; then
    fail "ADR-29: containers tier MUST NOT expose wg-easy admin (51821)"
else
    pass "ADR-29: containers tier excludes wg-easy admin (51821)"
fi

# -----------------------------------------------------------------------------
# detect_lan_cidr — normalize host CIDR to network CIDR
# -----------------------------------------------------------------------------

if type detect_lan_cidr >/dev/null 2>&1; then
    # Stub `ip` so the parsing/normalization path is exercised deterministically.
    _fake_ip() {
        case "$*" in
            "-4 route show default") printf 'default via 192.168.1.1 dev eth0 proto dhcp metric 100\n' ;;
            "-4 -o addr show "*) printf '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0\n' ;;
        esac
    }
    detected=$(ip() { _fake_ip "$@"; }; detect_lan_cidr)
    assert_eq "192.168.1.0/24" "$detected" "ADR-29: detect_lan_cidr normalizes host CIDR to network CIDR"

    # Failure path: no default route → empty + non-zero.
    if (ip() { return 1; }; detect_lan_cidr >/dev/null 2>&1); then
        fail "ADR-29: detect_lan_cidr returns non-zero when no default route"
    else
        pass "ADR-29: detect_lan_cidr returns non-zero when no default route"
    fi
fi

# -----------------------------------------------------------------------------
# Drift guard: the containers-tier port list in scripts/lib/network.sh is a
# centralized static contract. This test parses docker-compose.yml and asserts
# the contract matches every published port on a MediaStack service except the
# two excluded by design: WG_PORT (UDP, VPN handshake) and 51821 (wg-easy admin).
# Adding/removing a service port without updating wg_firewall_ips_for_tier
# will fail this test.
# -----------------------------------------------------------------------------

if type wg_firewall_ips_for_tier >/dev/null 2>&1; then
    compose_ports=$(python3 -c '
import re, sys, yaml
with open("'"$REPO_ROOT"'/docker-compose.yml") as f:
    compose = yaml.safe_load(f)
ports = set()
for name, svc in (compose.get("services") or {}).items():
    for spec in (svc.get("ports") or []):
        if not isinstance(spec, str):
            continue
        if "${" in spec:  # ${WG_PORT} entry — VPN handshake, not a service
            continue
        # "8096:8096" or "8096:8096/udp"
        m = re.match(r"^([0-9]+):[0-9]+(?:/(tcp|udp))?$", spec)
        if not m:
            continue
        host_port, proto = m.group(1), (m.group(2) or "tcp")
        ports.add(f"{host_port}/{proto}")
ports.discard("51821/tcp")  # wg-easy admin — excluded by design
print(",".join(sorted(ports)))
')
    contract_ports=$(wg_firewall_ips_for_tier containers "" "192.168.1.50" | \
        python3 -c '
import sys
raw = sys.stdin.read().strip()
out = set()
for entry in raw.split(","):
    if ":" in entry:
        out.add(entry.split(":", 1)[1])
print(",".join(sorted(out)))
')
    assert_eq "$compose_ports" "$contract_ports" \
        "drift guard: containers-tier port list matches docker-compose.yml (excluding WG_PORT and 51821)"
fi

scenario_end "$CURRENT_SCENARIO"
summary

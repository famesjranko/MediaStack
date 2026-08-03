#!/usr/bin/env python3
"""Select a non-conflicting MediaStack Docker subnet."""

from __future__ import annotations

import ipaddress
import json
import os
import pathlib
import re
import sys


def valid_prefix(value):
    if not re.fullmatch(r"172\.(1[6-9]|2[0-9]|3[0-1])\.(0|[1-9][0-9]{0,2})", value or ""):
        return False
    try:
        return 0 <= int(value.rsplit(".", 1)[1]) <= 255
    except ValueError:
        return False


def net_for_prefix(prefix):
    return ipaddress.ip_network(f"{prefix}.0/24")


def parse_network(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return None
    if net.version == 4 and net.prefixlen != 0:
        return net
    return None


def add_network(items, cidr, source):
    net = parse_network(cidr)
    if net is not None:
        items.append((net, source))


def docker_networks(path):
    text = path.read_text().strip()
    if not text:
        return []
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out = []
    for item in data:
        if not isinstance(item, dict):
            continue
        name = str(item.get("Name") or "")
        network_id = str(item.get("Id") or "")
        options = item.get("Options") or {}
        interfaces = set()
        if name:
            interfaces.add(name)
            interfaces.add(f"br-{name}")
        if network_id:
            interfaces.add(f"br-{network_id[:12]}")
        if isinstance(options, dict):
            bridge_name = options.get("com.docker.network.bridge.name")
            if bridge_name:
                interfaces.add(str(bridge_name))
        for cfg in (item.get("IPAM") or {}).get("Config") or []:
            subnet = cfg.get("Subnet") if isinstance(cfg, dict) else None
            gateway = cfg.get("Gateway") if isinstance(cfg, dict) else None
            if subnet:
                out.append(
                    {
                        "name": name,
                        "subnet": subnet,
                        "gateway": gateway or "",
                        "interfaces": sorted(interfaces),
                    }
                )
    return out


def source_interface(source):
    raw = source.split(": ", 1)[1] if ": " in source else source
    route_match = re.search(r"(?:^|\s)dev\s+(\S+)", raw)
    if route_match:
        return route_match.group(1).split("@", 1)[0]
    addr_match = re.match(r"\d+:\s+([^:\s]+)", raw)
    if addr_match:
        return addr_match.group(1).split("@", 1)[0]
    return ""


def prefix_from_net(net):
    parts = str(net.network_address).split(".")
    prefix = ".".join(parts[:3])
    return prefix if valid_prefix(prefix) else ""


def main() -> int:
    routes_path, addrs_path, docker_path, mediastack_path = map(pathlib.Path, sys.argv[1:5])
    requested_prefix = os.environ.get("REQUESTED_PREFIX", "")
    requested_subnet = os.environ.get("REQUESTED_SUBNET", "")
    requested_gateway = os.environ.get("REQUESTED_GATEWAY", "")
    stage1_complete = os.environ.get("STAGE1_COMPLETE", "") == "1"

    existing_mediastack = []
    for item in docker_networks(mediastack_path):
        net = parse_network(item["subnet"])
        if net is not None:
            existing_mediastack.append(
                {
                    "net": net,
                    "gateway": item.get("gateway") or "",
                    "interfaces": set(item.get("interfaces") or []),
                }
            )

    conflicts: list[tuple[ipaddress._BaseNetwork, str]] = []
    for line in routes_path.read_text().splitlines():
        parts = line.split()
        if not parts or parts[0] == "default":
            continue
        token = parts[0]
        if "/" not in token:
            token = f"{token}/32"
        route_net = parse_network(token)
        if route_net is not None and route_net.prefixlen <= 1:
            continue
        add_network(conflicts, token, f"host route: {line}")

    for line in addrs_path.read_text().splitlines():
        parts = line.split()
        for idx, part in enumerate(parts):
            if part == "inet" and idx + 1 < len(parts):
                add_network(conflicts, parts[idx + 1], f"host address: {line}")
                break

    for item in docker_networks(docker_path):
        name = item["name"]
        if name == "mediastack":
            continue
        add_network(conflicts, item["subnet"], f"Docker network {name}")

    def is_own_mediastack_source(net, source):
        iface = source_interface(source)
        if not iface:
            return False
        for own in existing_mediastack:
            if net.overlaps(own["net"]) and iface in own["interfaces"]:
                return True
        return False

    def conflicts_for(candidate):
        return [
            (net, source)
            for net, source in conflicts
            if candidate.overlaps(net) and not is_own_mediastack_source(net, source)
        ]

    def ordered_prefixes():
        seen = set()
        preferred = []
        if valid_prefix(requested_prefix):
            preferred.append(requested_prefix)
        preferred.extend(["172.28.0", "172.29.0", "172.30.0", "172.31.0"])
        for prefix in preferred:
            if prefix not in seen:
                seen.add(prefix)
                yield prefix
        for second in range(16, 32):
            for third in range(0, 256):
                prefix = f"172.{second}.{third}"
                if prefix not in seen:
                    seen.add(prefix)
                    yield prefix

    def existing_record_for_prefix(prefix):
        candidate = net_for_prefix(prefix)
        for own in existing_mediastack:
            if candidate.subnet_of(own["net"]):
                return own
        return None

    def requested_record_for_prefix(prefix):
        if not valid_prefix(prefix):
            return None
        net = parse_network(requested_subnet) if requested_subnet else net_for_prefix(prefix)
        if net is None:
            return None
        if prefix_from_net(net) != prefix:
            return None
        npm_ip = ipaddress.ip_address(f"{prefix}.10")
        if npm_ip not in net:
            return None
        gateway = requested_gateway or f"{prefix}.1"
        try:
            gateway_ip = ipaddress.ip_address(gateway)
        except ValueError:
            gateway = f"{prefix}.1"
            gateway_ip = ipaddress.ip_address(gateway)
        if gateway_ip not in net:
            gateway = f"{prefix}.1"
            gateway_ip = ipaddress.ip_address(gateway)
        if gateway_ip not in net:
            return None
        return {"net": net, "gateway": gateway, "interfaces": set()}

    def first_existing_record():
        for own in existing_mediastack:
            prefix = prefix_from_net(own["net"])
            if prefix:
                return prefix, own
        return "", None

    def emit_values(prefix, subnet=None, gateway=None):
        print(f"MEDIASTACK_NETWORK_PREFIX={prefix}")
        print(f"MEDIASTACK_SUBNET={subnet or f'{prefix}.0/24'}")
        print(f"MEDIASTACK_GATEWAY={gateway or f'{prefix}.1'}")
        print(f"MEDIASTACK_NPM_IP={prefix}.10")

    if stage1_complete:
        locked_prefix, locked_record = first_existing_record()
        if not locked_prefix:
            locked_prefix = requested_prefix if valid_prefix(requested_prefix) else "172.28.0"
            locked_record = existing_record_for_prefix(
                locked_prefix
            ) or requested_record_for_prefix(locked_prefix)
        locked_net = locked_record["net"] if locked_record else net_for_prefix(locked_prefix)
        locked_conflicts = conflicts_for(locked_net)
        if locked_conflicts:
            print(
                f"ERROR: MediaStack is already installed with Docker subnet {locked_net}, "
                "but that range now overlaps host networking."
            )
            print(
                "INFO: This is usually caused by a LAN or VPN route using the same private range."
            )
            print("INFO: Disconnect or narrow the conflicting VPN/LAN route, then rerun setup.")
            print(
                "INFO: MediaStack will not silently migrate an existing install to a "
                "different Docker subnet."
            )
            for net, source in locked_conflicts[:6]:
                print(f"INFO: conflict: {net} ({source})")
            return 1
        emit_values(
            locked_prefix,
            str(locked_record["net"]) if locked_record else None,
            locked_record["gateway"] if locked_record else None,
        )
        return 0

    for prefix in ordered_prefixes():
        existing_record = existing_record_for_prefix(prefix)
        candidate = existing_record["net"] if existing_record else net_for_prefix(prefix)
        if not conflicts_for(candidate):
            emit_values(
                prefix,
                str(existing_record["net"]) if existing_record else None,
                existing_record["gateway"] if existing_record else None,
            )
            return 0

    print("ERROR: No available MediaStack Docker subnet found inside 172.16.0.0/12.")
    print(
        "INFO: A LAN, VPN, or corporate route appears to overlap every conservative "
        "Docker candidate."
    )
    print("INFO: Disconnect or narrow the conflicting VPN route, then rerun setup.")
    print(
        "INFO: MediaStack intentionally does not auto-pick 10.x or 192.168.x in this mode "
        "because qBittorrent and firewall trust rules are scoped to Docker's 172.16.0.0/12 range."
    )
    for net, source in conflicts[:8]:
        print(f"INFO: observed network: {net} ({source})")
    return 1


if __name__ == "__main__":
    sys.exit(main())

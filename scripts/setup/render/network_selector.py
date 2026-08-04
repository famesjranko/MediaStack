#!/usr/bin/env python3
"""Select a non-conflicting MediaStack Docker subnet."""

from __future__ import annotations

import dataclasses
import ipaddress
import json
import os
import pathlib
import re
import sys
from collections.abc import Iterator
from typing import Any

_MEDIASTACK_NETWORK_NAME = "mediastack"
_DEFAULT_NETWORK_PREFIX = "172.28.0"
_PREFERRED_NETWORK_PREFIXES = ("172.28.0", "172.29.0", "172.30.0", "172.31.0")
_NETWORK_SECOND_OCTET_START = 16
_NETWORK_SECOND_OCTET_END = 32
_NETWORK_THIRD_OCTET_END = 256
_NETWORK_CATCHALL_PREFIX_LENGTH = 1
_DEFAULT_NETWORK_GATEWAY_SUFFIX = ".1"
_DEFAULT_NPM_IP_SUFFIX = ".10"
_DOCKER_NETWORK_RANGE = "172.16.0.0/12"
_NETWORK_FIRST_OCTET = 172
_DEFAULT_ROUTE = "default"
_IPV4_ADDRESS_FAMILY = "inet"
_PREFIX_PATTERN = re.compile(r"172\.(1[6-9]|2[0-9]|3[0-1])\.(0|[1-9][0-9]{0,2})")


@dataclasses.dataclass
class _NetworkRecord:
    net: ipaddress.IPv4Network
    gateway: str
    interfaces: set[str]


_Conflict = tuple[ipaddress.IPv4Network, str]


def valid_prefix(value: str) -> bool:
    if not _PREFIX_PATTERN.fullmatch(value or ""):
        return False
    try:
        return 0 <= int(value.rsplit(".", 1)[1]) <= 255
    except ValueError:
        return False


def net_for_prefix(prefix: str) -> ipaddress.IPv4Network:
    return ipaddress.IPv4Network(f"{prefix}.0/24")


def parse_network(cidr: str) -> ipaddress.IPv4Network | None:
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return None
    if net.version == 4 and net.prefixlen != 0:
        return ipaddress.IPv4Network(net)
    return None


def add_network(items: list[_Conflict], cidr: str, source: str) -> None:
    net = parse_network(cidr)
    if net is not None:
        items.append((net, source))


def docker_networks(path: pathlib.Path) -> list[dict[str, Any]]:
    text = path.read_text().strip()
    if not text:
        return []
    try:
        data: Any = json.loads(text)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out: list[dict[str, Any]] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        name = str(item.get("Name") or "")
        network_id = str(item.get("Id") or "")
        options = item.get("Options") or {}
        interfaces: set[str] = set()
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


def source_interface(source: str) -> str:
    raw = source.split(": ", 1)[1] if ": " in source else source
    route_match = re.search(r"(?:^|\s)dev\s+(\S+)", raw)
    if route_match:
        return route_match.group(1).split("@", 1)[0]
    addr_match = re.match(r"\d+:\s+([^:\s]+)", raw)
    if addr_match:
        return addr_match.group(1).split("@", 1)[0]
    return ""


def prefix_from_net(net: ipaddress.IPv4Network) -> str:
    parts = str(net.network_address).split(".")
    prefix = ".".join(parts[:3])
    return prefix if valid_prefix(prefix) else ""


def _load_existing_records(path: pathlib.Path) -> list[_NetworkRecord]:
    records: list[_NetworkRecord] = []
    for item in docker_networks(path):
        net = parse_network(item["subnet"])
        if net is not None:
            records.append(
                _NetworkRecord(
                    net=net,
                    gateway=item.get("gateway") or "",
                    interfaces=set(item.get("interfaces") or []),
                )
            )
    return records


def _add_route_conflicts(conflicts: list[_Conflict], path: pathlib.Path) -> None:
    for line in path.read_text().splitlines():
        parts = line.split()
        if not parts or parts[0] == _DEFAULT_ROUTE:
            continue
        token = parts[0]
        if "/" not in token:
            token = f"{token}/32"
        route_net = parse_network(token)
        if route_net is not None and route_net.prefixlen <= _NETWORK_CATCHALL_PREFIX_LENGTH:
            continue
        add_network(conflicts, token, f"host route: {line}")


def _add_address_conflicts(conflicts: list[_Conflict], path: pathlib.Path) -> None:
    for line in path.read_text().splitlines():
        parts = line.split()
        for idx, part in enumerate(parts):
            if part == _IPV4_ADDRESS_FAMILY and idx + 1 < len(parts):
                add_network(conflicts, parts[idx + 1], f"host address: {line}")
                break


def _add_docker_conflicts(conflicts: list[_Conflict], path: pathlib.Path) -> None:
    for item in docker_networks(path):
        if item["name"] != _MEDIASTACK_NETWORK_NAME:
            add_network(conflicts, item["subnet"], f"Docker network {item['name']}")


def _collect_conflicts(
    routes_path: pathlib.Path, addrs_path: pathlib.Path, docker_path: pathlib.Path
) -> list[_Conflict]:
    conflicts: list[_Conflict] = []
    _add_route_conflicts(conflicts, routes_path)
    _add_address_conflicts(conflicts, addrs_path)
    _add_docker_conflicts(conflicts, docker_path)
    return conflicts


def _is_own_mediastack_source(
    net: ipaddress.IPv4Network, source: str, existing_records: list[_NetworkRecord]
) -> bool:
    iface = source_interface(source)
    if not iface:
        return False
    return any(net.overlaps(own.net) and iface in own.interfaces for own in existing_records)


def _conflicts_for(
    candidate: ipaddress.IPv4Network,
    conflicts: list[_Conflict],
    existing_records: list[_NetworkRecord],
) -> list[_Conflict]:
    return [
        (net, source)
        for net, source in conflicts
        if candidate.overlaps(net) and not _is_own_mediastack_source(net, source, existing_records)
    ]


def _ordered_prefixes(requested_prefix: str) -> Iterator[str]:
    seen: set[str] = set()
    preferred = [requested_prefix] if valid_prefix(requested_prefix) else []
    preferred.extend(_PREFERRED_NETWORK_PREFIXES)
    for prefix in preferred:
        if prefix not in seen:
            seen.add(prefix)
            yield prefix
    for second in range(_NETWORK_SECOND_OCTET_START, _NETWORK_SECOND_OCTET_END):
        for third in range(_NETWORK_THIRD_OCTET_END):
            prefix = f"{_NETWORK_FIRST_OCTET}.{second}.{third}"
            if prefix not in seen:
                seen.add(prefix)
                yield prefix


def _existing_record_for_prefix(
    prefix: str, existing_records: list[_NetworkRecord]
) -> _NetworkRecord | None:
    candidate = net_for_prefix(prefix)
    for own in existing_records:
        if candidate.subnet_of(own.net):
            return own
    return None


def _requested_record_for_prefix(
    prefix: str, requested_subnet: str, requested_gateway: str
) -> _NetworkRecord | None:
    if not valid_prefix(prefix):
        return None
    net = parse_network(requested_subnet) if requested_subnet else net_for_prefix(prefix)
    if net is None or prefix_from_net(net) != prefix:
        return None
    npm_ip = ipaddress.ip_address(f"{prefix}{_DEFAULT_NPM_IP_SUFFIX}")
    if npm_ip not in net:
        return None
    gateway = requested_gateway or f"{prefix}{_DEFAULT_NETWORK_GATEWAY_SUFFIX}"
    try:
        gateway_ip = ipaddress.ip_address(gateway)
    except ValueError:
        gateway = f"{prefix}{_DEFAULT_NETWORK_GATEWAY_SUFFIX}"
        gateway_ip = ipaddress.ip_address(gateway)
    if gateway_ip not in net:
        gateway = f"{prefix}{_DEFAULT_NETWORK_GATEWAY_SUFFIX}"
        gateway_ip = ipaddress.ip_address(gateway)
    if gateway_ip not in net:
        return None
    return _NetworkRecord(net=net, gateway=gateway, interfaces=set())


def _first_existing_record(
    existing_records: list[_NetworkRecord],
) -> tuple[str, _NetworkRecord | None]:
    for own in existing_records:
        prefix = prefix_from_net(own.net)
        if prefix:
            return prefix, own
    return "", None


def _emit_values(prefix: str, subnet: str | None = None, gateway: str | None = None) -> None:
    print(f"MEDIASTACK_NETWORK_PREFIX={prefix}")
    print(f"MEDIASTACK_SUBNET={subnet or f'{prefix}.0/24'}")
    print(f"MEDIASTACK_GATEWAY={gateway or f'{prefix}{_DEFAULT_NETWORK_GATEWAY_SUFFIX}'}")
    print(f"MEDIASTACK_NPM_IP={prefix}{_DEFAULT_NPM_IP_SUFFIX}")


def _emit_locked_values(
    requested_prefix: str,
    requested_subnet: str,
    requested_gateway: str,
    existing_records: list[_NetworkRecord],
    conflicts: list[_Conflict],
) -> int:
    locked_prefix, locked_record = _first_existing_record(existing_records)
    if not locked_prefix:
        locked_prefix = (
            requested_prefix if valid_prefix(requested_prefix) else _DEFAULT_NETWORK_PREFIX
        )
        locked_record = _existing_record_for_prefix(locked_prefix, existing_records)
        if locked_record is None:
            locked_record = _requested_record_for_prefix(
                locked_prefix, requested_subnet, requested_gateway
            )
    locked_net = locked_record.net if locked_record else net_for_prefix(locked_prefix)
    locked_conflicts = _conflicts_for(locked_net, conflicts, existing_records)
    if locked_conflicts:
        print(
            f"ERROR: MediaStack is already installed with Docker subnet {locked_net}, "
            "but that range now overlaps host networking."
        )
        print("INFO: This is usually caused by a LAN or VPN route using the same private range.")
        print("INFO: Disconnect or narrow the conflicting VPN/LAN route, then rerun setup.")
        print(
            "INFO: MediaStack will not silently migrate an existing install to a "
            "different Docker subnet."
        )
        for net, source in locked_conflicts[:6]:
            print(f"INFO: conflict: {net} ({source})")
        return 1
    _emit_values(
        locked_prefix,
        str(locked_record.net) if locked_record else None,
        locked_record.gateway if locked_record else None,
    )
    return 0


def _select_fresh_values(
    requested_prefix: str,
    conflicts: list[_Conflict],
    existing_records: list[_NetworkRecord],
) -> int:
    for prefix in _ordered_prefixes(requested_prefix):
        existing_record = _existing_record_for_prefix(prefix, existing_records)
        candidate = existing_record.net if existing_record else net_for_prefix(prefix)
        if not _conflicts_for(candidate, conflicts, existing_records):
            _emit_values(
                prefix,
                str(existing_record.net) if existing_record else None,
                existing_record.gateway if existing_record else None,
            )
            return 0

    print(f"ERROR: No available MediaStack Docker subnet found inside {_DOCKER_NETWORK_RANGE}.")
    print(
        "INFO: A LAN, VPN, or corporate route appears to overlap every conservative "
        "Docker candidate."
    )
    print("INFO: Disconnect or narrow the conflicting VPN route, then rerun setup.")
    print(
        "INFO: MediaStack intentionally does not auto-pick 10.x or 192.168.x in this mode "
        "because qBittorrent and firewall trust rules are scoped to Docker's "
        f"{_DOCKER_NETWORK_RANGE} range."
    )
    for net, source in conflicts[:8]:
        print(f"INFO: observed network: {net} ({source})")
    return 1


def main() -> int:
    routes_path, addrs_path, docker_path, mediastack_path = map(pathlib.Path, sys.argv[1:5])
    requested_prefix = os.environ.get("REQUESTED_PREFIX", "")
    requested_subnet = os.environ.get("REQUESTED_SUBNET", "")
    requested_gateway = os.environ.get("REQUESTED_GATEWAY", "")
    stage1_complete = os.environ.get("STAGE1_COMPLETE", "") == "1"

    existing_records = _load_existing_records(mediastack_path)
    conflicts = _collect_conflicts(routes_path, addrs_path, docker_path)
    if stage1_complete:
        return _emit_locked_values(
            requested_prefix,
            requested_subnet,
            requested_gateway,
            existing_records,
            conflicts,
        )
    return _select_fresh_values(requested_prefix, conflicts, existing_records)


if __name__ == "__main__":
    sys.exit(main())

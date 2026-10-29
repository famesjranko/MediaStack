"""Connect an existing IPv4 client through the published WireGuard UDP port.

The client uses the accepted image and export on a separate Docker network.
Only the endpoint address changes to reach the disposable Docker host. Keys,
allowed routes and the custom port come from the saved export.
"""

from __future__ import annotations

import base64
import configparser
import copy
import ipaddress
import pathlib
import subprocess
import sys

CLIENT_CONFIG = pathlib.Path("/tmp/ms-wireguard-client.conf")
CLIENT = "wireguard-migration-client"
NETWORK = "wireguard-migration-client"
TARGET = "192.168.50.10"
INTERFACE = "wg-fixture"


def docker(*args: str, data: str | None = None) -> str:
    # stderr can include upstream configuration or key material. The caller
    # reports a fixed error; neither stream may escape on a failed command.
    result = subprocess.run(
        ["docker", *args], input=data, text=True, capture_output=True, timeout=30, check=True
    )
    return result.stdout.strip()


def execute(*args: str) -> str:
    return docker("exec", CLIENT, *args)


def connect(image: str, exported: configparser.ConfigParser, attempts: int = 10) -> None:
    docker("network", "create", NETWORK)
    try:
        gateway = docker(
            "network", "inspect", "--format", "{{(index .IPAM.Config 0).Gateway}}", NETWORK
        )
        docker(
            "run",
            "-d",
            "--name",
            CLIENT,
            "--network",
            NETWORK,
            "--cap-add",
            "NET_ADMIN",
            "--entrypoint",
            "sleep",
            image,
            "infinity",
        )
        configure(exported, gateway)
        # A local server address supplies a deterministic tunnel destination;
        # LAN forwarding and public WAN routing remain separate host proofs.
        docker("exec", "wireguard", "ip", "address", "replace", TARGET + "/32", "dev", "lo")
        for _ in range(attempts):
            try:
                execute("ping", "-n", "-c", "1", "-W", "1", "-I", INTERFACE, TARGET)
            except subprocess.CalledProcessError:
                continue
            key, stamp = execute("wg", "show", INTERFACE, "latest-handshakes").split()
            if key != exported["Peer"]["PublicKey"] or int(stamp) <= 0:
                raise ValueError("client traffic has no authenticated WireGuard handshake")
            return
        raise ValueError("existing WireGuard client cannot send tunnel traffic")
    finally:
        # Attempt both operations even if container removal fails.
        try:
            docker("rm", "-fv", CLIENT)
        finally:
            docker("network", "rm", NETWORK)


def configure(exported: configparser.ConfigParser, gateway: str) -> None:
    peer = {key: exported["Peer"][key] for key in ("PublicKey", "PresharedKey", "AllowedIPs")}
    port = int(exported["Peer"]["Endpoint"].rsplit(":", 1)[1])
    peer["Endpoint"] = f"{gateway}:{port}"
    config = (
        "\n".join(
            ["[Interface]", "PrivateKey = " + exported["Interface"]["PrivateKey"], "[Peer]"]
            + [f"{key} = {value}" for key, value in peer.items()]
        )
        + "\n"
    )
    docker("exec", "-i", CLIENT, "sh", "-c", "umask 077; cat >/tmp/client.conf", data=config)
    execute("ip", "link", "add", INTERFACE, "type", "wireguard")
    execute("wg", "setconf", INTERFACE, "/tmp/client.conf")
    address = next(
        ipaddress.ip_interface(value.strip())
        for value in exported["Interface"]["Address"].split(",")
        if ipaddress.ip_interface(value.strip()).version == 4
    )
    execute("ip", "address", "add", str(address), "dev", INTERFACE)
    execute("ip", "link", "set", INTERFACE, "up")
    for value in peer["AllowedIPs"].split(","):
        route = ipaddress.ip_network(value.strip())
        if route.version == 4:
            execute("ip", "route", "add", str(route), "dev", INTERFACE)
    route_output = execute("ip", "route", "get", TARGET)
    if f"dev {INTERFACE} " not in route_output + " ":
        raise ValueError("fixture traffic does not use the WireGuard interface")


def probe(image: str, exported: configparser.ConfigParser) -> None:
    """Both blocked UDP and a wrong client key must fail on a real server."""
    rule = (
        "INPUT",
        "-p",
        "udp",
        "--dport",
        exported["Peer"]["Endpoint"].rsplit(":", 1)[1],
        "-j",
        "DROP",
    )
    docker("exec", "wireguard", "iptables", "-I", *rule)
    try:
        reject(image, exported)
    finally:
        docker("exec", "wireguard", "iptables", "-D", *rule)
    broken = copy.deepcopy(exported)
    key = bytearray(base64.b64decode(exported["Peer"]["PresharedKey"], validate=True))
    if len(key) != 32:
        raise ValueError("invalid client preshared key")
    key[0] ^= 1
    broken["Peer"]["PresharedKey"] = base64.b64encode(key).decode()
    reject(image, broken)
    connect(image, exported)


def reject(image: str, exported: configparser.ConfigParser) -> None:
    try:
        connect(image, exported, attempts=3)
    except ValueError as error:
        if str(error) != "existing WireGuard client cannot send tunnel traffic":
            raise
    else:
        raise ValueError("WireGuard tunnel check accepted a broken connection")


def main() -> None:
    exported = configparser.ConfigParser(interpolation=None)
    exported.read_string(CLIENT_CONFIG.read_text())
    image = sys.argv[2]
    if sys.argv[1] == "probe":
        probe(image, exported)
    elif sys.argv[1] == "check":
        connect(image, exported)
    else:
        raise ValueError("expected probe or check")


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        KeyError,
        IndexError,
        StopIteration,
        OSError,
        configparser.Error,
        subprocess.SubprocessError,
    ):
        sys.exit("WireGuard existing-client tunnel check failed; no receipt is authorized")

"""Seed and compare wg-easy peer migration through its API and kernel interface.

Only hashes of keys and exported configurations enter the saved snapshot. Checks
are read-only so a candidate cannot repair missing state before comparison.
"""

from __future__ import annotations

import base64
import configparser
import hashlib
import json
import pathlib
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

STATE = pathlib.Path("/tmp/ms-wireguard-state.json")
CLIENT_CONFIG = pathlib.Path("/tmp/ms-wireguard-client.conf")
PEER_FIELDS = (
    "id",
    "name",
    "enabled",
    "ipv4Address",
    "ipv6Address",
    "expiresAt",
    "allowedIps",
    "serverAllowedIps",
    "firewallIps",
    "dns",
    "mtu",
    "persistentKeepalive",
    "serverEndpoint",
    "preUp",
    "postUp",
    "preDown",
    "postDown",
)


def digest(value: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("missing WireGuard key or configuration")
    return hashlib.sha256(value.encode()).hexdigest()


def command(*args: str) -> str:
    return subprocess.check_output(["docker", "exec", "wireguard", *args], text=True, timeout=20)


class Client:
    def __init__(self) -> None:
        env = {}
        for line in pathlib.Path(".env").read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key] = " ".join(shlex.split(value))
        auth = f"{env['JELLYFIN_ADMIN_USER']}:{env['JELLYFIN_ADMIN_PASSWORD']}"
        self.authorization = "Basic " + base64.b64encode(auth.encode()).decode()

    def call(self, path: str, body: Any = None, *, raw: bool = False) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            "http://127.0.0.1:51821/api" + path,
            data=data,
            headers={"Authorization": self.authorization, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                result = response.read().decode()
        except urllib.error.HTTPError as error:
            # v15 may persist a mutation before its IPv6 firewall command fails.
            # Only seeding tolerates that response; seed() requires read-back.
            if data is None or error.code != 500:
                raise ValueError(f"WireGuard request failed: {path} HTTP {error.code}") from None
            return None
        return result if raw else json.loads(result)

    def peers(self) -> list[dict[str, Any]]:
        peers: list[dict[str, Any]] = self.call("/client")
        if not isinstance(peers, list) or not peers:
            raise ValueError("WireGuard peer inventory is empty or invalid")
        return peers

    def seed(self) -> None:
        for name, enabled in (("migration-enabled", True), ("migration-disabled", False)):
            self.call("/client", {"name": name, "expiresAt": None})
            rows = [peer for peer in self.peers() if peer["name"] == name]
            if len(rows) != 1:
                raise ValueError("WireGuard fixture peer was not created exactly once")
            path = f"/client/{rows[0]['id']}"
            body = self.call(path)
            body.update(
                enabled=enabled,
                expiresAt="2099-12-31T23:59:59.000Z",
                allowedIps=["192.168.50.0/24"],
                firewallIps=["192.168.50.10/32"],
                dns=["9.9.9.9"],
                mtu=1380,
                persistentKeepalive=17,
            )
            self.call(path, body)
            actual = self.call(path)
            if any(actual[key] != body[key] for key in PEER_FIELDS):
                raise ValueError("WireGuard fixture settings were not persisted")

    def snapshot(self) -> dict[str, Any]:
        peers = {}
        for row in self.peers():
            peer = self.call(f"/client/{row['id']}")
            saved = {key: peer[key] for key in PEER_FIELDS}
            config = self.call(f"/client/{row['id']}/configuration", raw=True)
            exported = configparser.ConfigParser(interpolation=None)
            exported.read_string(config)
            saved["keys"] = {
                "publicKey": digest(peer["publicKey"]),
                "privateKey": digest(exported["Interface"]["PrivateKey"]),
                "preSharedKey": digest(exported["Peer"]["PresharedKey"]),
                "serverPublicKey": digest(exported["Peer"]["PublicKey"]),
            }
            saved["configuration"] = digest(config)
            peers[str(peer["id"])] = saved
        names = {peer["name"] for peer in peers.values()}
        if not {"admin", "migration-enabled", "migration-disabled"} <= names:
            raise ValueError("WireGuard migration fixture peers are missing")
        interface = self.call("/admin/interface")
        if interface["firewallEnabled"] is not True:
            raise ValueError("WireGuard per-client firewall was lost")
        kernel = kernel_state()
        expected = {
            peer["keys"]["publicKey"]: peer["keys"]["preSharedKey"]
            for peer in peers.values()
            if peer["enabled"]
        }
        loaded = {key: peer["psk"] for key, peer in kernel["peers"].items()}
        if expected != loaded:
            raise ValueError("WireGuard enabled peers or keys are not loaded in the kernel")
        if any(peer["keys"]["serverPublicKey"] != kernel["public"] for peer in peers.values()):
            raise ValueError("WireGuard export does not match the running server key")
        return {"peers": peers, "kernel": kernel, "firewallEnabled": True}

    def probe(self) -> None:
        """Prove the comparison notices a real user setting changed on the server."""
        previous = self.snapshot()
        peer = next(row for row in self.peers() if row["name"] == "migration-disabled")
        path = f"/client/{peer['id']}"
        original = self.call(path)
        changed = dict(original, mtu=original["mtu"] + 16)
        try:
            self.call(path, changed)
            current = self.snapshot()
            if current == previous:
                raise ValueError("WireGuard fixture mutation was not persisted")
            try:
                check(previous, current)
            except ValueError:
                pass
            else:
                raise ValueError("WireGuard comparison missed a changed peer")
        finally:
            self.call(path, original)
        check(previous, self.snapshot())


def kernel_state() -> dict[str, Any]:
    lines = command("wg", "show", "wg0", "dump").splitlines()
    private, public, port, mark = lines[0].split("\t")
    peers = {}
    for line in lines[1:]:
        key, psk, _endpoint, allowed, _handshake, _rx, _tx, keepalive = line.split("\t")
        peers[digest(key)] = {
            "psk": digest(psk),
            "allowed": sorted(allowed.split(",")),
            "keepalive": keepalive,
        }
    if not peers:
        raise ValueError("WireGuard kernel has no active peers")
    return {
        "private": digest(private),
        "public": digest(public),
        "port": port,
        "mark": mark,
        "peers": peers,
    }


def check(previous: dict[str, Any], current: dict[str, Any]) -> None:
    changed = [
        key for key in previous.keys() | current.keys() if previous.get(key) != current.get(key)
    ]
    if changed:
        raise ValueError("WireGuard migration changed: " + ", ".join(sorted(changed)))


def main() -> None:
    client = Client()
    action = sys.argv[1]
    if action == "seed":
        client.seed()
    elif action == "probe":
        client.probe()
    elif action == "save":
        STATE.write_text(json.dumps(client.snapshot(), sort_keys=True))
        peer = next(row for row in client.peers() if row["name"] == "migration-enabled")
        # Keep the accepted export private and reuse it after migration. Fetching
        # another export on the candidate could hide a rotated client key.
        CLIENT_CONFIG.touch(mode=0o600)
        CLIENT_CONFIG.write_text(client.call(f"/client/{peer['id']}/configuration", raw=True))
    elif action == "check":
        check(json.loads(STATE.read_text()), client.snapshot())
    else:
        raise ValueError("expected seed, probe, save or check")


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        KeyError,
        IndexError,
        OSError,
        configparser.Error,
        subprocess.SubprocessError,
    ):
        # Exceptions from upstream may embed response bodies or key material.
        sys.exit("WireGuard migration state check failed; no receipt is authorized")

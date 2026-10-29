"""Exercise real NPM renewal and compare disk leaves with fresh SNI TLS connections.

Runs inside disposable DinD with the repository's Pebble ACME override only.
"""

import contextlib
import hashlib
import json
import socket
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, cast

STATE = Path("/tmp/npm-renewal-state.json")
EMAIL = "renewal@example.test"
PASSWORD = "disposable-renewal-password"
DOMAINS = ("jellyfin.renewal.test", "seerr.renewal.test")


def api(path: str, body: dict[str, Any], token: str = "") -> dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"http://127.0.0.1:81/api/{path}", json.dumps(body).encode(), headers
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return cast("dict[str, Any]", json.load(response))


def disk_fingerprint(cert_id: int) -> str:
    pem = Path(f"config/npm/letsencrypt/live/npm-{cert_id}/cert.pem").read_text()
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def served_fingerprint(domain: str) -> str:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with (
        socket.create_connection(("127.0.0.1", 443), timeout=3) as connection,
        context.wrap_socket(connection, server_hostname=domain) as tls,
    ):
        cert = tls.getpeercert(binary_form=True)
    if cert is None:
        raise RuntimeError("TLS peer did not supply a certificate")
    return hashlib.sha256(cert).hexdigest()


def require_served(domain: str, expected: str) -> None:
    deadline = time.monotonic() + 15
    actual = "unavailable"
    while time.monotonic() < deadline:
        with contextlib.suppress(OSError):
            actual = served_fingerprint(domain)
        if actual == expected:
            print(f"{domain}: served=disk={expected}", flush=True)
            return
        time.sleep(0.25)
    raise RuntimeError(f"{domain}: disk={expected} served={actual} after 15s")


def seed() -> None:
    api(
        "users",
        {
            "name": "Renewal fixture",
            "nickname": "Renewal",
            "email": EMAIL,
            "roles": ["admin"],
            "is_disabled": False,
            "auth": {"type": "password", "secret": PASSWORD},
        },
    )
    token = api("tokens", {"identity": EMAIL, "secret": PASSWORD})["token"]
    certificates = {}
    for domain in DOMAINS:
        cert = api(
            "nginx/certificates",
            {"provider": "letsencrypt", "domain_names": [domain], "meta": {}},
            token,
        )
        cert_id = int(cert["id"])
        api(
            "nginx/proxy-hosts",
            {
                "domain_names": [domain],
                "forward_scheme": "http",
                "forward_host": "127.0.0.1",
                "forward_port": 9,
                "access_list_id": 0,
                "certificate_id": cert_id,
                "ssl_forced": True,
                "meta": {},
                "advanced_config": "",
                "locations": [],
                "block_exploits": True,
                "caching_enabled": False,
                "allow_websocket_upgrade": False,
                "http2_support": False,
                "hsts_enabled": False,
                "hsts_subdomains": False,
            },
            token,
        )
        require_served(domain, disk_fingerprint(cert_id))
        # Certbot saves the deploy hook as renew_hook; pre-fix certificates lack it.
        renewal = Path(f"config/npm/letsencrypt/renewal/npm-{cert_id}.conf")
        lines = renewal.read_text().splitlines(keepends=True)
        renewal.write_text(
            "".join(line for line in lines if line.split("=", 1)[0].strip() != "renew_hook")
        )
        certificates[domain] = cert_id
    STATE.write_text(json.dumps(certificates))


def renew(scheduled: bool) -> None:
    certificates = json.loads(STATE.read_text())
    token = api("tokens", {"identity": EMAIL, "secret": PASSWORD})["token"]
    before = {domain: disk_fingerprint(cid) for domain, cid in certificates.items()}

    if scheduled:
        # Given both certificates are due according to NPM's database.
        with sqlite3.connect("config/npm/data/database.sqlite") as db:
            db.executemany(
                "UPDATE certificate SET expires_on = '2000-01-01 00:00:00' WHERE id = ?",
                [(cid,) for cid in certificates.values()],
            )

        # When the actual timer callback runs, without waiting its one-hour interval.
        subprocess.run(
            ["docker", "exec", "-i", "-w", "/app", "npm", "node", "--input-type=module"],
            input="""
import certificates from './internal/certificate.js';
certificates.processExpiringHosts();
const deadline = Date.now() + 120000;
const poll = setInterval(() => {
    if (!certificates.intervalProcessing) process.exit(0);
    if (Date.now() > deadline) process.exit(1);
}, 100);
""",
            text=True,
            check=True,
            timeout=150,
        )
        for domain, cid in certificates.items():
            require_renewed(domain, cid, before[domain])
    else:
        for domain, cid in certificates.items():
            # Given an HTTPS proxy already serves this certificate.
            require_served(domain, before[domain])

            # When renewal succeeds through NPM's public API.
            api(f"nginx/certificates/{cid}/renew", {}, token)

            # Then new TLS connections receive the renewed leaf for this SNI name.
            require_renewed(domain, cid, before[domain])


def require_renewed(domain: str, cert_id: int, previous: str) -> None:
    renewed = disk_fingerprint(cert_id)
    if renewed == previous:
        raise RuntimeError(f"{domain}: renewal did not replace the leaf certificate")
    print(f"{domain}: previous={previous} renewed={renewed}", flush=True)
    require_served(domain, renewed)


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed()
    else:
        renew(scheduled=sys.argv[1] == "scheduled")

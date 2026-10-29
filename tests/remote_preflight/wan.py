"""Public DNS, HTTPS content, certificate and firewall probes from the operator host."""

from __future__ import annotations

import hashlib
import http.client
import json
import re
import socket
import ssl
import time
from typing import Any

from preflight.model import ROOT

from .gcp import command


def dns_ready(hosts: list[str], ip: str) -> None:
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        found = []
        for host in hosts:
            try:
                data = command(["getent", "ahostsv4", host], timeout=10).decode()
            except RuntimeError:
                data = ""
            found.append({line.split()[0] for line in data.splitlines()} == {ip})
        if all(found):
            return
        time.sleep(5)
    raise ValueError("public DNS did not converge to the disposable VM within 180 seconds")


def https(host: str, ip: str, path: str, cert_hash: str, port: int = 443) -> dict[str, Any]:
    # Staging chains are untrusted. Bind TLS to the exact certificate inspected
    # on the candidate instead of treating any successful -k request as proof.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with (
        socket.create_connection((ip, port), timeout=10) as sock,
        context.wrap_socket(sock, server_hostname=host) as tls,
    ):
        if hashlib.sha256(tls.getpeercert(binary_form=True) or b"").hexdigest() != cert_hash:
            raise ValueError("public HTTPS served a different certificate")
        tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
        response = http.client.HTTPResponse(tls)
        response.begin()
        if response.status != 200:
            raise ValueError("public HTTPS returned a non-200 response")
        value: dict[str, Any] = json.loads(response.read(1_000_000))
        return value


def check(domain: str, ip: str, state: dict[str, Any]) -> None:
    hosts = [f"{app}.{domain}" for app in ("jellyfin", "seerr")]
    dns_ready(hosts, ip)
    for host in hosts:
        proxy = next(h for h in state["hosts"] if host in h["domain_names"])
        cert_hash = state[f"certificate/{proxy['certificate_id']}"]
        path = "/System/Info/Public" if host == hosts[0] else "/api/v1/status"
        body = https(host, ip, path, cert_hash)
        required = ("Id", "Version") if host == hosts[0] else ("version",)
        if any(not body.get(key) for key in required):
            raise ValueError("public HTTPS did not reach the expected application")
    text = (ROOT / "scripts/setup/hardening/admin-filter.sh").read_text()
    match = re.search(r"^ADMIN_FILTER_TCP_GROUPS=\((.*)\)$", text, re.M)
    ports = set(re.findall(r"\d+", match[1])) if match else set()
    if not ports:
        raise ValueError("canonical admin port population is empty")
    for port in sorted(ports):
        try:
            conn = socket.create_connection((ip, int(port)), timeout=3)
        except (TimeoutError, ConnectionRefusedError):
            continue
        else:
            conn.close()
            raise ValueError(f"admin TCP port {port} is reachable from WAN")

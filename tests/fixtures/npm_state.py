"""NPM migration oracle on a disposable host. No API bodies or credentials are logged."""

from __future__ import annotations

import hashlib
import json
import pathlib
import shlex
import ssl
import subprocess
import sys
import urllib.request
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from npm_renewal import require_served
from upgrade_state import changed_keys, fingerprint, read_env

STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
PEBBLE = "https://pebble:14000/dir"
STATE = pathlib.Path("/tmp/ms-npm-before.json")
HOST_FIELDS = (
    "id",
    "domain_names",
    "forward_scheme",
    "forward_host",
    "forward_port",
    "certificate_id",
    "enabled",
    "ssl_forced",
    "advanced_config",
    "locations",
    "access_list_id",
    "block_exploits",
    "allow_websocket_upgrade",
    "http2_support",
    "caching_enabled",
    "hsts_enabled",
    "hsts_subdomains",
)


def prepare() -> None:
    values = json.load(sys.stdin)
    updates = {key: values[key] for key in ("DOMAIN", "NPM_ADMIN_EMAIL")}
    updates.update(NPM_LE_SERVER=STAGING, REMOTE_WEB_STATE="unchecked", IMAGE_CHANNEL="stable")
    env = pathlib.Path(".env")
    lines = env.read_text().splitlines() if env.exists() else []
    lines = [line for line in lines if line.partition("=")[0] not in updates]
    lines.extend(f"{key}={shlex.quote(value)}" for key, value in updates.items())
    env.write_text("\n".join(lines) + "\n")
    env.chmod(0o600)


class Npm:
    def __init__(self, base: str = "http://127.0.0.1:81/api") -> None:
        self.env = read_env()
        self.acme = self.env.get("NPM_LE_SERVER", STAGING)
        if self.acme not in (STAGING, PEBBLE):
            raise ValueError("NPM fixtures require staging or Pebble ACME")
        self.base = base
        self.token = ""
        result = self.call(
            "/tokens",
            {
                "identity": self.env["NPM_ADMIN_EMAIL"],
                "secret": self.env["JELLYFIN_ADMIN_PASSWORD"],
            },
        )
        self.token = result["token"]
        if not self.token:
            raise ValueError("NPM login returned no token")

    def call(self, path: str, body: Any = None, method: str | None = None) -> Any:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            self.base + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers,
            method=method,
        )
        with urllib.request.urlopen(request, timeout=240) as response:
            return json.load(response)

    @staticmethod
    def cert_bytes(cert_id: int) -> bytes:
        path = f"/etc/letsencrypt/live/npm-{cert_id}/fullchain.pem"
        return subprocess.check_output(["docker", "exec", "npm", "cat", path], timeout=20)

    def snapshot(self) -> dict[str, Any]:
        hosts = self.call("/nginx/proxy-hosts")
        certs = self.call("/nginx/certificates")
        required = {f"{app}.{self.env['DOMAIN']}" for app in ("jellyfin", "seerr")}
        managed = [h for h in hosts if set(h["domain_names"]) & required]
        domains = {name for h in managed for name in h["domain_names"]}
        if (
            not required <= domains
            or len(managed) != 2
            or any(
                not h["enabled"] or not h["ssl_forced"] or not h["certificate_id"] for h in managed
            )
        ):
            raise ValueError("required HTTPS proxy hosts are missing or disabled")
        if not any(h["domain_names"] == ["upgrade-fixture.invalid"] for h in hosts):
            raise ValueError("NPM lost the deliberate user proxy fixture")
        admin = self.call("/users/me")
        result: dict[str, Any] = {
            "admin": {key: admin[key] for key in ("id", "email", "roles", "is_disabled")},
            "hosts": sorted(
                [{key: h[key] for key in HOST_FIELDS} for h in hosts], key=lambda h: h["id"]
            ),
            "certificates": sorted(
                [{key: c[key] for key in ("id", "provider", "domain_names")} for c in certs],
                key=lambda c: c["id"],
            ),
            "credential": fingerprint(self.env["JELLYFIN_ADMIN_PASSWORD"]),
        }
        for host in managed:
            cert_id = host["certificate_id"]
            cert = next(c for c in certs if c["id"] == cert_id)
            if cert["provider"] != "letsencrypt":
                raise ValueError("managed proxy uses a non-ACME certificate")
            pem = self.cert_bytes(cert_id)
            issuer = subprocess.check_output(
                ["openssl", "x509", "-noout", "-issuer"], input=pem, timeout=10
            )
            expected_issuer = b"PEBBLE" if self.acme == PEBBLE else b"STAGING"
            if expected_issuer not in issuer.upper():
                raise ValueError("certificate is not from the fixture ACME issuer")
            subprocess.run(
                ["openssl", "x509", "-noout", "-checkend", "0"],
                input=pem,
                capture_output=True,
                timeout=10,
                check=True,
            )
            for domain in host["domain_names"]:
                subprocess.run(
                    ["openssl", "x509", "-noout", "-checkhost", domain],
                    input=pem,
                    capture_output=True,
                    timeout=10,
                    check=True,
                )
            conf = f"/etc/letsencrypt/renewal/npm-{cert_id}.conf"
            renewal = subprocess.check_output(["docker", "exec", "npm", "cat", conf], timeout=20)
            if self.acme.encode() not in renewal:
                raise ValueError("certificate renewal does not use the fixture ACME server")
            leaf = pem.decode().split("-----END CERTIFICATE-----", 1)[0]
            der = ssl.PEM_cert_to_DER_cert(leaf + "-----END CERTIFICATE-----\n")
            result[f"certificate/{cert_id}"] = hashlib.sha256(der).hexdigest()
            key = subprocess.check_output(
                [
                    "docker",
                    "exec",
                    "npm",
                    "cat",
                    f"/etc/letsencrypt/live/npm-{cert_id}/privkey.pem",
                ],
                timeout=20,
            )
            if not key.strip():
                raise ValueError("managed certificate private key is missing")
            result[f"private-key/{cert_id}"] = hashlib.sha256(key).hexdigest()
        return result

    def seed(self) -> None:
        body = {
            "domain_names": ["upgrade-fixture.invalid"],
            "forward_scheme": "http",
            "forward_host": "jellyfin",
            "forward_port": 8096,
            "certificate_id": 0,
            "enabled": False,
            "ssl_forced": False,
            "advanced_config": "# user fixture",
            "locations": [
                {
                    "path": "/fixture",
                    "forward_scheme": "http",
                    "forward_host": "jellyfin",
                    "forward_port": 8096,
                    "advanced_config": "# user location",
                }
            ],
            "access_list_id": 0,
            "block_exploits": True,
            "allow_websocket_upgrade": True,
            "http2_support": False,
            "caching_enabled": False,
            "hsts_enabled": False,
            "hsts_subdomains": False,
            "meta": {"nginx_online": False},
        }
        self.call("/nginx/proxy-hosts", body)
        STATE.write_text(json.dumps(self.snapshot(), sort_keys=True))

    def check(self) -> None:
        changed = changed_keys(json.loads(STATE.read_text()), self.snapshot())
        if changed:
            raise ValueError("NPM persistent state changed: " + ", ".join(changed))

    def probe(self) -> None:
        host = next(
            h
            for h in self.call("/nginx/proxy-hosts")
            if h["domain_names"] == ["upgrade-fixture.invalid"]
        )
        body = {key: host[key] for key in HOST_FIELDS if key != "id"}
        body["meta"] = host.get("meta") or {}
        changed = dict(body, forward_port=8097)
        try:
            self.call(f"/nginx/proxy-hosts/{host['id']}", changed, "PUT")
            try:
                self.check()
            except ValueError as error:
                if "NPM persistent state changed" not in str(error):
                    raise
            else:
                raise ValueError("NPM comparison missed a changed user proxy")
        finally:
            self.call(f"/nginx/proxy-hosts/{host['id']}", body, "PUT")
        self.check()

    def served(self) -> None:
        state = self.snapshot()
        for host in state["hosts"]:
            if host["certificate_id"]:
                for domain in host["domain_names"]:
                    require_served(domain, state[f"certificate/{host['certificate_id']}"])

    def legacy(self) -> None:
        """Exercise the configurator's supported default-admin rotation on a candidate."""
        if (
            self.acme != PEBBLE
            or pathlib.Path.cwd() != pathlib.Path("/root/MediaStack")
            or self.env.get("DATA_DIR") != "/tmp/ms-data"
        ):
            raise ValueError("legacy admin fixture requires the isolated DinD install")
        # Password changes invalidate the token needed for the identity update.
        self.call(
            "/users/me",
            {"name": "Administrator", "nickname": "Admin", "email": "admin@example.com"},
            "PUT",
        )
        self.call(
            "/users/me/auth",
            {
                "type": "password",
                "current": self.env["JELLYFIN_ADMIN_PASSWORD"],
                "secret": "changeme",
            },
            "PUT",
        )

    def renew(self) -> None:
        before = self.snapshot()
        for name in before:
            if name.startswith("certificate/"):
                self.call(f"/nginx/certificates/{name.split('/')[1]}/renew", {})
        after = self.snapshot()
        cert_keys = [key for key in before if key.startswith("certificate/")]
        if not cert_keys or any(before[key] == after[key] for key in cert_keys):
            raise ValueError("staging renewal did not replace every managed certificate")
        if any(
            before[key] != after[key]
            for key in before
            if key not in cert_keys and not key.startswith("private-key/")
        ):
            raise ValueError("staging renewal changed proxy or certificate identity")
        pathlib.Path("/tmp/ms-npm-after.json").write_text(json.dumps(after, sort_keys=True))
        if self.acme == PEBBLE:
            self.served()


if __name__ == "__main__":
    try:
        if sys.argv[1] == "prepare":
            prepare()
        else:
            getattr(Npm(), sys.argv[1])()
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError):
        # Exception messages from HTTP or subprocesses can contain secrets.
        raise SystemExit(f"NPM {sys.argv[1]} proof failed (private diagnostics withheld)") from None

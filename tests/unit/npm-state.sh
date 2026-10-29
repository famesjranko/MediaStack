#!/usr/bin/env bash
# Real fixture HTTP and TLS exercise migration, renewal and WAN refusal paths.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin npm-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import hashlib
import http.server
import json
import pathlib
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(sys.argv.pop())
sys.path[:0] = [str(ROOT / "tests/fixtures"), str(ROOT / "tests")]
import npm_state as fixture
from remote_preflight import wan


def host(hid, domain, cid):
    return dict(id=hid, domain_names=[domain], forward_scheme="http", forward_host="jellyfin",
                forward_port=8096, certificate_id=cid, enabled=True, ssl_forced=True,
                advanced_config="add_header X-User-Choice keep;", locations=[], access_list_id=0,
                block_exploits=True, allow_websocket_upgrade=True, http2_support=True,
                caching_enabled=False, hsts_enabled=True, hsts_subdomains=False)


class Handler(http.server.BaseHTTPRequestHandler):
    state = None
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        s = self.state
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"null")
        if self.path == "/api/tokens":
            if data != {"identity": "admin@fixture.test", "secret": "fixture-password"}:
                self.send_error(401)
                return
            result = {"token": "fixture-session"}
        elif self.headers.get("Authorization") != "Bearer fixture-session":
            self.send_error(401)
            return
        elif self.path == "/api/nginx/proxy-hosts":
            if self.command == "POST":
                data["id"] = 3
                s["hosts"].append(data)
                result = data
            else: result = s["hosts"]
        elif self.path == "/api/nginx/certificates": result = s["certs"]
        elif self.path.endswith("/renew"):
            s["renewed"] = not s.get("no_renewal", False)
            result = {"id": int(self.path.split("/")[-2])}
        else:
            self.send_error(404)
            return
        body = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Migration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.directory = pathlib.Path(cls.scratch.name)
        for name in ("before", "after"):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(cls.directory / (name + ".key")), "-out", str(cls.directory / (name + ".pem")),
                "-days", "1", "-subj", "/CN=STAGING fixture",
                "-addext", "subjectAltName=DNS:jellyfin.fixture.test,DNS:seerr.fixture.test"],
                check=True, capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.scratch.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.saved = pathlib.Path(self.temp.name) / "state.json"
        self.data = {"hosts": [host(1, "jellyfin.fixture.test", 10), host(2, "seerr.fixture.test", 11)],
                     "certs": [dict(id=10, provider="letsencrypt", domain_names=["jellyfin.fixture.test"]),
                               dict(id=11, provider="letsencrypt", domain_names=["seerr.fixture.test"])],
                     "renewed": False}
        handler = type("FixtureHandler", (Handler,), {"state": self.data})
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.patches = [patch.object(fixture, "STATE", self.saved),
            patch.object(fixture, "read_env", return_value={"DOMAIN": "fixture.test",
                "NPM_ADMIN_EMAIL": "admin@fixture.test", "JELLYFIN_ADMIN_PASSWORD": "fixture-password"}),
            patch.object(fixture.Npm, "cert_bytes", side_effect=self.certificate),
            patch.object(fixture.subprocess, "check_output", side_effect=self.inspection)]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.npm = fixture.Npm(f"http://127.0.0.1:{self.server.server_port}/api")

    def certificate(self, cid):
        name = "after" if self.data["renewed"] else "before"
        return (self.directory / (name + ".pem")).read_bytes()

    def inspection(self, argv, **kwargs):
        if argv[:3] == ["openssl", "x509", "-noout"]:
            return b"issuer=STAGING fixture"
        if argv[-1].endswith("privkey.pem"):
            return b"fixture-opaque-private-key-material"
        return ("server = " + fixture.STAGING).encode()

    def test_seed_check_and_renew_preserve_real_records(self):
        # Given a configured accepted NPM API and a deliberately seeded user proxy.
        self.npm.seed()

        # When the candidate retains those records and renews its staging certificates.
        self.npm.check()
        before = self.npm.snapshot()
        after_file = pathlib.Path(self.temp.name) / "after.json"
        with patch.object(fixture.pathlib, "Path", side_effect=lambda p: after_file):
            self.npm.renew()
        after = json.loads(after_file.read_text())

        # Then identities and user choices survive while both leaf certificates change.
        self.assertEqual(before["hosts"], after["hosts"])
        self.assertEqual(before["certificates"], after["certificates"])
        self.assertNotEqual(before["certificate/10"], after["certificate/10"])
        self.assertNotEqual(before["certificate/11"], after["certificate/11"])
        self.assertNotIn("fixture-password", self.saved.read_text())

    def test_lost_proxy_certificate_or_user_setting_blocks_upgrade(self):
        for fault in ("managed", "user", "certificate", "setting", "duplicate-domain"):
            with self.subTest(fault):
                # Given accepted state and a candidate that loses or overwrites one record.
                self.data["hosts"] = [host(1, "jellyfin.fixture.test", 10), host(2, "seerr.fixture.test", 11)]
                self.npm.seed()
                if fault == "managed": self.data["hosts"].pop(0)
                if fault == "user": self.data["hosts"].pop()
                if fault == "certificate": self.data["hosts"][0]["certificate_id"] = 99
                if fault == "setting": self.data["hosts"][0]["advanced_config"] = ""
                if fault == "duplicate-domain": self.data["hosts"][1]["domain_names"] = ["jellyfin.fixture.test"]

                # When the migration oracle reads the candidate before reconfiguration.
                # Then the loss fails instead of being silently repaired.
                with self.assertRaises((ValueError, StopIteration)): self.npm.check()

    def test_success_status_without_new_certificate_is_not_renewal(self):
        # Given an NPM renew endpoint that returns 200 but leaves the old certificate.
        self.npm.seed()
        self.data["no_renewal"] = True

        # When the renewal oracle runs.
        # Then a success response cannot replace proof of changed certificate material.
        with self.assertRaisesRegex(ValueError, "did not replace"): self.npm.renew()

    def test_production_renewal_server_is_rejected(self):
        # Given a certificate with a production renewal configuration.
        self.npm.seed()

        # When the candidate certificate is checked.
        # Then the check refuses before an ACME request can use production.
        original = self.inspection
        def inspect(argv, **kwargs):
            return b"server = https://acme-v02.api.letsencrypt.org/directory" if argv[0] == "docker" else original(argv, **kwargs)
        with patch.object(fixture.subprocess, "check_output", side_effect=inspect):
            with self.assertRaisesRegex(ValueError, "renewal does not use staging"):
                self.npm.check()

    def test_lost_private_key_is_not_hidden_by_later_renewal(self):
        # Given accepted certificates and a candidate that loses the private key.
        self.npm.seed()
        original = self.inspection
        def inspect(argv, **kwargs):
            if argv[-1].endswith("privkey.pem"): return b""
            return original(argv, **kwargs)

        # When persistent state is checked before renewal can recreate the key.
        # Then missing key material fails the migration check.
        with patch.object(fixture.subprocess, "check_output", side_effect=inspect):
            with self.assertRaisesRegex(ValueError, "private key is missing"):
                self.npm.check()

    def test_production_certificate_issuer_is_rejected_independently_of_renewal_config(self):
        # Given a production issuer even though the renewal config names staging.
        self.npm.seed()
        original = self.inspection
        def inspect(argv, **kwargs):
            if argv[0] == "openssl": return b"issuer=C=US, O=Let's Encrypt, CN=R1"
            return original(argv, **kwargs)

        # When the candidate certificate material is inspected.
        # Then the issuer check independently refuses it.
        with patch.object(fixture.subprocess, "check_output", side_effect=inspect):
            with self.assertRaisesRegex(ValueError, "not from Let's Encrypt staging"):
                self.npm.check()

    def test_changed_nonempty_private_key_blocks_migration(self):
        # Given accepted key material and a different nonempty candidate key.
        self.npm.seed()
        original = self.inspection
        def inspect(argv, **kwargs):
            if argv[-1].endswith("privkey.pem"): return b"different-opaque-key-material"
            return original(argv, **kwargs)

        # When NPM state is compared before renewal.
        # Then key replacement fails even though neither file is empty.
        with patch.object(fixture.subprocess, "check_output", side_effect=inspect):
            with self.assertRaisesRegex(ValueError, "persistent state changed"):
                self.npm.check()


class Wan(unittest.TestCase):
    def state(self):
        return {"hosts": [host(1, "jellyfin.fixture.test", 10), host(2, "seerr.fixture.test", 11)],
                "certificate/10": "1" * 64, "certificate/11": "2" * 64}

    def application(self, hostname, ip, path, cert):
        return {"Id": "fixture", "Version": "1"} if path == "/System/Info/Public" else {"version": "1"}

    def test_public_proof_accepts_matching_dns_and_closed_admin_ports(self):
        # Given both DNS names point to the VM and all admin TCP ports refuse connections.
        with patch.object(wan, "command", return_value=b"192.0.2.42 STREAM fixture\n"), \
             patch.object(wan, "https", side_effect=self.application) as tls, \
             patch.object(wan.socket, "create_connection", side_effect=ConnectionRefusedError) as tcp:
            # When the real WAN proof checks DNS, applications and the canonical ports.
            wan.check("fixture.test", "192.0.2.42", self.state())

        # Then both applications qualify and the admin-port check has a nonempty population.
        self.assertEqual(tls.call_count, 2)
        self.assertGreater(tcp.call_count, 0)

    def test_wrong_public_dns_blocks_even_when_https_and_firewall_would_pass(self):
        # Given one DNS name points elsewhere but HTTPS and blocked ports would qualify.
        def dns(argv, **kwargs):
            ip = "192.0.2.66" if argv[-1].startswith("jellyfin.") else "192.0.2.42"
            return (ip + " STREAM fixture\n").encode()
        with patch.object(wan, "command", side_effect=dns), \
             patch.object(wan, "https", side_effect=self.application), \
             patch.object(wan.socket, "create_connection", side_effect=ConnectionRefusedError), \
             patch.object(wan.time, "monotonic", side_effect=[0, 0, 181]), patch.object(wan.time, "sleep"):
            # When the real WAN proof reaches its bounded DNS deadline.
            # Then stale public DNS independently prevents acceptance.
            with self.assertRaisesRegex(ValueError, "public DNS did not converge"):
                wan.check("fixture.test", "192.0.2.42", self.state())

    def test_reachable_admin_port_blocks_even_when_dns_and_https_pass(self):
        # Given correct public DNS and HTTPS but NPM's admin TCP port is reachable.
        class Connection:
            def close(self): pass
        def connect(address, **kwargs):
            if address[1] == 81: return Connection()
            raise ConnectionRefusedError()
        with patch.object(wan, "command", return_value=b"192.0.2.42 STREAM fixture\n"), \
             patch.object(wan, "https", side_effect=self.application), \
             patch.object(wan.socket, "create_connection", side_effect=connect):
            # When the real WAN proof tests the canonical admin ports.
            # Then the reachable admin service independently prevents acceptance.
            with self.assertRaisesRegex(ValueError, "admin TCP port 81 is reachable"):
                wan.check("fixture.test", "192.0.2.42", self.state())


class Tls(unittest.TestCase):
    def test_slow_headers_and_body_cannot_extend_the_total_request_deadline(self):
        # Given a TLS server that keeps each read active beyond the total request budget.
        with tempfile.TemporaryDirectory() as folder:
            cert, key = pathlib.Path(folder) / "cert.pem", pathlib.Path(folder) / "key"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=fixture.test"],
                check=True, capture_output=True)
            expected = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
            for phase in ("headers", "body"):
                with self.subTest(phase):
                    dripped = threading.Event()
                    stopped = threading.Event()
                    class Slow(http.server.BaseHTTPRequestHandler):
                        def log_message(self, *args): pass
                        def do_GET(self):
                            body = b'{"Id":"fixture"}' + b' ' * 100
                            headers = (f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\n"
                                       "X-Fixture: " + "a" * 100 + "\r\n\r\n").encode()
                            try:
                                if phase == "body": self.wfile.write(headers)
                                payload = headers + body if phase == "headers" else body
                                for index, byte in enumerate(payload):
                                    self.wfile.write(bytes([byte]))
                                    if index: dripped.set()
                                    if stopped.wait(0.02): break
                            except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
                    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Slow)
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(cert, key)
                    server.socket = context.wrap_socket(server.socket, server_side=True)
                    thread = threading.Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    try:
                        # When the public probe has a short total deadline and receives frequent bytes.
                        with patch.object(wan, "HTTPS_TIMEOUT", 0.5, create=True):
                            # Then both header and body streaming expire despite continued activity.
                            with self.assertRaises(TimeoutError):
                                wan.https("fixture.test", "127.0.0.1", "/", expected, server.server_port)
                        self.assertTrue(dripped.is_set())
                    finally:
                        stopped.set()
                        server.shutdown()
                        server.server_close()
                        thread.join(timeout=5)

    def test_public_https_requires_the_candidate_certificate_and_working_backend(self):
        # Given a real TLS endpoint with the candidate's leaf certificate.
        with tempfile.TemporaryDirectory() as folder:
            cert, key = pathlib.Path(folder) / "cert.pem", pathlib.Path(folder) / "key"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=fixture.test"],
                check=True, capture_output=True)
            class Public(http.server.BaseHTTPRequestHandler):
                status = 200
                def log_message(self, *args): pass
                def handle(self):
                    try: super().handle()
                    except BrokenPipeError: pass  # The wrong-pin client closes before HTTP.
                def do_GET(self):
                    self.send_response(self.status)
                    self.end_headers()
                    self.wfile.write(b'{"Id":"fixture-id","Version":"1.0"}')
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Public)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                expected = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()

                # When a client requests the public application with an exact certificate pin.
                result = wan.https("fixture.test", "127.0.0.1", "/System/Info/Public", expected, server.server_port)

                # Then the working backend qualifies and wrong certificates or failed HTTPS do not.
                self.assertEqual(result["Id"], "fixture-id")
                with self.assertRaisesRegex(ValueError, "different certificate"):
                    wan.https("fixture.test", "127.0.0.1", "/", "0" * 64, server.server_port)
                Public.status = 502
                with self.assertRaisesRegex(ValueError, "non-200"):
                    wan.https("fixture.test", "127.0.0.1", "/", expected, server.server_port)
            finally:
                server.shutdown()
                server.server_close()


unittest.main(argv=["npm-state"], verbosity=2)
PY
    pass 'NPM migration, staging renewal and public TLS contracts'
else
    fail 'NPM migration, staging renewal and public TLS contracts'
fi
summary

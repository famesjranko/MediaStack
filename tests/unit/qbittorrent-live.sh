#!/usr/bin/env bash
# Exercise the real HTTP assertion against independent local API responses.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin qbittorrent-live
if python3 -I - "$REPO_ROOT" <<'PY'; then
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(sys.argv.pop())
PREFS = {"max_ratio_act": 0, "dl_limit": 1048576, "up_limit": 2097152,
         "max_seeding_time": 60, "max_seeding_time_enabled": True,
         "bypass_auth_subnet_whitelist": "172.28.0.22/32\n172.28.0.23/32\n172.28.0.40/32",
         "bypass_auth_subnet_whitelist_enabled": True, "save_path": "/data",
         "temp_path": "/data/tmp", "temp_path_enabled": True}


class LoginContract(unittest.TestCase):
    def probe(self, status, body, delayed_path=None):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if self.path == delayed_path:
                    time.sleep(25)
                    return
                self.send_response(status)
                self.send_header("Set-Cookie", "SID=fixture; Path=/")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == delayed_path:
                    time.sleep(25)
                    return
                values = {"/api/v2/app/preferences": PREFS,
                          "/api/v2/torrents/categories": {"tv": {"savePath": "/data/tv"}}}
                if self.headers.get("Cookie") != "SID=fixture" or self.path not in values:
                    self.send_error(403)
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(values[self.path]).encode())

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as td:
                folder = pathlib.Path(td)
                (folder / ".env").write_text("JELLYFIN_ADMIN_USER=admin\nJELLYFIN_ADMIN_PASSWORD=fixture\n"
                    "QBT_DL_LIMIT=1\nQBT_UL_LIMIT=2\nMEDIASTACK_NETWORK_PREFIX=172.28.0\n")
                config = {"qbittorrent": {"max_seeding_time": 60, "save_path": "/data",
                          "temp_path": "/data/tmp", "categories": {"tv": "/data/tv"}}}
                (folder / "config.yml").write_text(json.dumps(config))
                omitted = {"JELLYFIN_ADMIN_USER", "JELLYFIN_ADMIN_PASSWORD", "QBT_DL_LIMIT",
                           "QBT_UL_LIMIT", "MEDIASTACK_NETWORK_PREFIX", "STORAGE_APP_WIRING"}
                child_env = {k: v for k, v in os.environ.items() if k not in omitted}
                child_env.update({"NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"})
                return subprocess.run(["bash", str(ROOT / "tests/assertions/qbittorrent-live.sh"),
                    "--url", f"http://127.0.0.1:{server.server_port}", "--env", str(folder / ".env"),
                    "--config", str(folder / "config.yml")], capture_output=True, text=True, timeout=30, env=child_env)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

    def test_ok_body_on_http_error_is_rejected(self):
        # Given a failed login response whose body misleadingly says Ok.
        # When the real assertion reads HTTP 500 and the otherwise valid API.
        result = self.probe(500, b"Ok.")

        # Then it reports failed authentication and exits unsuccessfully.
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL\tstep 1 qBittorrent: shared admin credentials authenticate", result.stdout)
        self.assertNotIn("PASS\tstep 1 qBittorrent: shared admin credentials authenticate", result.stdout)

    def test_ok_login_and_authenticated_reads_pass(self):
        # Given a successful login and valid preferences and categories.
        # When the real assertion receives HTTP 200 with Ok.
        result = self.probe(200, b"Ok.")

        # Then its cookie-authenticated reads and all configuration checks pass.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL\t", result.stdout)

    def test_no_content_login_and_authenticated_reads_pass(self):
        # Given the accepted image's successful no-content login response.
        # When the real assertion receives HTTP 204 with its session cookie.
        result = self.probe(204, b"")

        # Then it accepts the login and verifies the authenticated configuration.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL\t", result.stdout)


    def test_stalled_requests_have_a_total_deadline(self):
        for endpoint in ("/api/v2/auth/login", "/api/v2/app/preferences"):
            with self.subTest(endpoint=endpoint):
                # Given a local endpoint that does not respond for 25 seconds.
                start = time.monotonic()

                # When the real assertion makes its login or preferences request.
                result = self.probe(200, b"Ok.", delayed_path=endpoint)
                elapsed = time.monotonic() - start

                # Then it fails within its 20-second request budget plus process overhead.
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertLess(elapsed, 24, f"{endpoint} exceeded its total request deadline")


unittest.main()
PY
    pass 'qBittorrent live assertions require successful HTTP authentication'
else
    fail 'qBittorrent live assertions require successful HTTP authentication'
fi
summary

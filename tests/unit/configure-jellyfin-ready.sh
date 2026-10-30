#!/usr/bin/env bash
# Exercise the real configuration dispatcher against a loading Jellyfin API.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO=configure-jellyfin-ready
scenario_begin "$CURRENT_SCENARIO"

if python3 - "$REPO_ROOT" <<'PY'
import http.server
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

REPO = pathlib.Path(sys.argv[1])


class Readiness(unittest.TestCase):
    def exercise(self, response, unavailable=2):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            shutil.copytree(REPO / "scripts", root / "scripts")
            shutil.copyfile(REPO / "config/examples/config.yml", root / "config.yml")
            # The service boundary performs the same strict startup read as Jellyfin.
            (root / "scripts/services/jellyfin/main.sh").write_text('''
configure_jellyfin() {
    local state
    state=$(http_json_request "Jellyfin startup state" GET \
        "$(service_local_url jellyfin)/System/Info/Public" "" "" "" \
        StartupWizardCompleted:boolean) || return 1
    printf '%s' "$state" >"$SCRIPT_DIR/configured"
}
''')
            calls = []

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    calls.append(self.path)
                    if self.path == "/":
                        code, body = 302, b""
                    elif self.path == "/System/Info/Public":
                        loading = calls.count(self.path) <= unavailable
                        code = 503 if loading else 200
                        body = b"Jellyfin Server is loading" if loading else json.dumps(response).encode()
                        if loading and calls.count(self.path) == 1 and unavailable != 1000:
                            code, body = 200, b'{"startupWizardCompleted":false}'
                    else:
                        code, body = 404, b""
                    self.send_response(code)
                    if code == 302:
                        self.send_header("Location", "/web/")
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *args):
                    pass

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            flows = root / "scripts/flows"
            flows.mkdir(exist_ok=True)
            # Keep the production polling budget while avoiding real backoff delays.
            (flows / "fixture.sh").write_text(
                f'service_local_url() {{ printf "http://127.0.0.1:{server.server_port}"; }}\n'
                'sleep() { :; }\n'
            )
            try:
                result = subprocess.run(
                    ["bash", str(root / "scripts/configure.sh"), "--only", "jellyfin"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                configured = root / "configured"
                return (json.loads(configured.read_text()) if configured.exists() else None,
                        (root / ".configure_issues").exists(), calls, result.stdout)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_redirect_does_not_release_configuration_before_the_api_is_ready(self):
        for completed in (False, True):
            with self.subTest(completed=completed):
                # Given a redirecting web root and a bootstrap response followed by HTTP 503.
                expected = {"StartupWizardCompleted": completed}

                # When the real dispatcher waits and then configures Jellyfin.
                configured, issues, calls, _ = self.exercise(expected)

                # Then configuration reads the ready API for both fresh and existing installs.
                self.assertEqual(configured, expected)
                self.assertFalse(issues)
                self.assertGreaterEqual(calls.count("/System/Info/Public"), 3)

    def test_permanent_loading_is_bounded_and_does_not_report_configuration_success(self):
        # Given the startup API never leaves its loading state.
        # When the dispatcher exhausts its readiness budget.
        configured, issues, calls, output = self.exercise({}, unavailable=1000)

        # Then the run ends with a warning and no configured state.
        self.assertIsNone(configured)
        self.assertTrue(issues)
        self.assertIn("timeout", output)
        self.assertLess(len(calls), 50)

    def test_successful_http_with_missing_startup_state_still_fails_closed(self):
        # Given an available API whose successful response omits the completion flag.
        # When configuration reads the startup state.
        configured, issues, _, _ = self.exercise({}, unavailable=0)

        # Then the typed read refuses to configure the service.
        self.assertIsNone(configured)
        self.assertTrue(issues)


unittest.main(argv=["configure-jellyfin-ready"], verbosity=2)
PY
then
    pass 'Jellyfin configuration waits for its API and rejects unknown startup state'
else
    fail 'Jellyfin configuration waits for its API and rejects unknown startup state'
fi
summary

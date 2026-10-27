#!/usr/bin/env bash
# Pin authentication responses observed from the real accepted images.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin upgrade-state
if python3 -I - "$REPO_ROOT" <<'PY'
import importlib.util
import io
import pathlib
import sys
import unittest

spec = importlib.util.spec_from_file_location("upgrade_state", pathlib.Path(sys.argv.pop()) / "tests/fixtures/upgrade_state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.read_env = lambda: {"JELLYFIN_ADMIN_USER": "admin", "JELLYFIN_ADMIN_PASSWORD": "fixture", "JELLYFIN_API_KEY": "test-key"}


class Response(io.BytesIO):
    def __init__(self, status, body):
        super().__init__(body)
        self.status = status


class Opener:
    def __init__(self, status=200, body=b"Ok."):
        self.status, self.body, self.request = status, body, None

    def open(self, request, *args, **kwargs):
        self.request = request
        if isinstance(request, str) and request.endswith("/auth/login"):
            return Response(self.status, self.body)
        return Response(200, b'{"fixture":true}')


class AuthContract(unittest.TestCase):
    def test_no_content_login_is_supported(self):
        # Given the accepted qBittorrent image returns its documented 204 login.
        client = module.StateClient()
        client.http = Opener(204, b"")

        # When the migration probe reads authenticated preferences.
        actual = client.qbt("app/preferences")

        # Then it accepts the successful login and reads the response.
        self.assertEqual(actual, {"fixture": True})

    def test_false_success_body_is_rejected(self):
        # Given qBittorrent rejects credentials with HTTP 200 and Fails.
        client = module.StateClient()
        client.http = Opener(200, b"Fails.")

        # When the migration probe attempts an authenticated read.
        # Then an HTTP success code cannot hide authentication failure.
        with self.assertRaisesRegex(ValueError, "login failed"):
            client.qbt("app/preferences")

    def test_jellyfin_uses_product_authorization(self):
        # Given a configured Jellyfin integration key.
        client = module.StateClient()
        client.http = Opener()

        # When the probe reads administrative user state.
        client.call("jellyfin", "/Users")

        # Then it sends the authorization form that the accepted image supports.
        self.assertEqual(client.http.request.get_header("Authorization"), 'MediaBrowser Token="test-key"')


unittest.main()
PY
then
    pass 'upgrade-state authentication follows the real service contracts'
else
    fail 'upgrade-state authentication follows the real service contracts'
fi
summary

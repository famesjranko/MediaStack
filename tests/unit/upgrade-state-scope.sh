#!/usr/bin/env bash
# Keep remote settings proof separate from destructive DinD media fixtures.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin upgrade-state-scope
if python3 -I - "$REPO_ROOT" <<'PY'; then
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("upgrade_state", pathlib.Path(sys.argv.pop()) / "tests/fixtures/upgrade_state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Scope(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        for target, name, value in (
            (module, "read_env", lambda: {"DATA_DIR": "/mnt/data"}),
            (module, "SNAPSHOT", self.root / "snapshot.json"),
            (module.pathlib.Path, "cwd", lambda: pathlib.Path("/opt/MediaStack")),
        ):
            self.patch(target, name, value)

    def patch(self, target, name, value):
        change = patch.object(target, name, value)
        change.start()
        self.addCleanup(change.stop)

    def test_default_seed_refuses_remote_host_before_any_write(self):
        # Given the ordinary full fixture command runs on a remote host.
        writes = []
        self.patch(module.StateClient, "call", lambda *args, **kwargs: writes.append(args))

        # When the caller does not explicitly select settings-only proof.
        # Then the DinD guard refuses before any service or local fixture can change.
        with patch.object(sys, "argv", ["upgrade_state.py", "seed"]):
            with self.assertRaisesRegex(ValueError, "isolated DinD"):
                module.main()
        self.assertEqual(writes, [])

    def test_remote_seed_keeps_user_and_setting_writes_without_local_media(self):
        # Given an empty remote baseline and local fixture writers that must not run.
        writes = []
        routes = {
            ("jellyfin", "/Users"): [],
            ("jellyfin", "/Auth/Keys"): {"Items": []},
            ("seerr", "/api/v1/user?take=1000&skip=0"): {"results": []},
            ("sonarr", "/api/v3/qualityprofile"): [{"id": 12, "name": "1080p Balanced", "upgradeAllowed": False}],
        }
        def call(client, app, path, body=None, method="GET"):
            if method == "GET":
                return routes[app, path]
            writes.append((app, path, method))
        self.patch(module.StateClient, "call", call)
        def forbidden(*args):
            raise AssertionError("remote proof attempted a local media fixture")
        for target, name in ((module.upgrade_history, "seed"),
                             (module.upgrade_media, "seed_watch_state"),
                             (module.upgrade_media, "seed_torrent")):
            self.patch(target, name, forbidden)

        # When the real command explicitly selects the remote settings scope.
        with patch.object(sys, "argv", ["upgrade_state.py", "seed", "--settings-only"]):
            module.main()

        # Then user identities, the stored key and the custom profile are still seeded.
        self.assertEqual(writes, [
            ("jellyfin", "/Users/New", "POST"),
            ("jellyfin", "/Auth/Keys?app=upgrade-fixture-key", "POST"),
            ("seerr", "/api/v1/user", "POST"),
            ("sonarr", "/api/v3/qualityprofile/12", "PUT"),
        ])

    def snapshot_readers(self):
        # The existing upgrade-state suite tests the API readers themselves.
        values = {
            "arr_state": {"sonarr/notification": [1], "radarr/notification": [2],
                          "sonarr/naming": {"renameEpisodes": True}, "sonarr/mediamanagement": {"minimumFreeSpaceWhenImporting": 1024},
                          "radarr/naming": {"renameMovies": True}, "radarr/mediamanagement": {"minimumFreeSpaceWhenImporting": 1024}},
            "jellyfin_state": {"jellyfin/libraries": ["Movies"], "jellyfin/system": {"ServerName": "MediaStack"},
                               "jellyfin/encoding": {"EnableHardwareEncoding": False}, "jellyfin/network": {"EnableIPv6": False}},
            "seerr_state": {"seerr/api-key": {"set": True}, "seerr/jellyfin": {"hostname": "jellyfin"},
                            "seerr/network": {"trustProxy": True}, "seerr/users": [{"id": 2}]},
            "jackett_state": {"jackett/admin": {"admin_password_set": True}},
            "qbittorrent_state": {"qbittorrent/preferences": {"upnp": False}},
        }
        for name, rows in values.items():
            self.patch(module.StateClient, name, lambda client, result, rows=rows: result.update(rows))
        self.patch(module.StateClient, "authenticate", lambda client: None)
        self.patch(module.StateClient, "integration_credentials", lambda client: None)
        def forbidden(*args):
            raise AssertionError("settings snapshot attempted a media/history read")
        self.patch(module.upgrade_media, "snapshot", forbidden)
        self.patch(module.upgrade_history, "snapshot", forbidden)
        return values

    def command(self, action):
        with patch.object(sys, "argv", ["upgrade_state.py", action, "--settings-only"]):
            module.main()

    def test_remote_snapshot_detects_user_state_loss(self):
        # Given a saved remote settings snapshot and a candidate that lost a user.
        values = self.snapshot_readers()
        self.command("save")
        self.command("check")
        values["seerr_state"]["seerr/users"] = []

        # When the candidate is compared with the accepted baseline.
        # Then missing user state still blocks acceptance without media fixtures.
        with self.assertRaisesRegex(SystemExit, "persistent state changed: seerr/users"):
            self.command("check")

    def test_snapshot_scope_cannot_change_between_save_and_check(self):
        # Given a settings snapshot carrying a different scope from this check.
        self.snapshot_readers()
        self.command("save")
        saved = json.loads(module.SNAPSHOT.read_text())
        saved["fixture_scope"] = "full"
        module.SNAPSHOT.write_text(json.dumps(saved))

        # When settings-only proof tries to reuse that snapshot.
        # Then the scope mismatch fails even when all compared values match.
        with self.assertRaisesRegex(SystemExit, "persistent state changed: fixture_scope"):
            self.command("check")


unittest.main()
PY
    pass 'remote settings scope preserves state checks and the DinD write guard'
else
    fail 'remote settings scope preserves state checks and the DinD write guard'
fi
summary

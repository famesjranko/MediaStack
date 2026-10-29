#!/usr/bin/env bash
# Migration state must reject lost peers, reset settings, rotated keys and failed login.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin wireguard-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import importlib.util
import io
import json
import pathlib
import sys
import unittest
import urllib.error
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("wireguard_state", pathlib.Path(sys.argv.pop()) / "tests/fixtures/wireguard_state.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# Values follow wg-easy v15's ClientType and API responses. Counters and timestamps
# vary at runtime and must not affect persistence comparisons.
PEERS = [
    {"id": i, "name": name, "enabled": enabled, "ipv4Address": f"10.8.0.{i + 1}",
     "ipv6Address": f"fdcc:ad94:bacf:61a3::{i + 1}", "expiresAt": None,
     "allowedIps": ["192.168.50.0/24"], "serverAllowedIps": [],
     "firewallIps": ["192.168.50.10/32"], "dns": ["9.9.9.9"], "mtu": 1380,
     "persistentKeepalive": 17, "serverEndpoint": None,
     "preUp": "", "postUp": "", "preDown": "", "postDown": "",
     "privateKey": f"fixture-private-{i}", "publicKey": f"fixture-public-{i}",
     "preSharedKey": f"fixture-preshared-{i}", "createdAt": "2026-01-01", "updatedAt": "2026-01-01"}
    for i, (name, enabled) in enumerate((("admin", True), ("migration-enabled", True), ("migration-disabled", False)), 1)
]
DUMP = "server-private\tserver-public\t51920\toff\n" + "".join(
    f"{p['publicKey']}\t{p['preSharedKey']}\t(none)\t{p['ipv4Address']}/32\t0\t0\t0\t0\n"
    for p in PEERS if p["enabled"]
)


class Fixture(m.Client):
    def __init__(self):
        self.rows = copy.deepcopy(PEERS)
        self.firewall = True
        self.calls = []
        self.config = {}

    def call(self, path, body=None, *, raw=False):
        self.calls.append((path, body))
        if path == "/client":
            return copy.deepcopy(self.rows)
        if path == "/admin/interface":
            return {"firewallEnabled": self.firewall}
        pid = int(path.split("/")[2])
        if raw:
            return self.config.get(pid, f"[Interface]\nPrivateKey = fixture-private-{pid}\n[Peer]\nPresharedKey = fixture-preshared-{pid}\nPublicKey = server-public\n")
        return {k: copy.deepcopy(v) for k, v in next(p for p in self.rows if p["id"] == pid).items() if k not in ("privateKey", "preSharedKey")}


class Snapshot(unittest.TestCase):
    def setUp(self):
        self.commands = patch.object(m, "command", return_value=DUMP)
        self.command = self.commands.start()
        self.addCleanup(self.commands.stop)

    def test_snapshot_has_no_secret_and_uses_authenticated_reads_only(self):
        # Given representative enabled and disabled peers on the accepted image.
        client = Fixture()

        # When migration state is recorded.
        state = client.snapshot()

        # Then raw private and preshared keys never enter the snapshot.
        encoded = json.dumps(state)
        for value in ["server-private", *[p[k] for p in PEERS for k in ("privateKey", "preSharedKey")]]:
            self.assertNotIn(value, encoded)
        # And every API request is read-only and keys are read from the kernel.
        self.assertTrue(client.calls)
        self.assertTrue(all(body is None for _, body in client.calls))
        self.command.assert_called_once_with("wg", "show", "wg0", "dump")

    def test_each_saved_peer_field_detects_a_change(self):
        for key in m.PEER_FIELDS:
            if key == "id":
                continue
            with self.subTest(key=key):
                # Given a baseline and an upgrade that changes one disabled peer's setting.
                before = Fixture().snapshot()
                client = Fixture()
                client.rows[2][key] = "changed"

                # When the candidate state is checked.
                # Then the change cannot pass the migration comparison.
                with self.assertRaises((ValueError, StopIteration)):
                    m.check(before, client.snapshot())

    def test_missing_required_field_is_rejected(self):
        for key in (*m.PEER_FIELDS, "publicKey"):
            with self.subTest(key=key):
                # Given an API response missing a field required for migration.
                client = Fixture()
                del client.rows[2][key]

                # When migration state is recorded.
                # Then an absent field cannot silently become a default.
                with self.assertRaises(KeyError):
                    client.snapshot()

    def test_lost_peer_is_rejected(self):
        # Given a candidate that loses an existing disabled peer.
        client = Fixture()
        client.rows.pop()

        # When its state is read.
        # Then an empty or reduced baseline cannot count as migration evidence.
        with self.assertRaisesRegex(ValueError, "fixture peers are missing"):
            client.snapshot()

    def test_recreated_peer_with_new_id_is_rejected(self):
        # Given a peer re-created with the same name and a new identity.
        before = Fixture().snapshot()
        client = Fixture()
        client.rows[2]["id"] = 99

        # When its state is compared.
        # Then the new peer cannot replace the existing one unnoticed.
        with self.assertRaisesRegex(ValueError, "changed: peers"):
            m.check(before, client.snapshot())

    def test_rotated_peer_key_is_rejected(self):
        for key in ("privateKey", "publicKey", "preSharedKey"):
            with self.subTest(key=key):
                # Given a baseline and a changed key on the disabled peer.
                before = Fixture().snapshot()
                client = Fixture()
                if key == "publicKey":
                    client.rows[2][key] = "replacement-key"
                else:
                    old = client.call("/client/3/configuration", raw=True)
                    token = "fixture-private-3" if key == "privateKey" else "fixture-preshared-3"
                    client.config[3] = old.replace(token, "replacement-key")

                # When the candidate state is compared.
                # Then the key change is rejected without printing the key.
                with self.assertRaisesRegex(ValueError, "changed: peers") as error:
                    m.check(before, client.snapshot())
                self.assertNotIn("replacement-key", str(error.exception))

    def test_changed_export_is_rejected(self):
        # Given a candidate that exports a different client configuration.
        before = Fixture().snapshot()
        client = Fixture()
        client.config[3] = "[Interface]\nPrivateKey = changed\n[Peer]\nEndpoint = wrong:1234\nPresharedKey = fixture-preshared-3\nPublicKey = server-public\n"

        # When state is compared.
        # Then a broken download cannot pass because the database still matches.
        with self.assertRaisesRegex(ValueError, "changed: peers"):
            m.check(before, client.snapshot())

    def test_missing_kernel_peer_is_rejected(self):
        # Given API state that still lists an enabled peer absent from wg0.
        self.command.return_value = "\n".join(DUMP.splitlines()[:-1]) + "\n"

        # When migration state is read.
        # Then database state alone cannot prove a loaded peer.
        with self.assertRaisesRegex(ValueError, "not loaded in the kernel"):
            Fixture().snapshot()

    def test_reset_server_key_or_port_is_rejected(self):
        for old in ("server-private", "51920"):
            with self.subTest(field=old):
                # Given a baseline and a changed server identity or listen port.
                self.command.return_value = DUMP
                before = Fixture().snapshot()
                self.command.return_value = DUMP.replace(old, "changed")

                # When candidate state is compared.
                # Then the loaded interface change is rejected.
                with self.assertRaisesRegex(ValueError, "changed: kernel"):
                    m.check(before, Fixture().snapshot())

    def test_firewall_disabled_is_rejected(self):
        # Given an upgrade that turns off per-client firewall enforcement.
        client = Fixture()
        client.firewall = False

        # When state is read.
        # Then unchanged peers cannot hide the lost firewall setting.
        with self.assertRaisesRegex(ValueError, "firewall was lost"):
            client.snapshot()

    def test_transient_kernel_statistics_do_not_change_state(self):
        # Given a saved snapshot and later handshakes, traffic and endpoints.
        before = Fixture().snapshot()
        self.command.return_value = DUMP.replace("(none)\t", "192.0.2.1:4567\t").replace("\t0\t0\t0\t", "\t1760000000\t100\t200\t")

        # When state is compared after recreation.
        m.check(before, Fixture().snapshot())

        # Then volatile traffic data does not cause a migration failure.
        self.assertEqual(before, Fixture().snapshot())


class Transport(unittest.TestCase):
    def test_stored_auth_is_sent_and_failed_login_is_rejected(self):
        # Given a stored password containing shell characters and an unauthorized response.
        text = 'JELLYFIN_ADMIN_USER=admin\nJELLYFIN_ADMIN_PASSWORD=\'a$"b\\c\'\n'
        with patch.object(pathlib.Path, "read_text", return_value=text):
            client = m.Client()
        error = urllib.error.HTTPError("http://test", 401, "Unauthorized", {}, None)

        # When an authenticated peer read is attempted.
        with patch.object(m.urllib.request, "urlopen", side_effect=error) as request:
            with self.assertRaisesRegex(ValueError, "HTTP 401"):
                client.call("/client")

        # Then the stored credential is used and a failed login cannot return state.
        self.assertEqual(request.call_args.args[0].get_header("Authorization"), "Basic YWRtaW46YSQiYlxj")
        self.assertEqual(request.call_count, 1)


unittest.main()
PY
    pass 'WireGuard migration rejects lost state and keeps secrets out of snapshots'
else
    fail 'WireGuard migration rejects lost state and keeps secrets out of snapshots'
fi
summary

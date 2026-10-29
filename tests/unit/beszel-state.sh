#!/usr/bin/env bash
# The migration oracle must reject lost records, credentials and user access.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin beszel-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import json
import pathlib
import sys
import tempfile
import unittest
import urllib.error

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests/fixtures"))
import beszel_state as module
import upgrade_state

ENV = {"NPM_ADMIN_EMAIL": "admin@beszel.test", "JELLYFIN_ADMIN_PASSWORD": "shared-password",
       "BESZEL_AGENT_KEY": "ssh-ed25519 fixture-agent-key"}
ADMIN = {"id": "admin1", "email": ENV["NPM_ADMIN_EMAIL"], "username": "admin", "role": "admin", "verified": True}
USER = {"id": "user1", "email": module.EMAIL, "username": "fixture", "role": "user", "verified": True}
LOCAL = {"id": "local1", "name": "MediaStack", "host": "/beszel_data/socket/beszel.sock", "port": "", "users": ["admin1"]}
ROWS = {
    "users": USER,
    "systems": {"id": "system1", "name": "Upgrade fixture", "host": "127.0.0.1", "port": "45876", "users": ["user1"], "status": "paused"},
    "user_settings": {"id": "settings1", "user": "user1", "settings": {"unitTemp": 3}},
    "system_stats": {"id": "stats1", "system": "system1", "type": "480m", "stats": {"cpu": 12.5}, "created": "2026-10-29 00:00:00.000Z"},
    "container_stats": {"id": "containers1", "system": "system1", "type": "480m", "stats": [{"n": "fixture", "cpu": 1.5}], "created": "2026-10-29 00:00:00.000Z"},
}


class Client(module.BeszelState):
    def __init__(self):
        self.env = dict(ENV)
        self.rows = copy.deepcopy(ROWS)
        self.local = copy.deepcopy(LOCAL)
        self.admin = copy.deepcopy(ADMIN)
        self.key = ENV["BESZEL_AGENT_KEY"]
        self.denied = None
        self.hidden = False
        self.total = 1

    def send(self, app, path, body, method, headers):
        if "auth-with-password" in path:
            identity = "fixture" if body["identity"] == module.EMAIL else "admin"
            collection = path.split("/")[3]
            if self.denied == (collection, identity):
                raise urllib.error.HTTPError("http://fixture", 401, "Unauthorized", {}, None)
            record = self.rows["users"] if identity == "fixture" else self.admin
            return {"token": identity + "-token", "record": record}
        if path.endswith("beszel/getkey"):
            return {"key": self.key}
        collection = path.split("/")[3]
        if "?" in path:
            rows = [self.local] if collection == "systems" else ([] if self.hidden else [self.rows[collection]])
            return {"items": rows, "totalItems": self.total if rows else 0}
        return self.rows[collection]


class Seeder(Client):
    def create(self, collection, body):
        self.rows[collection].update(body)
        if collection == "systems":
            self.rows[collection]["status"] = "pending"
        if collection == "user_settings":
            # The accepted hub's InitializeUserSettings hook keeps only defaults.
            self.rows[collection]["settings"] = {"chartTime": "1h", "emails": [module.EMAIL]}
        if collection == "container_stats" and self.drop_sample:
            self.rows[collection]["stats"] = []
        return self.rows[collection]["id"]

    def send(self, app, path, body, method, headers):
        if method == "PATCH":
            self.rows[path.split("/")[3]].update(body)
        return super().send(app, path, body, method, headers)


class Migration(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        module.FIXTURE = pathlib.Path(self.folder.name) / "fixture.json"
        module.FIXTURE.write_text(json.dumps({"ids": {k: v["id"] for k, v in ROWS.items()}, "password": "fixture-password"}))
        self.state = Client()

    def test_seed_saves_preferences_after_the_create_hook(self):
        # Given the accepted hub replaces preferences with defaults on creation.
        module.FIXTURE.unlink()
        state = Seeder()
        state.drop_sample = False

        # When the fixture creates a user and saves deliberate user preferences.
        state.seed()

        # Then the saved baseline contains the choices rather than defaults.
        self.assertEqual(state.snapshot()["user_settings"]["settings"], {"unitTemp": 3, "chartTime": "24h"})
        self.assertEqual(state.snapshot()["systems"]["status"], "paused")
        self.assertEqual(module.FIXTURE.stat().st_mode & 0o777, 0o600)

    def test_seed_refuses_a_sample_that_was_not_saved(self):
        # Given the hub silently drops the submitted container history sample.
        module.FIXTURE.unlink()
        state = Seeder()
        state.drop_sample = True

        # When the fixture verifies its seeded baseline.
        # Then an empty history cannot qualify as migration evidence.
        with self.assertRaisesRegex(ValueError, "did not persist fixture container_stats"):
            state.seed()

    def test_recovery_preparation_targets_only_the_local_system_and_superuser(self):
        # Given a migrated hub with its original local system and admin identities.
        changes = []
        original = self.state.send
        def record(app, path, body, method, headers):
            if method == "PATCH":
                changes.append((path, body))
                return {}
            return original(app, path, body, method, headers)
        self.state.send = record

        # When the fixture prepares the supported recovery paths.
        self.state.prepare_recovery()

        # Then the old TCP entry and superuser password are the only changes.
        self.assertEqual(changes[0], ("/api/collections/systems/records/local1",
                                     {"host": "host.docker.internal", "port": "45876"}))
        self.assertEqual(len(changes), 2)
        self.assertEqual(changes[1][0], "/api/collections/_superusers/records/admin1")
        password = changes[1][1]["password"]
        self.assertEqual(changes[1][1], {"password": password, "passwordConfirm": password})
        self.assertNotEqual(password, ENV["JELLYFIN_ADMIN_PASSWORD"])

    def test_socket_system_ignores_transient_status_and_unused_tcp_port(self):
        # Given a saved socket connection and a later status and TCP port change.
        before = self.state.snapshot()
        self.state.local.update(status="down", port="45876")

        # When the migration oracle reads the same socket connection.
        after = self.state.snapshot()

        # Then the unchanged connection is preserved regardless of unused fields.
        self.assertEqual(module.changed_keys(before, after), [])

    def test_unchanged_records_pass_without_exposing_credentials(self):
        # Given a hub with real API response shapes and stored credentials.
        before = self.state.snapshot()

        # When the hub returns the same state after recreation.
        after = self.state.snapshot()

        # Then all seeded records remain compared and no secret is saved.
        self.assertEqual(module.changed_keys(before, after), [])
        self.assertEqual(set(after), set(ROWS) | {"superuser", "admin", "local-system", "agent-key"})
        self.assertEqual(after["agent-key"], upgrade_state.fingerprint(ENV["BESZEL_AGENT_KEY"]))
        for secret in (*ENV.values(), "admin-token", "fixture-token", "fixture-password"):
            if secret != ENV["NPM_ADMIN_EMAIL"]:
                self.assertNotIn(secret, json.dumps(after))

    def test_changed_persistent_records_are_reported(self):
        # Given a saved hub snapshot and changes to each persistent collection.
        before = self.state.snapshot()
        changes = {"users": ("role", "admin"), "systems": ("users", ["admin1"]),
                   "user_settings": ("settings", {}), "system_stats": ("stats", {}),
                   "container_stats": ("stats", []), "admin": ("verified", False),
                   "local-system": ("users", ["user1"])}
        for collection, (field, value) in changes.items():
            with self.subTest(collection=collection):
                state = Client()
                target = state.local if collection == "local-system" else state.admin if collection == "admin" else state.rows[collection]
                target[field] = value

                # When the migration oracle reads the changed record.
                changed = module.changed_keys(before, state.snapshot())

                # Then that collection is reported as changed.
                self.assertIn(collection, changed)

    def test_missing_persistent_fields_fail_closed(self):
        # Given each collection can lose a required field during migration.
        for collection, fields in module.FIELDS.items():
            for field in fields:
                with self.subTest(collection=collection, field=field):
                    state = Client()
                    del state.rows[collection][field]

                    # When the migration oracle reads the incomplete response.
                    # Then it cannot save a default or report preserved state.
                    with self.assertRaises(KeyError):
                        state.snapshot()

    def test_every_saved_login_must_still_work(self):
        # Given either admin identity or the additional user loses its password.
        for login in (("_superusers", "admin"), ("users", "admin"), ("users", "fixture")):
            with self.subTest(login=login):
                state = Client()
                state.denied = login

                # When the migration oracle authenticates with saved credentials.
                # Then the rejected login blocks evidence.
                with self.assertRaises(urllib.error.HTTPError):
                    state.snapshot()

    def test_rotated_or_empty_agent_key_is_rejected(self):
        # Given the hub loses or regenerates the agent public key.
        for key in ("", "ssh-ed25519 changed"):
            with self.subTest(key=key):
                self.state.key = key

                # When the migration oracle compares it with the installed agent.
                # Then the disconnected agent blocks evidence.
                with self.assertRaisesRegex(ValueError, "agent key"):
                    self.state.snapshot()

    def test_saved_preferences_must_remain_visible_to_the_user(self):
        # Given the superuser can read preferences but their owner cannot.
        self.state.hidden = True

        # When the migration oracle repeats the read as the additional user.
        # Then a permissions regression blocks evidence.
        with self.assertRaisesRegex(ValueError, "cannot read"):
            self.state.snapshot()

    def test_truncated_inventory_is_rejected(self):
        # Given pagination hides a second system from the returned page.
        self.state.total = 2

        # When the migration oracle checks the local system inventory.
        # Then a partial inventory cannot authorize preserved state.
        with self.assertRaisesRegex(ValueError, "truncated"):
            self.state.snapshot()


unittest.main()
PY
    pass 'Beszel migration rejects lost state, broken logins and lost user access'
else
    fail 'Beszel migration rejects lost state, broken logins and lost user access'
fi
summary

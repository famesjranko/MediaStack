#!/usr/bin/env bash
# The migration oracle must reject data loss, broken credentials and dead endpoints.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin portainer-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("portainer_state", pathlib.Path(sys.argv[1]) / "tests/fixtures/portainer_state.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "tests/contracts"))
import inventory
ENV = {"JELLYFIN_ADMIN_USER": "admin", "JELLYFIN_ADMIN_PASSWORD": "shared-secret-password",
       "PORTAINER_API_KEY": "ptr-secret-homepage-key"}
USERS = [{"Id": 1, "Username": "admin", "Role": 1},
         {"Id": 2, "Username": "migration-reader", "Role": 2}]
ENDPOINT = {"Id": 3, "Name": "migration-local", "Type": 1,
            "URL": "unix:///var/run/docker.sock", "GroupId": 1, "TagIds": [4]}


class Service:
    def __init__(self):
        self.users = copy.deepcopy(USERS)
        self.endpoints = [copy.deepcopy(ENDPOINT)]
        self.tags = [{"ID": 4, "Name": "migration-tag"}]
        self.containers = [{"Names": ["/portainer"]}]
        self.logins = []
        self.auth_error = None

    def call(self, path, body=None, method="GET", headers=None):
        if path == "/auth":
            self.logins.append(body)
            if self.auth_error:
                raise self.auth_error
            return {"jwt": body["Username"]}
        if path == "/users/me":
            username = headers["Authorization"].split()[-1]
            return next(u for u in self.users if u["Username"] == username)
        if method == "PUT" and path == "/endpoints/3":
            self.endpoints[0].update(body)
            return self.endpoints[0]
        return {"/users": self.users, "/tags": self.tags, "/endpoints": self.endpoints,
                "/endpoints/3/docker/containers/json": self.containers}[path]


class Tests(unittest.TestCase):
    def setUp(self):
        self.service = Service()
        with patch.object(m, "read_env", return_value=dict(ENV)):
            self.client = m.Client()
        self.client.call = self.service.call

    def test_endpoint_contract_matches_the_real_response_field_case(self):
        # Given the accepted image's endpoint response uses Id with a capital I.
        body = [{"Id": 3, "Name": "local"}]
        entry = next(e for e in inventory.load_endpoints() if e.service == "portainer" and e.id == "endpoint-list")

        # When contract coverage looks for the declared response fields.
        present = [inventory.read_present(body, field) for field in entry.reads]

        # Then a successful endpoint read satisfies every declared field.
        self.assertTrue(present)
        self.assertTrue(all(present))

    def test_healthy_snapshot_authenticates_both_users_without_saving_secrets(self):
        # Given configured users, a tagged endpoint and the stored API token.
        # When the accepted state is recorded.
        state = self.client.snapshot()

        # Then both stored passwords authenticate and only a token fingerprint is saved.
        self.assertEqual(self.service.logins, [
            {"Username": "admin", "Password": ENV["JELLYFIN_ADMIN_PASSWORD"]},
            {"Username": "migration-reader", "Password": ENV["JELLYFIN_ADMIN_PASSWORD"]}])
        self.assertEqual(state["homepage-key"], m.fingerprint(ENV["PORTAINER_API_KEY"]))
        self.assertEqual(state["users"], USERS)
        self.assertEqual(state["endpoints"], [ENDPOINT])
        for value in ENV.values():
            if value != "admin":
                self.assertNotIn(value, json.dumps(state))

    def test_data_loss_and_schema_changes_are_refused(self):
        # Given one lost or malformed record in an otherwise configured service.
        mutations = [lambda s: s.users.pop(), lambda s: s.tags.clear(),
                     lambda s: s.endpoints.clear(), lambda s: s.endpoints[0].pop("GroupId"),
                     lambda s: s.endpoints[0].update(URL="tcp://wrong:2375"),
                     lambda s: s.endpoints[0].update(TagIds=[])]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                self.service = Service()
                self.client.call = self.service.call
                mutate(self.service)

                # When candidate state is read.
                # Then the check refuses it instead of filling missing values.
                with self.assertRaises((KeyError, ValueError, StopIteration)):
                    self.client.snapshot()

    def test_changed_ids_and_token_are_reported(self):
        # Given a saved accepted snapshot.
        before = self.client.snapshot()
        self.service.tags[0]["ID"] = 8
        self.service.endpoints[0]["TagIds"] = [8]
        self.client.key = "rotated-token"

        # When a candidate has replaced persisted IDs and the stored key.
        changed = m.changed_keys(before, self.client.snapshot())

        # Then their categories are named as changed even though authentication works.
        self.assertEqual(changed, ["endpoints", "homepage-key", "tags"])

    def test_role_escalation_is_refused(self):
        # Given the reader became an administrator during migration.
        self.service.users[1]["Role"] = 1

        # When the stored reader authenticates.
        # Then a valid login does not hide changed permissions.
        with self.assertRaisesRegex(ValueError, "identity"):
            self.client.snapshot()

    def test_failed_login_is_refused(self):
        # Given authentication fails while database reads still work.
        self.service.auth_error = OSError("authentication failed")

        # When the candidate snapshot is read.
        # Then the error blocks the snapshot.
        with self.assertRaises(OSError):
            self.client.snapshot()

    def test_dead_docker_endpoint_is_refused(self):
        # Given the local endpoint exists but cannot see the Portainer container.
        self.service.containers = []

        # When the authenticated Docker proxy is queried.
        # Then database equality cannot pass the candidate.
        with self.assertRaisesRegex(ValueError, "running container"):
            self.client.snapshot()

    def test_probe_restores_its_persisted_change(self):
        # Given the accepted fixture state.
        before = self.client.snapshot()

        # When the live oracle probe changes the endpoint and tests detection.
        self.client.probe()

        # Then its original state is restored before the migration baseline is saved.
        self.assertEqual(before, self.client.snapshot())

    def test_check_command_rejects_a_changed_saved_snapshot(self):
        # Given an accepted snapshot with a different endpoint ID.
        before = self.client.snapshot()
        before["endpoints"][0]["Id"] = 99
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "state.json"
            path.write_text(json.dumps(before))

            # When the real check command compares it with the running state.
            # Then the command fails before any reconfiguration can repair it.
            with patch.object(m, "Client", return_value=self.client), patch.object(m, "STATE", path), patch.object(sys, "argv", ["fixture", "check"]):
                with self.assertRaisesRegex(ValueError, "endpoints"):
                    m.main()


unittest.main(argv=["portainer-state"], verbosity=2)
PY
    pass 'Portainer migration oracle rejects lost state and unusable credentials'
else
    fail 'Portainer migration oracle rejects lost state and unusable credentials'
fi
summary

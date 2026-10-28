#!/usr/bin/env bash
# tests/unit/contracts-inventory.sh
#
# Proves the shared reading of the contract format in
# tests/contracts/inventory.py: how a route placeholder matches a path, which
# response values prove a declared read, which entries the schema refuses, and
# what the inventory fingerprint covers. check.py, observe.py and the preflight
# verdict all depend on these rules. Pure python3, no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-inventory"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "tests/contracts"))
import inventory  # noqa: E402

UUID = "3f2b8c1e-9a4d-4e6f-8b7a-0c1d2e3f4a5b"


def endpoint(**changes):
    item = {"id": "probe", "method": "GET", "path": "/probe", "sends": [], "reads": [],
            "callers": []}
    item.update(changes)
    return {"endpoints": [item]}


class RouteContract(unittest.TestCase):
    def test_id_matches_exactly_one_segment(self):
        # Given an entry route that ends in one {id} placeholder.
        route = "/api/v3/qualityprofile/{id}"

        # When a path with two segments after the prefix is matched against it.
        matched = inventory.route_matches(route, "/api/v3/qualityprofile/1/2")

        # Then it does not match.
        self.assertFalse(matched)
        # And the same route matches a path with one numeric segment there.
        self.assertTrue(inventory.route_matches(route, "/api/v3/qualityprofile/1"))

    def test_id_does_not_match_a_word(self):
        # Given an entry route whose last segment is {id}.
        route = "/api/v1/settings/{id}"

        # When an unlisted sibling route with a plain word there is matched.
        matched = inventory.route_matches(route, "/api/v1/settings/about")

        # Then it does not match.
        self.assertFalse(matched)

    def test_id_matches_generated_identifiers(self):
        # Given an entry route whose last segment is {id}.
        route = "/Items/{id}"

        # When digits, a UUID and a 32-digit hex id are matched.
        matches = [inventory.route_matches(route, f"/Items/{value}")
                   for value in ("42", UUID, "a" * 16 + "0123456789abcdef")]

        # Then each one matches.
        self.assertEqual(matches, [True, True, True])

    def test_key_matches_any_one_segment(self):
        # Given an entry route keyed by name with the {key} placeholder.
        route = "/api/v2.0/indexers/{key}/config"

        # When a name and a path with an extra segment are matched.
        name = inventory.route_matches(route, "/api/v2.0/indexers/yts/config")
        extra = inventory.route_matches(route, "/api/v2.0/indexers/yts/x/config")

        # Then the name matches and the extra segment does not.
        self.assertEqual((name, extra), (True, False))

    def test_unlisted_seerr_settings_route_has_no_entry(self):
        # Given the real inventory.
        found = inventory.load_endpoints()

        # When Seerr settings routes are matched.
        about = inventory.match(found, "seerr", "GET", "/api/v1/settings/about")
        sonarr = inventory.match(found, "seerr", "GET", "/api/v1/settings/sonarr")

        # Then the unlisted route matches nothing and the listed one matches its entry.
        self.assertIsNone(about)
        self.assertEqual(sonarr.id if sonarr else None, "sonarr-settings-get")


class ReadContract(unittest.TestCase):
    def test_null_is_not_a_read(self):
        # Given a response whose declared field is null.
        body = {"apiKey": None}

        # When the read is checked.
        present = inventory.read_present(body, "apiKey")

        # Then it is not present.
        self.assertFalse(present)

    def test_empty_values_are_not_reads(self):
        # Given responses whose declared field is an empty string, list or object.
        bodies = [{"apiKey": ""}, {"apiKey": []}, {"apiKey": {}}]

        # When the read is checked in each.
        present = [inventory.read_present(body, "apiKey") for body in bodies]

        # Then none of them is present.
        self.assertEqual(present, [False, False, False])

    def test_zero_and_false_are_reads(self):
        # Given responses whose declared field is 0 or false.
        bodies = [{"cutoff": 0}, {"cutoff": False}]

        # When the read is checked in each.
        present = [inventory.read_present(body, "cutoff") for body in bodies]

        # Then both are present.
        self.assertEqual(present, [True, True])


class SchemaContract(unittest.TestCase):
    def test_empty_expect_list_is_refused(self):
        # Given an entry with an empty expect list.
        contract = endpoint(expect=[])

        # When the contract is validated.
        errors = inventory.validate("probe", contract)

        # Then the entry is refused by name.
        self.assertEqual(errors, ["probe probe: expect must be a non-empty list of HTTP statuses"])

    def test_unknown_placeholder_is_refused(self):
        # Given an entry whose path holds a placeholder that is not {id} or {key}.
        contract = endpoint(path="/probe/{name}")

        # When the contract is validated.
        errors = inventory.validate("probe", contract)

        # Then the entry is refused by name.
        self.assertEqual(errors, ["probe probe: path may hold only whole {id} or {key} segments"])


def exec_entry(entry_id, command, match=None):
    return inventory.ExecEntry("fail2ban", entry_id, tuple(command), match, (), None)


class ExecContract(unittest.TestCase):
    def test_longest_command_prefix_wins(self):
        # Given an unban entry and an unban-all entry whose command extends it.
        found = [exec_entry("unban", ["fail2ban-client", "unban"]),
                 exec_entry("unban-all", ["fail2ban-client", "unban", "--all"])]

        # When the argv of an unban --all and of a single unban are matched.
        every = inventory.exec_match(found, "fail2ban", ["fail2ban-client", "unban", "--all"])
        one = inventory.exec_match(found, "fail2ban", ["fail2ban-client", "unban", "10.0.0.9"])

        # Then each one hits its own entry.
        self.assertEqual((every.id, one.id), ("unban-all", "unban"))

    def test_match_reads_the_word_after_the_prefix(self):
        # Given an sh -c entry that requires fail2ban-regex in its script.
        found = [exec_entry("regex", ["sh", "-c"], match="fail2ban-regex")]

        # When a script with it and a script without it are matched.
        hit = inventory.exec_match(found, "fail2ban", ["sh", "-c", "fail2ban-regex /l f"])
        miss = inventory.exec_match(found, "fail2ban", ["sh", "-c", "date"])

        # Then only the first one hits the entry.
        self.assertEqual((hit and hit.id, miss), ("regex", None))

    def test_command_with_a_variable_is_refused(self):
        # Given an exec entry whose command holds a shell variable.
        contract = {"endpoints": [], "exec": [
            {"id": "status", "command": ["fail2ban-client", "status", "$jail"], "callers": []}]}

        # When the contract is validated.
        errors = inventory.validate("fail2ban", contract)

        # Then the entry is refused by name.
        self.assertEqual(errors, ["fail2ban status: command must be a non-empty list of literal words"])

    def test_exec_id_may_not_repeat_an_endpoint_id(self):
        # Given an exec entry with the id of an endpoint in the same file.
        contract = endpoint()
        contract["exec"] = [{"id": "probe", "command": ["true"], "callers": []}]

        # When the contract is validated.
        errors = inventory.validate("probe", contract)

        # Then the exec entry is refused as a duplicate.
        self.assertEqual(errors, ["probe probe: duplicate id"])


class FingerprintContract(unittest.TestCase):
    def test_fingerprint_covers_file_content(self):
        # Given a copy of the inventory.
        with tempfile.TemporaryDirectory() as folder:
            copy = pathlib.Path(folder)
            for path in inventory.CONTRACT_DIR.glob("*.yml"):
                shutil.copy(path, copy / path.name)
            before = inventory.fingerprint(copy)

            # When one file's content changes and its name does not.
            target = copy / "sonarr.yml"
            target.write_text(target.read_text().replace("indexer-list", "indexer-lists"))

            # Then the fingerprint changes.
            self.assertNotEqual(inventory.fingerprint(copy), before)


class Lines(unittest.TestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        print(f"PASS\t{test.id().rsplit('.', 1)[-1]}")

    def _bad(self, test, err):
        print(f"FAIL\t{getattr(test, 'id', lambda: str(test))().rsplit('.', 1)[-1]}")
        print(self._exc_info_to_string(err, test), file=sys.stderr)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._bad(test, err)

    def addError(self, test, err):
        super().addError(test, err)
        self._bad(test, err)


result = Lines()
unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
sys.exit(0 if result.wasSuccessful() and result.testsRun else 1)
PY
)
rc=$?

while IFS=$'\t' read -r status name; do
    case "$status" in
        PASS) pass "$name" ;;
        FAIL) fail "$name" ;;
    esac
done <<<"$results"
[[ "$results" == *PASS* ]] || fail "contract inventory cases ran" "no case reported a result"
((rc == 0)) || fail "contract inventory suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

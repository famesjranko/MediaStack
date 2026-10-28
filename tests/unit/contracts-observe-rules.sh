#!/usr/bin/env bash
# tests/unit/contracts-observe-rules.sh
#
# Proves the reducer rules in tests/contracts/observe.py that real curl on
# 127.0.0.1 cannot reach: a request to a public address is ignored, an
# unlisted path keeps only route-like segments, and a request at exactly a
# container's start time binds to that container's image. It also proves the
# exec reduction over records in the shape tests/lib/contract-trace-docker.sh
# writes: entry matching, exit counts, image binding, and an unlisted exec
# reported without its argument values. The end-to-end trace path is proved by
# tests/unit/contracts-observe.sh, the docker shim by
# tests/unit/contract-trace-docker.sh. Pure python3, no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-observe-rules"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "tests/contracts"))
import inventory  # noqa: E402
import observe  # noqa: E402

CANDIDATE = "lscr.io/linuxserver/sonarr@sha256:" + "c" * 64
ACCEPTED = "lscr.io/linuxserver/sonarr@sha256:" + "a" * 64


class ReducerRules(unittest.TestCase):
    found = inventory.load_endpoints()

    def test_external_target_is_ignored(self):
        # Given a request to a public address on a port that Sonarr owns locally.
        request = observe.Request(1, ("", 0), {("example.com", 8989): "93.184.216.34"},
                                  bytearray(b"GET /api/v3/indexer HTTP/1.1\r\n"
                                            b"Host: example.com:8989\r\n\r\n"))

        # When the request is tallied.
        result = observe.tally([request], self.found, {8989: "sonarr"},
                               observe.Binder({}, {}))

        # Then it is counted as a request but not as Sonarr traffic or as unparsed.
        self.assertEqual((result.requests, result.unparsed), (1, 0))
        self.assertEqual((result.entries, result.unmatched), ({}, {}))

    def test_unmatched_path_keeps_only_route_like_segments(self):
        # Given an unlisted path with a short mixed-case token, a plain word and a number.
        path = "/api/v3/Ab3xYz9/status/42"

        # When the path is redacted.
        redacted = observe.redact(path, observe.route_literals(self.found))

        # Then only the token is hidden.
        self.assertEqual(redacted, "/api/v3/{redacted}/status/42")

    def test_request_at_the_start_time_binds_to_the_started_image(self):
        # Given the accepted image started at 100 and the candidate at 200.
        binder = observe.Binder({"sonarr": [(100, ACCEPTED), (200, CANDIDATE)]},
                                {"sonarr": CANDIDATE})

        # When a request that started at exactly 200 is bound.
        side = binder.side("sonarr", 200)

        # Then it binds to the candidate.
        self.assertEqual(side, "candidate")


FAIL2BAN = "crazymax/fail2ban@sha256:" + "f" * 64
OLD_FAIL2BAN = "crazymax/fail2ban@sha256:" + "e" * 64
BESZEL = "henrygd/beszel@sha256:" + "b" * 64


def record(container, *argv, rc=0, t=500):
    return observe.ExecRecord(t, container, tuple(argv), rc)


class ExecReduction(unittest.TestCase):
    found = inventory.load_exec()
    binder = observe.Binder({"fail2ban": [(100, OLD_FAIL2BAN), (400, FAIL2BAN)],
                             "beszel": [(100, BESZEL)]},
                            {"fail2ban": FAIL2BAN, "beszel": BESZEL})

    def reduce(self, *records):
        return observe._exec_report(observe.exec_tally(list(records), self.found, self.binder))

    def test_exit_codes_are_counted_per_entry(self):
        # Given two fail2ban reloads on the candidate, one that exits 0 and one that exits 1.
        records = (record("fail2ban", "fail2ban-client", "reload"),
                   record("fail2ban", "fail2ban-client", "reload", rc=1))

        # When the records are reduced.
        report = self.reduce(*records)

        # Then the reload entry counts each exit status on the candidate.
        self.assertEqual(report["entries"]["fail2ban"]["client-reload"],
                         {"candidate": {"0": 1, "1": 1}, "other": {}})

    def test_exec_before_the_candidate_started_binds_to_other(self):
        # Given a status call made while the earlier fail2ban image ran.
        early = record("fail2ban", "fail2ban-client", "status", t=200)

        # When the record is reduced.
        report = self.reduce(early)

        # Then it counts for the other image.
        self.assertEqual(report["entries"]["fail2ban"]["client-status"],
                         {"candidate": {}, "other": {"0": 1}})

    def test_sh_script_is_matched_by_its_substring(self):
        # Given an sh -c call whose script runs fail2ban-regex.
        call = record("fail2ban", "sh", "-c", "cat x > /tmp/l && fail2ban-regex /tmp/l f")

        # When the record is reduced.
        report = self.reduce(call)

        # Then it counts for the regex entry, not as unlisted.
        self.assertEqual(report["entries"]["fail2ban"]["regex-count"]["candidate"], {"0": 1})
        self.assertEqual(report["unmatched"], {})

    def test_unlisted_exec_is_reported_without_argument_values(self):
        # Given a beszel exec outside the inventory whose argv carries a password.
        call = record("beszel", "/beszel", "superuser", "create", "admin@x.test", "pw-Secret-123")

        # When the record is reduced.
        text = json.dumps(self.reduce(call))

        # Then it is unlisted as argv0 and inventory words only.
        self.assertIn('"beszel /beszel superuser ...": {"candidate": 1, "other": 0}', text)
        # And no argument value is in the report.
        for value in ("create", "admin@x.test", "pw-Secret-123"):
            self.assertNotIn(value, text)

    def test_listed_exec_reports_no_argument_values(self):
        # Given the listed superuser upsert with an email and a password.
        call = record("beszel", "/beszel", "superuser", "upsert", "admin@x.test", "pw-Secret-123")

        # When the record is reduced.
        text = json.dumps(self.reduce(call))

        # Then the entry counts it and neither value is in the report.
        self.assertIn('"superuser-upsert": {"candidate": {"0": 1}', text)
        self.assertNotIn("admin@x.test", text)
        self.assertNotIn("pw-Secret-123", text)

    def test_reducer_reports_exec_records_beside_traces(self):
        # Given a trace directory with one exec record and one file that is not a record.
        with tempfile.TemporaryDirectory() as folder:
            traces = pathlib.Path(folder)
            (traces / "500-1.exec").write_text(json.dumps(
                {"t": 500, "container": "fail2ban", "argv": ["fail2ban-client", "reload"], "rc": 1}))
            (traces / "501-1.exec").write_text("")
            events = traces / "events.jsonl"
            events.write_text(json.dumps({"Type": "container", "Action": "start", "timeNano": 400,
                                          "Actor": {"Attributes": {
                                              "com.docker.compose.service": "fail2ban",
                                              "image": FAIL2BAN}}}) + "\n")
            output = traces / "contracts.json"

            # When observe.py reduces the directory.
            observe.main(["--traces", str(traces), "--events", str(events), "--ports", "{}",
                          "--candidates", f"fail2ban={FAIL2BAN}", "--scenario", "fresh-install",
                          "--run-id", "run-1", "--output", str(output)])
            report = json.loads(output.read_text())

        # Then the schema is 2 and the exec section counts the record and the unparsed file.
        self.assertEqual(report["schema"], 2)
        self.assertEqual(report["exec"], {
            "calls": 1, "unparsed": 1, "unmatched": {},
            "entries": {"fail2ban": {"client-reload": {"candidate": {"1": 1}, "other": {}}}}})


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
[[ "$results" == *PASS* ]] || fail "contract reducer rule cases ran" "no case reported a result"
((rc == 0)) || fail "contract reducer rule suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

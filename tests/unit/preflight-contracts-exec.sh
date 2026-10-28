#!/usr/bin/env bash
# tests/unit/preflight-contracts-exec.sh
#
# Proves the docker exec rules of the contract verdict in
# tests/preflight/contracts.py: each exec entry of a candidate service without
# `unexercised` must run on the candidate with an accepted exit status
# (`expect_exit`, or 0), and an exec into the candidate outside the inventory
# fails it. The evidence is contracts.json data in the shape
# tests/contracts/observe.py writes, judged against a small fail2ban
# inventory. The HTTP rules are proved by tests/unit/preflight-contracts.sh.
# Pure python3, no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="preflight-contracts-exec"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import pathlib
import sys
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tests/contracts"))
from inventory import ExecEntry  # noqa: E402
from preflight import contracts  # noqa: E402

FINGERPRINT = "f" * 64
TIMES = "×"
CANDIDATES = {"fail2ban": "crazymax/fail2ban@sha256:" + "c" * 64}
FOUND = [
    ExecEntry("fail2ban", "client-reload", ("fail2ban-client", "reload"), None, (), None),
    ExecEntry("fail2ban", "client-status", ("fail2ban-client", "status"), None, (0, 255), None),
    ExecEntry("fail2ban", "client-unban", ("fail2ban-client", "unban"), None, (),
              "launcher-menu"),
]
JOB = {"id": "p1-fail2ban.fresh-install", "scenario": "fresh-install", "run_id": "run-1",
       "combination": ["fail2ban"], "services": ["fail2ban"]}


def exits(candidate=None, other=None):
    return {"candidate": candidate or {}, "other": other or {}}


def data(entries, unmatched=None, unparsed=0):
    return {"schema": 2, "inventory": FINGERPRINT, "scenario": "fresh-install",
            "run_id": "run-1", "candidates": CANDIDATES, "requests": 1, "unparsed": 0,
            "entries": {}, "unmatched": {},
            "exec": {"calls": 3, "unparsed": unparsed, "entries": {"fail2ban": entries},
                     "unmatched": unmatched or {}}}


COMPLETE = {"client-reload": exits({"0": 2}), "client-status": exits({"0": 1})}


def judge(evidence):
    result = contracts.verdict([(JOB, evidence)], ["fail2ban"], CANDIDATES, FINGERPRINT, FOUND)
    return result, [failure.message for failure in result.failures]


class ExecVerdict(unittest.TestCase):
    def test_complete_exec_evidence_passes(self):
        # Given every exec entry ran on the candidate and exited 0.
        evidence = data(COMPLETE)

        # When the verdict judges fail2ban.
        result, failures = judge(evidence)

        # Then nothing fails and the exempt unban entry is reported.
        self.assertEqual(failures, [])
        self.assertEqual(result.exempt, {"fail2ban": ["client-unban (launcher-menu)"]})

    def test_nonzero_exit_fails_the_entry(self):
        # Given the reload exited 1 on the candidate.
        evidence = data(dict(COMPLETE, **{"client-reload": exits({"1": 1})}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the failure names the entry and its exit status.
        self.assertEqual(failures, ["fail2ban client-reload: exit 1"])

    def test_expect_exit_accepts_a_listed_status(self):
        # Given the status entry, which accepts 0 and 255, exited 255 on the candidate.
        evidence = data(dict(COMPLETE, **{"client-status": exits({"255": 1})}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then nothing fails.
        self.assertEqual(failures, [])

    def test_exec_only_on_another_image_fails_the_entry(self):
        # Given the reload ran only while another fail2ban image was running.
        evidence = data(dict(COMPLETE, **{"client-reload": exits(other={"0": 1})}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the entry is not exercised on the candidate.
        self.assertEqual(failures, [
            "fail2ban client-reload: not exercised on candidate "
            f"(seen exit 0{TIMES}1 on another image in fresh-install)"])

    def test_unlisted_exec_fails_the_service(self):
        # Given an exec into fail2ban that matches no entry.
        evidence = data(COMPLETE, {"fail2ban fail2ban-client ...": {"candidate": 1, "other": 0}})

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the failure names the unlisted exec and the scenario.
        self.assertEqual(failures, ["fail2ban: unlisted exec fail2ban-client ... (fresh-install)"])

    def test_unlisted_exec_on_another_image_fails_the_service(self):
        # Given an unlisted exec into fail2ban made only while another image ran.
        evidence = data(COMPLETE, {"fail2ban fail2ban-client ...": {"candidate": 0, "other": 1}})

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then it fails as for an unlisted HTTP call.
        self.assertEqual(failures, ["fail2ban: unlisted exec fail2ban-client ... (fresh-install)"])

    def test_unlisted_exec_without_a_command_is_named(self):
        # Given an unlisted exec into fail2ban that has no command.
        evidence = data(COMPLETE, {"fail2ban": {"candidate": 1, "other": 0}})

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the failure says it had no command.
        self.assertEqual(failures, ["fail2ban: unlisted exec (no command) (fresh-install)"])

    def test_exit_key_that_is_not_a_status_is_malformed(self):
        # Given evidence that counts an exit key that is not a number.
        evidence = data(dict(COMPLETE, **{"client-reload": exits({"ok": 1})}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the job fails as malformed.
        self.assertIn("contracts.json is malformed", failures)

    def test_unexercised_entry_that_runs_is_stale(self):
        # Given the exempt unban entry did run on the candidate.
        evidence = data(dict(COMPLETE, **{"client-unban": exits({"0": 1})}))

        # When the verdict judges fail2ban.
        result, failures = judge(evidence)

        # Then nothing fails and the exemption is reported stale.
        self.assertEqual(failures, [])
        self.assertEqual(len(result.stale), 1)
        self.assertIn("fail2ban client-unban: exempt as launcher-menu", result.stale[0])

    def test_unparsed_exec_record_fails_the_job(self):
        # Given complete evidence that also counts one exec record it could not parse.
        evidence = data(COMPLETE, unparsed=1)

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the job fails and so fail2ban has no qualifying evidence.
        self.assertEqual(failures, ["contract trace has 1 unparsed exec record",
                                    "no qualifying contract evidence"])

    def test_unknown_exec_entry_fails_the_job(self):
        # Given evidence that names an exec entry the inventory lacks.
        evidence = data(dict(COMPLETE, **{"client-ban": exits({"0": 1})}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the job fails and names the unknown entry.
        self.assertIn("unknown exec entry fail2ban client-ban", failures)

    def test_exec_section_without_exits_is_malformed(self):
        # Given evidence whose exec entry lacks its other-image counts.
        evidence = data(dict(COMPLETE, **{"client-reload": {"candidate": {"0": 1}}}))

        # When the verdict judges fail2ban.
        _, failures = judge(evidence)

        # Then the job fails as malformed.
        self.assertIn("contracts.json is malformed", failures)


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
unittest.defaultTestLoader.loadTestsFromTestCase(ExecVerdict).run(result)
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
[[ "$results" == *PASS* ]] || fail "contract exec verdict cases ran" "no case reported a result"
((rc == 0)) || fail "contract exec verdict suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

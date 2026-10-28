#!/usr/bin/env bash
# tests/unit/preflight-contracts.sh
#
# Proves each contract-coverage acceptance rule in tests/preflight/contracts.py
# can fail, that exemptions and held services do not block, and that a
# candidate without entries passes only with an explicit report. The evidence is
# contracts.json data in the shape tests/contracts/observe.py writes, judged
# against a small Sonarr and Portainer inventory. Pure python3, no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="preflight-contracts"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import copy
import json
import os
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tests/contracts"))
from inventory import Endpoint, join_path  # noqa: E402
from preflight import contracts  # noqa: E402

FINGERPRINT = "f" * 64
TIMES = "×"
CANDIDATES = {"sonarr": "lscr.io/linuxserver/sonarr@sha256:" + "c" * 64,
              "radarr": "lscr.io/linuxserver/radarr@sha256:" + "b" * 64,
              "ddns-updater": "qmcgaw/ddns-updater@sha256:" + "d" * 64}


def entry(service, entry_id, method, base, path, reads=(), expect=(), unexercised=None):
    return Endpoint(service, entry_id, method, path, join_path(base, path), tuple(expect),
                    tuple(reads), unexercised)


FOUND = [
    entry("sonarr", "readiness", "GET", "/", "/", expect=(200, 302)),
    entry("sonarr", "quality-profile-list", "GET", "/api/v3", "/qualityprofile",
          reads=("id", "name", "items[].quality.id")),
    entry("sonarr", "indexer-list", "GET", "/api/v3", "/indexer", reads=("id", "name")),
    entry("sonarr", "encoding-probe", "GET", "/api/v3", "/system/gpu", unexercised="gpu"),
    entry("portainer", "admin-check", "GET", "/", "/api/users/admin/check", expect=(204, 404)),
]


def job(job_id, scenario, services=("sonarr",)):
    return {"id": job_id, "scenario": scenario, "run_id": f"run-{job_id}",
            "combination": list(services), "services": list(services)}


def data(the_job, entries, unmatched=None, requests=5, unparsed=0):
    return {"schema": 1, "inventory": FINGERPRINT, "scenario": the_job["scenario"],
            "run_id": the_job["run_id"],
            "candidates": {s: CANDIDATES[s] for s in the_job["combination"]},
            "requests": requests, "unparsed": unparsed,
            "entries": entries, "unmatched": unmatched or {}}


def seen(candidate=None, other=None, reads=()):
    return {"candidate": candidate or {}, "other": other or {}, "reads": sorted(reads)}


FRESH = job("p1-sonarr.fresh-install", "fresh-install")
COMPLETE = {"sonarr": {
    "readiness": seen({"302": 1}),
    "quality-profile-list": seen({"200": 2}, reads=("id", "name", "items[].quality.id")),
    "indexer-list": seen({"200": 1}, reads=("id", "name")),
}}


def judge(*evidence, services=("sonarr",)):
    result = contracts.verdict(list(evidence), list(services), CANDIDATES, FINGERPRINT, FOUND)
    return result, [failure.message for failure in result.failures]


def with_entries(change):
    entries = copy.deepcopy(COMPLETE)
    change(entries["sonarr"])
    return data(FRESH, entries)


class VerdictContract(unittest.TestCase):
    def test_complete_evidence_passes(self):
        # Given one job that called every Sonarr entry on the candidate with all reads.
        evidence = (FRESH, data(FRESH, COMPLETE))

        # When the verdict judges Sonarr.
        _, failures = judge(evidence)

        # Then nothing fails.
        self.assertEqual(failures, [])

    def test_not_found_status_fails_the_entry(self):
        # Given the quality profile list answered 404 twice on the candidate.
        evidence = with_entries(lambda s: s.update({"quality-profile-list": seen({"404": 2})}))

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then the failure names the entry and what was seen.
        self.assertEqual(failures, [
            f"sonarr quality-profile-list: not exercised on candidate (seen 404{TIMES}2 in fresh-install)"])

    def test_missing_read_fails_the_entry(self):
        # Given the quality profile list response lacked items[].quality.id.
        evidence = with_entries(
            lambda s: s.update({"quality-profile-list": seen({"200": 1}, reads=("id", "name"))}))

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then the failure names the entry and the missing read.
        self.assertEqual(failures, ["sonarr quality-profile-list: missing reads items[].quality.id"])

    def test_empty_list_fails_every_read(self):
        # Given the indexer list only ever answered with an empty list.
        evidence = with_entries(lambda s: s.update({"indexer-list": seen({"200": 3})}))

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then every declared read of the entry is missing.
        self.assertEqual(failures, ["sonarr indexer-list: missing reads id, name"])

    def test_unlisted_call_fails_the_service(self):
        # Given an upgrade-path job that called a Sonarr route the inventory lacks.
        upgrade = job("p1-sonarr.upgrade-path", "upgrade-path")
        unlisted = data(upgrade, {}, {"sonarr GET /api/v3/system/status": {"candidate": 1, "other": 0}})

        # When the verdict judges Sonarr over both jobs.
        _, failures = judge((FRESH, data(FRESH, COMPLETE)), (upgrade, unlisted))

        # Then the failure names the call and the scenario.
        self.assertEqual(failures, ["sonarr GET /api/v3/system/status: unlisted call (upgrade-path)"])

    def test_call_only_on_another_image_fails_the_entry(self):
        # Given the indexer list was called only while the accepted image ran.
        evidence = with_entries(lambda s: s.update({"indexer-list": seen(other={"200": 3})}))

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then the entry is not exercised on the candidate, and the message says where it was.
        self.assertEqual(failures, ["sonarr indexer-list: not exercised on candidate "
                                    f"(seen 200{TIMES}3 on another image in fresh-install)"])

    def test_no_traced_request_is_an_inactive_trace(self):
        # Given a job whose trace recorded no product request at all.
        evidence = data(FRESH, {}, requests=0)

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails as an inactive trace.
        self.assertIn(contracts.Failure(FRESH["id"], "contract trace inactive: "
                                        "no product request was traced"), result.failures)

    def test_traffic_on_other_images_only_is_an_active_trace(self):
        # Given a ddns-updater job whose traced requests all reached other services.
        ddns = job("p1-ddns-updater.fresh-install", "fresh-install", services=("ddns-updater",))
        evidence = data(ddns, {"sonarr": {"readiness": seen(other={"200": 1})}}, requests=1)

        # When the verdict judges ddns-updater.
        result, _ = judge((ddns, evidence), services=("ddns-updater",))

        # Then nothing fails.
        self.assertEqual(result.failures, [])

    def test_service_without_entries_passes_and_is_reported(self):
        # Given an active ddns-updater job, and no inventory entry for ddns-updater.
        ddns = job("p1-ddns-updater.fresh-install", "fresh-install", services=("ddns-updater",))

        # When the verdict judges ddns-updater.
        result, _ = judge((ddns, data(ddns, {})), services=("ddns-updater",))

        # Then nothing fails.
        self.assertEqual(result.failures, [])
        # And the verdict says acceptance rests on the scenarios.
        self.assertEqual(result.uncovered,
                         ["ddns-updater: no contract entries; acceptance rests on its scenarios"])

    def test_unparsed_request_fails_the_job(self):
        # Given complete evidence from a job in which one traced request could not be parsed.
        evidence = data(FRESH, COMPLETE, unparsed=1)

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails and gives Sonarr no evidence.
        self.assertEqual(result.failures, [
            contracts.Failure(FRESH["id"], "contract trace has 1 unparsed request"),
            contracts.Failure("sonarr", "no qualifying contract evidence")])

    def test_other_candidate_ref_fails_the_job(self):
        # Given complete evidence bound to a Sonarr ref that is not the plan's candidate.
        evidence = dict(data(FRESH, COMPLETE), candidates={"sonarr": "sonarr@sha256:" + "e" * 64})

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails on the candidate refs.
        self.assertIn(contracts.Failure(FRESH["id"], "contracts.json candidates do not match the "
                                        "job's planned candidates"), result.failures)

    def test_other_run_id_fails_the_job(self):
        # Given complete evidence that names another run.
        evidence = dict(data(FRESH, COMPLETE), run_id="run-other")

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails as evidence from another run.
        self.assertIn(contracts.Failure(FRESH["id"], "contracts.json comes from another run"),
                      result.failures)

    def test_other_scenario_fails_the_job(self):
        # Given complete evidence that names another scenario.
        evidence = dict(data(FRESH, COMPLETE), scenario="upgrade-path")

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails on the scenario.
        self.assertIn(contracts.Failure(FRESH["id"], "contracts.json schema or scenario does not "
                                        "match the job"), result.failures)

    def test_boolean_schema_is_refused(self):
        # Given complete evidence whose schema is true, which equals 1 in Python.
        evidence = dict(data(FRESH, COMPLETE), schema=True)

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails as malformed.
        self.assertIn(contracts.Failure(FRESH["id"], "contracts.json is malformed"), result.failures)

    def test_entry_without_reads_is_malformed(self):
        # Given evidence with an entry record that lacks its reads list.
        evidence = with_entries(lambda s: s.update({"indexer-list": {"candidate": {"200": 1},
                                                                     "other": {}}}))

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails as malformed.
        self.assertIn(contracts.Failure(FRESH["id"], "contracts.json is malformed"), result.failures)

    def test_undeclared_read_fails_the_job(self):
        # Given evidence that reports a read the indexer list entry does not declare.
        evidence = with_entries(
            lambda s: s.update({"indexer-list": seen({"200": 1}, reads=("id", "name", "secret"))}))

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails and names the entry.
        self.assertIn(contracts.Failure(FRESH["id"], "sonarr indexer-list: reports reads it does "
                                        "not declare"), result.failures)

    def test_redirect_is_not_accepted_without_expect(self):
        # Given the quality profile list, which has no expect list, answered only 302.
        evidence = with_entries(lambda s: s.update({"quality-profile-list": seen(
            {"302": 1}, reads=("id", "name", "items[].quality.id"))}))

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then the entry is not exercised on the candidate.
        self.assertEqual(failures, [f"sonarr quality-profile-list: not exercised on candidate "
                                    f"(seen 302{TIMES}1 in fresh-install)"])

    def test_job_for_another_service_does_not_count(self):
        # Given Sonarr's own job lacks the indexer list and a Radarr job called it.
        radarr = job("p1-radarr.fresh-install", "fresh-install", services=("radarr",))
        radarr_data = data(radarr, COMPLETE)
        own = with_entries(lambda s: s.pop("indexer-list"))

        # When the verdict judges Sonarr over both jobs.
        _, failures = judge((FRESH, own), (radarr, radarr_data))

        # Then Sonarr's indexer list is still not exercised.
        self.assertEqual(failures, ["sonarr indexer-list: not exercised on candidate (never called)"])

    def test_unlisted_call_on_another_image_fails_the_service(self):
        # Given complete evidence plus an unlisted Sonarr call made while another image ran.
        evidence = data(FRESH, COMPLETE, {"sonarr GET /api/v3/system/status": {"candidate": 0,
                                                                               "other": 1}})

        # When the verdict judges Sonarr.
        _, failures = judge((FRESH, evidence))

        # Then the unlisted call fails Sonarr.
        self.assertEqual(failures, ["sonarr GET /api/v3/system/status: unlisted call (fresh-install)"])

    def test_fingerprint_mismatch_fails_the_job(self):
        # Given evidence recorded against another inventory.
        evidence = dict(data(FRESH, COMPLETE), inventory="0" * 64)

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails on the fingerprint and gives Sonarr no evidence.
        self.assertEqual(result.failures, [
            contracts.Failure(FRESH["id"], "contract inventory fingerprint does not match the tested source"),
            contracts.Failure("sonarr", "no qualifying contract evidence")])

    def test_unknown_entry_fails_the_job(self):
        # Given evidence that reports an entry id the inventory does not have.
        evidence = with_entries(lambda s: s.update({"renamed-entry": seen({"200": 1})}))

        # When the verdict judges the job.
        result, _ = judge((FRESH, evidence))

        # Then the job fails and names the unknown entry.
        self.assertIn(contracts.Failure(FRESH["id"], "unknown contract entry sonarr renamed-entry"),
                      result.failures)

    def test_union_across_two_jobs_satisfies_the_entries(self):
        # Given fresh-install saw some reads and upgrade-path saw the rest and the indexer list.
        upgrade = job("p1-sonarr.upgrade-path", "upgrade-path")
        first = data(FRESH, {"sonarr": {
            "readiness": seen({"200": 1}),
            "quality-profile-list": seen({"200": 1}, reads=("id", "name"))}})
        second = data(upgrade, {"sonarr": {
            "quality-profile-list": seen({"200": 1}, reads=("items[].quality.id",)),
            "indexer-list": seen({"200": 1}, reads=("id", "name"))}})

        # When the verdict judges Sonarr over both jobs.
        _, failures = judge((FRESH, first), (upgrade, second))

        # Then the combined evidence passes.
        self.assertEqual(failures, [])

    def test_exempt_entry_does_not_block(self):
        # Given complete evidence in which the gpu-exempt entry was never called.
        evidence = data(FRESH, COMPLETE)

        # When the verdict judges Sonarr.
        result, failures = judge((FRESH, evidence))

        # Then the exempt entry causes no failure and no stale report.
        self.assertEqual(failures, [])
        self.assertEqual(result.stale, [])
        # And it is listed with its reason for the digest PR body.
        self.assertEqual(result.exempt, {"sonarr": ["encoding-probe (gpu)"]})

    def test_exercised_exempt_entry_is_reported_stale(self):
        # Given the gpu-exempt entry was called successfully on the candidate.
        evidence = with_entries(lambda s: s.update({"encoding-probe": seen({"200": 1})}))

        # When the verdict judges Sonarr.
        result, failures = judge((FRESH, evidence))

        # Then it is reported as a stale exemption, not as a failure.
        self.assertEqual(failures, [])
        self.assertEqual(result.stale, [
            "sonarr encoding-probe: exempt as gpu but exercised on candidate in fresh-install"])

    def test_held_service_entries_do_not_block_another_service(self):
        # Given a Sonarr job that never exercised held Portainer's entry and made an unlisted Portainer call.
        evidence = data(FRESH, COMPLETE, {"portainer GET /api/status": {"candidate": 0, "other": 2}})

        # When the verdict judges the Sonarr candidate.
        _, failures = judge((FRESH, evidence))

        # Then Portainer's entry and call do not fail Sonarr.
        self.assertEqual(failures, [])

    def test_oversized_evidence_file_is_refused(self):
        # Given a contracts.json of exactly 1 MB.
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "contracts.json"
            path.write_text(json.dumps({"pad": "x" * (contracts.MAX_BYTES - 11)}))

            # When the verifier reads it.
            # Then it is refused before parsing.
            with self.assertRaises(ValueError):
                contracts.read_contracts(path)

    def test_symlinked_evidence_file_is_refused(self):
        # Given a contracts.json that is a symlink to a well-formed file.
        with tempfile.TemporaryDirectory() as folder:
            real = pathlib.Path(folder) / "real.json"
            real.write_text(json.dumps(data(FRESH, COMPLETE)))
            link = pathlib.Path(folder) / "contracts.json"
            os.symlink(real, link)

            # When the verifier reads it.
            # Then it is refused.
            with self.assertRaises(ValueError):
                contracts.read_contracts(link)


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
unittest.defaultTestLoader.loadTestsFromTestCase(VerdictContract).run(result)
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
[[ "$results" == *PASS* ]] || fail "contract verdict cases ran" "no case reported a result"
((rc == 0)) || fail "contract verdict suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

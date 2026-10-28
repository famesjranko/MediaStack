#!/usr/bin/env bash
# Hosted preflight wiring of the contract-coverage gate: selection, acceptance
# and both reports read each traced job's contracts.json, and the event export
# keeps no exec command line. Synthetic artifacts; no Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-contracts
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
sys.path.insert(0, sys.path[0] + "/fixtures")
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight.model import (FIXTURES, ROOT, build_plan, drift, effective, fingerprint, rows,
                             source_sha)
from preflight.runner import canonical, lifecycle_events
from preflight.status import render
from preflight.verify import accept, phase_two_contract_failures, select_combination

SOURCE = source_sha()
RUN = "123-1"
MAIN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}
NOTHING = {"outcome": "", "pr": "", "reason": ""}


class ContractGate(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = pathlib.Path(temp.name)
        self.results = self.folder / "results"
        self.old = rows(ROOT / "docs/operations/image-digests.lock")
        self.current = dict(self.old)
        for service, digit in (("sonarr", "1"), ("radarr", "4"), ("socket-proxy", "5")):
            prior = self.old[service]
            self.current[service] = drift.ImageDigest(service, prior.image, "sha256:" + digit * 64)
        self.fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.snapshot = self.folder / "current.tsv"
        drift.write_tsv(self.snapshot, list(self.current.values()))

    def phase1(self, selected):
        return build_plan(self.old, self.current, selected, SOURCE, RUN, self.fixtures)

    def write(self, plan, job, contracts):
        """Passing job artifacts; ``contracts`` None writes no contracts.json."""
        folder = self.results / ("result-" + job["id"])
        folder.mkdir(parents=True, exist_ok=True)
        refs = effective(plan, job)
        result = {"schema": 1, "plan": fingerprint(plan), "source": SOURCE,
                  "run": RUN, "job": job["id"], "scenario": job["scenario"],
                  "run_id": job["run_id"], "architecture": "x86_64", "rc": 0, "passes": 240,
                  "failures": 0, "skips": 0, "evidence_error": None, "elapsed_seconds": 600,
                  "disk_error": None, "runner_error": None, "disk_samples": 300,
                  "disk_free_start_bytes": 30_000_000_000,
                  "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000}
        data = {"result": result,
                "events": [{"action": "start", "id": s, "service": s, "image": refs[s]}
                           for s in job["combination"]],
                "images": [{"id": s, "digests": [refs[s]], "arch": "amd64", "os": "linux"}
                           for s in job["combination"]]}
        for name, value in data.items():
            (folder / (name + ".json")).write_text(json.dumps(value))
        receipts = ["\t".join([s, *refs[s].rsplit("@", 1), job["scenario"], SOURCE,
                               job["run_id"], "x86_64", "2026-01-01T00:00:00Z"])
                    for s in job["services"]]
        (folder / "receipts.tsv").write_text("\n".join(receipts) + "\n")
        if contracts is not None:
            (folder / "contracts.json").write_text(json.dumps(contracts))

    def pass_jobs(self, plan, change=None):
        """Every job passes with covering evidence; ``change`` edits it per job id."""
        for job in plan["jobs"]:
            data = covering(plan, job) if job["scenario"] in TRACED_SCENARIOS else None
            if change and job["id"] in change:
                data = change[job["id"]](data)
            self.write(plan, job, data)

    def test_missing_contracts_fails_the_candidate(self):
        # Given Sonarr's install-e2e job passed but uploaded no contracts.json.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan, {"p1-sonarr.install-e2e": lambda data: None})

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then Sonarr fails as an image failure, not as undecided.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertIn("sonarr", selection["failed"])
        self.assertNotIn("sonarr", selection["runner_failed"])
        # And the contract report names the job without evidence.
        self.assertEqual(selection["contracts"]["failed"]["sonarr"],
                         ["p1-sonarr.install-e2e: contracts.json is missing or unreadable"])

    def test_phase_one_contract_failure_excludes_the_candidate(self):
        # Given no Sonarr job saw the quality profile items on the candidate.
        plan = self.phase1(["radarr", "sonarr"])

        def without_items(data):
            reads = data["entries"]["sonarr"]["quality-profile-list"]["reads"]
            reads.remove("items[].quality.id")
            return data

        self.pass_jobs(plan, {job["id"]: without_items for job in plan["jobs"]
                              if job["combination"] == ["sonarr"]
                              and job["scenario"] in TRACED_SCENARIOS})

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then only Radarr continues, and Sonarr failed every scenario it was judged on.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertEqual(selection["failed"]["sonarr"],
                         ["fresh-install", "install-e2e", "upgrade-path"])
        # And the status report names the exact entry and read.
        text = render(plan, selection, {"combine": "success", "verify": "success",
                                        "publish": "skipped"}, NOTHING, MAIN)
        self.assertIn("`sonarr quality-profile-list: missing reads items[].quality.id`", text)

    def test_an_entry_covered_only_by_the_union_of_jobs_passes(self):
        # Given Sonarr's notification test ran only in upgrade-path, and the
        # profile items were read only in install-e2e.
        plan = self.phase1(["sonarr"])

        def drop(entry=None, read=None):
            def change(data):
                item = data["entries"]["sonarr"]["quality-profile-list"]
                if read:
                    item["reads"].remove(read)
                if entry:
                    del data["entries"]["sonarr"][entry]
                return data
            return change

        self.pass_jobs(plan, {
            "p1-sonarr.fresh-install": drop("notification-test", "items[].quality.id"),
            "p1-sonarr.install-e2e": drop("notification-test"),
            "p1-sonarr.upgrade-path": drop(read="items[].quality.id"),
        })

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then Sonarr passes, because coverage is the union over its jobs.
        self.assertEqual(selection["selected"], ["sonarr"])
        self.assertEqual(selection["contracts"]["failed"], {})

    def test_phase_two_contract_failure_blocks_acceptance(self):
        # Given both candidates passed phase 1 alone.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        self.assertEqual(selection["authority"], "phase-2")
        # And together, Radarr's root folder list returned 404 in every phase-2 job.

        def not_found(data):
            if "radarr" in data["entries"]:
                data["entries"]["radarr"]["root-folder-list"]["candidate"] = {"404": 1}
            return data

        self.pass_jobs(selection, {job["id"]: not_found for job in selection["jobs"]})
        output = self.folder / "accepted"

        # When final verification judges the combination.
        # Then it refuses and names the entry and what was seen.
        with self.assertRaisesRegex(ValueError, "radarr root-folder-list: not exercised on "
                                    "candidate \\(seen 404×1 in fresh-install"):
            accept(plan, selection, self.snapshot, self.results, output)
        # And it writes no lock.
        self.assertFalse(output.exists())
        # And the status report names the failed entry for the refused combination.
        jobs = {"combine": "success", "verify": "failure", "publish": "skipped"}
        failures = phase_two_contract_failures(selection, self.results)
        text = render(plan, selection, jobs, NOTHING, MAIN, contract=failures)
        self.assertIn("| radarr | failed final verification (", text)
        self.assertIn("`radarr root-folder-list: not exercised on candidate", text)

    def test_a_service_without_entries_is_reported(self):
        # Given socket-proxy, which has no contract entries, passed every job alone.
        plan = self.phase1(["socket-proxy"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        output = self.folder / "accepted"

        # When the verifier accepts it.
        accept(plan, selection, self.snapshot, self.results, output)

        # Then the digest PR body says its acceptance rests on its scenarios.
        body = (output / "body.md").read_text()
        self.assertIn("- No contract entries: socket-proxy: no contract entries; acceptance "
                      "rests on its scenarios", body)
        # And the status report lists it too.
        text = render(plan, selection, {"combine": "skipped", "verify": "success",
                                        "publish": "skipped"}, NOTHING, MAIN)
        self.assertIn("socket-proxy: no contract entries", text)

    def test_traced_scenarios_are_the_scenarios_that_trace(self):
        # Given the scenario files that pass MS_CONTRACT_TRACE to product code.
        tracing = {path.stem for path in (ROOT / "tests/scenarios").glob("*.sh")
                   if "MS_CONTRACT_TRACE=" in path.read_text()}

        # When the verifier decides which jobs must carry contract evidence.
        # Then it expects evidence from exactly those scenarios.
        self.assertEqual(tracing, set(TRACED_SCENARIOS))

    def test_event_export_keeps_no_exec_argv(self):
        # Given docker events for an exec whose command line carries a password.
        secret = "hub-password-0123456789"
        actor = {"ID": "c1", "Attributes": {"com.docker.compose.service": "beszel",
                                            "image": "henrygd/beszel:latest", "execID": "e1"}}
        raw = "\n".join(json.dumps({"Type": "container", "Action": action, "Actor": actor})
                        for action in ("start", f"exec_create: /beszel superuser upsert a@b {secret}",
                                       f"exec_start: /beszel superuser upsert a@b {secret}",
                                       "health_status: healthy"))

        # When the runner reduces them for events.json.
        events = lifecycle_events(raw)

        # Then only the bare lifecycle actions remain.
        self.assertEqual([event["action"] for event in events],
                         ["start", "exec_create", "exec_start", "health_status"])
        # And the password appears nowhere in the artifact bytes.
        self.assertNotIn(secret.encode(), canonical(events))


unittest.main()
PY
    pass 'hosted preflight judges contract evidence and exports no exec argv'
else
    fail 'hosted preflight judges contract evidence and exports no exec argv'
fi
summary

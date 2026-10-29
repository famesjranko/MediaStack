#!/usr/bin/env bash
# Bazarr needs both its fresh subtitle scenario and accepted-to-candidate evidence.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin bazarr-preflight
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import pathlib
import sys
import tempfile
import unittest

root = pathlib.Path(sys.argv.pop())
sys.path.insert(0, str(root / "tests"))
sys.path.insert(0, str(root / "tests/fixtures"))
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight.model import FIXTURES, build_plan, drift, effective, fingerprint, rows, source_sha
from preflight.verify import accept, select_combination


class BazarrAcceptance(unittest.TestCase):
    def setUp(self):
        # Given a changed Bazarr digest and frozen accepted companions.
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.work = pathlib.Path(self.folder.name)
        self.results = self.work / "results"
        self.old = rows(root / "docs/operations/image-digests.lock")
        self.current = dict(self.old)
        prior = self.old["bazarr"]
        self.current["bazarr"] = drift.ImageDigest("bazarr", prior.image, "sha256:" + "5" * 64)
        self.source = source_sha()
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.plan = build_plan(self.old, self.current, ["bazarr"], self.source, "123-1", fixtures)

    def evidence(self):
        for job in self.plan["jobs"]:
            folder = self.results / ("result-" + job["id"])
            folder.mkdir(parents=True)
            ref = effective(self.plan, job)["bazarr"]
            result = {
                "schema": 1, "plan": fingerprint(self.plan), "source": self.source,
                "run": "123-1", "job": job["id"], "scenario": job["scenario"],
                "run_id": job["run_id"], "architecture": "x86_64", "rc": 0,
                "passes": 20, "failures": 0, "skips": 0, "evidence_error": None,
                "elapsed_seconds": 600, "disk_error": None, "runner_error": None,
                "disk_samples": 300, "disk_free_start_bytes": 30_000_000_000,
                "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000,
            }
            events = [{"action": "start", "id": "bazarr", "service": "bazarr", "image": ref}]
            images = [{"id": "bazarr", "digests": [ref], "arch": "amd64", "os": "linux"}]
            for name, value in (("result", result), ("events", events), ("images", images)):
                (folder / (name + ".json")).write_text(json.dumps(value))
            receipt = ["bazarr", *ref.rsplit("@", 1), job["scenario"], self.source,
                       job["run_id"], "x86_64", "2026-01-01T00:00:00Z"]
            (folder / "receipts.tsv").write_text("\t".join(receipt) + "\n")
            if job["scenario"] in TRACED_SCENARIOS:
                (folder / "contracts.json").write_text(json.dumps(covering(self.plan, job)))

    def test_bazarr_requires_fresh_and_migration_evidence(self):
        # Given a hosted plan for the changed Bazarr digest.
        # When its scheduled jobs are inspected.
        jobs = self.plan["jobs"]

        # Then neither the fresh subtitle check nor the traced upgrade can be omitted.
        self.assertEqual({job["scenario"] for job in jobs}, {"bazarr", "upgrade-path"})
        self.assertIn("upgrade-path", TRACED_SCENARIOS)
        self.assertTrue(all(job["services"] == ["bazarr"] for job in jobs))

    def test_complete_evidence_can_selectively_accept_bazarr(self):
        # Given both successful scenarios and complete contract evidence.
        self.evidence()
        selection = select_combination(self.plan, self.results)
        snapshot = self.work / "candidate.tsv"
        drift.write_tsv(snapshot, list(self.current.values()))

        # When the controlled verifier accepts the selected combination.
        accept(self.plan, selection, snapshot, self.results, self.work / "accepted")

        # Then only the proposed Bazarr digest changes.
        accepted = rows(self.work / "accepted/image-digests.lock")
        self.assertEqual(accepted["bazarr"].digest, self.current["bazarr"].digest)
        for service in self.old.keys() - {"bazarr"}:
            self.assertEqual(accepted[service], self.old[service])

    def test_missing_migration_receipt_blocks_selection(self):
        # Given evidence that first qualifies for Bazarr selection.
        self.evidence()
        self.assertEqual(select_combination(self.plan, self.results)["selected"], ["bazarr"])
        receipt = self.results / "result-p1-bazarr.upgrade-path/receipts.tsv"

        # When only the migration receipt is removed.
        receipt.write_text("")
        selection = select_combination(self.plan, self.results)

        # Then a successful fresh installation cannot authorize the upgrade.
        self.assertEqual(selection["selected"], [])
        self.assertIn("bazarr", selection["failed"])


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(BazarrAcceptance))
sys.exit(not result.wasSuccessful())
PY
    pass 'Bazarr acceptance requires fresh, migration and contract evidence'
else
    fail 'Bazarr acceptance requires fresh, migration and contract evidence'
fi
scenario_end "$CURRENT_SCENARIO"
summary

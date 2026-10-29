#!/usr/bin/env bash
# A migrated service qualifies only with both fresh and existing-install evidence.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-migrations
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
from preflight.model import FIXTURES, ROOT, build_plan, drift, fingerprint, rows, source_sha
from preflight.verify import select_combination

SOURCE = source_sha()
RUN = "123-1"


class Migrations(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.results = pathlib.Path(temporary.name)
        old = rows(ROOT / "docs/operations/image-digests.lock")
        current = dict(old)
        current["portainer"] = drift.ImageDigest("portainer", old["portainer"].image, "sha256:" + "a" * 64)
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.plan = build_plan(old, current, ["portainer"], SOURCE, RUN, fixtures)

    def write_evidence(self, job):
        folder = self.results / ("result-" + job["id"])
        folder.mkdir()
        ref = self.plan["candidates"]["portainer"]
        data = {
            "result": {"schema": 1, "plan": fingerprint(self.plan), "source": SOURCE, "run": RUN,
                       "job": job["id"], "scenario": job["scenario"], "run_id": job["run_id"],
                       "architecture": "x86_64", "rc": 0, "passes": 7, "failures": 0, "skips": 0,
                       "evidence_error": None, "elapsed_seconds": 30, "disk_error": None,
                       "runner_error": None, "disk_samples": 3, "disk_free_start_bytes": 30_000_000_000,
                       "disk_peak_growth_bytes": 1_000_000_000, "disk_growth_bytes": 1_000_000_000},
            "events": [{"action": "start", "id": "portainer", "service": "portainer", "image": ref}],
            "images": [{"id": "portainer", "digests": [ref], "arch": "amd64", "os": "linux"}],
            "contracts": covering(self.plan, job),
        }
        for name, value in data.items():
            (folder / (name + ".json")).write_text(json.dumps(value))
        receipt = ["portainer", *ref.rsplit("@", 1), job["scenario"], SOURCE,
                   job["run_id"], "x86_64", "2026-01-01T00:00:00Z"]
        (folder / "receipts.tsv").write_text("\t".join(receipt) + "\n")
        return folder

    def test_portainer_requires_migration_evidence(self):
        # Given a changed Portainer digest whose database migration now has a fixture.
        plan = self.plan

        # When hosted acceptance plans that candidate.
        scenarios = {job["scenario"] for job in plan["jobs"]}

        # Then migration is required beside fresh setup and the real installer.
        self.assertEqual(plan["selected"], ["portainer"])
        self.assertEqual(scenarios, {"fresh-install", "install-e2e", "portainer-upgrade"})
        self.assertIn("portainer-upgrade", TRACED_SCENARIOS)

    def test_portainer_without_migration_receipt_cannot_qualify(self):
        # Given complete evidence selects Portainer before its migration receipt is removed.
        for job in self.plan["jobs"]:
            self.write_evidence(job)
        self.assertEqual(select_combination(self.plan, self.results)["selected"], ["portainer"])
        receipt = self.results / "result-p1-portainer.portainer-upgrade/receipts.tsv"
        receipt.unlink()

        # When the verifier selects candidates with that one missing receipt.
        selection = select_combination(self.plan, self.results)

        # Then the missing migration evidence blocks Portainer.
        self.assertEqual(selection["selected"], [])
        self.assertIn("portainer", selection["failed"])


unittest.main(argv=["hosted-preflight-migrations"], verbosity=2)
PY
    pass 'Portainer acceptance requires complete migration evidence'
else
    fail 'Portainer acceptance requires complete migration evidence'
fi
summary

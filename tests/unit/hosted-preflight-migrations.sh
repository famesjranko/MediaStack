#!/usr/bin/env bash
# A migrated service qualifies only with both fresh and existing-install evidence.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-migrations
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
sys.path.insert(0, sys.path[0] + "/fixtures")
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight.model import FIXTURES, ROOT, build_plan, drift, fingerprint, rows, source_sha
from preflight.verify import select_combination
from inventory import read_present

SOURCE = source_sha()
RUN = "123-1"


class Migrations(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.results = pathlib.Path(temporary.name)
        self.plan = self.plan_for("portainer")

    def plan_for(self, service):
        old = rows(ROOT / "docs/operations/image-digests.lock")
        current = dict(old)
        current[service] = drift.ImageDigest(service, old[service].image, "sha256:" + "a" * 64)
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        return build_plan(old, current, [service], SOURCE, RUN, fixtures)

    def write_evidence(self, job, rc=0):
        folder = self.results / ("result-" + job["id"])
        folder.mkdir(exist_ok=True)
        service = job["services"][0]
        ref = self.plan["candidates"][service]
        data = {
            "result": {"schema": 1, "plan": fingerprint(self.plan), "source": SOURCE, "run": RUN,
                       "job": job["id"], "scenario": job["scenario"], "run_id": job["run_id"],
                       "architecture": "x86_64", "rc": rc, "passes": 7, "failures": 0, "skips": 0,
                       "evidence_error": None, "elapsed_seconds": 30, "disk_error": None,
                       "runner_error": None, "disk_samples": 3, "disk_free_start_bytes": 30_000_000_000,
                       "disk_peak_growth_bytes": 1_000_000_000, "disk_growth_bytes": 1_000_000_000},
            "events": [{"action": "start", "id": service, "service": service, "image": ref}],
            "images": [{"id": service, "digests": [ref], "arch": "amd64", "os": "linux"}],
            "contracts": covering(self.plan, job),
        }
        for name, value in data.items():
            (folder / (name + ".json")).write_text(json.dumps(value))
        receipt = [service, *ref.rsplit("@", 1), job["scenario"], SOURCE,
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

    def test_wireguard_requires_fresh_and_existing_client_evidence(self):
        # Given complete evidence from both WireGuard image scenarios.
        self.plan = self.plan_for("wireguard")
        jobs = {job["scenario"]: job for job in self.plan["jobs"]}
        for job in jobs.values():
            self.write_evidence(job)

        # When the verifier selects candidates for phase two.
        selection = select_combination(self.plan, self.results)

        # Then fresh setup and existing-client proof both qualify WireGuard.
        self.assertEqual(set(jobs), {"wireguard", "wireguard-upgrade"})
        self.assertTrue(set(jobs) <= TRACED_SCENARIOS)
        self.assertEqual(selection["selected"], ["wireguard"])

    def test_npm_requires_local_migration_and_renewal_evidence(self):
        # Given a drifted NPM digest with complete local fixture evidence.
        self.plan = self.plan_for("npm")
        jobs = {job["scenario"]: job for job in self.plan["jobs"]}
        for job in jobs.values():
            self.write_evidence(job)

        # When the verifier selects candidates for phase two.
        selection = select_combination(self.plan, self.results)

        # Then local migration and renewal qualify NPM without a WAN receipt.
        self.assertEqual(set(jobs), {"fresh-install", "npm-upgrade", "npm-renewal"})
        self.assertIn("npm-upgrade", TRACED_SCENARIOS)
        self.assertEqual(selection["selected"], ["npm"])

    def test_npm_missing_or_failed_migration_or_renewal_cannot_qualify(self):
        for missing in ("npm-upgrade", "npm-renewal"):
            for rc in (None, 1):
                with self.subTest(missing=missing, rc=rc):
                    # Given fresh setup but a missing or failed migration or renewal proof.
                    self.plan = self.plan_for("npm")
                    jobs = {job["scenario"]: job for job in self.plan["jobs"]}
                    for name, job in jobs.items():
                        if name != missing:
                            self.write_evidence(job)
                    missing_folder = self.results / ("result-" + jobs[missing]["id"])
                    if missing_folder.exists():
                        shutil.rmtree(missing_folder)
                    if rc is not None:
                        self.write_evidence(jobs[missing], rc=rc)

                    # When the verifier selects candidates for phase two.
                    selection = select_combination(self.plan, self.results)

                    # Then neither missing nor failed evidence can qualify NPM.
                    self.assertEqual(selection["selected"], [])
                    self.assertEqual(selection["failed"], {"npm": [missing]})

    def test_npm_certificate_contract_accepts_the_public_api_shape(self):
        # Given NPM's serialized certificate response without its hidden deletion flag.
        self.plan = self.plan_for("npm")
        payload = [{"id": 7, "domain_names": ["jellyfin.fixture.test"], "provider": "letsencrypt"}]
        for job in self.plan["jobs"]:
            folder = self.write_evidence(job)
            path = folder / "contracts.json"
            evidence = json.loads(path.read_text())
            entry = evidence["entries"]["npm"]["certificate-list"]
            entry["reads"] = [field for field in entry["reads"] if read_present(payload, field)]
            path.write_text(json.dumps(evidence))

        # When the hosted gate checks that response beside complete other evidence.
        selection = select_combination(self.plan, self.results)

        # Then the public API's omission does not disqualify a working candidate.
        self.assertEqual(selection["selected"], ["npm"])

    def test_wireguard_without_existing_client_proof_cannot_qualify(self):
        for rc in (None, 1):
            with self.subTest(rc=rc):
                # Given passing fresh setup and a missing or failed existing-client proof.
                self.plan = self.plan_for("wireguard")
                jobs = {job["scenario"]: job for job in self.plan["jobs"]}
                self.write_evidence(jobs["wireguard"])
                if rc is not None:
                    self.write_evidence(jobs["wireguard-upgrade"], rc=rc)

                # When the verifier selects candidates for phase two.
                selection = select_combination(self.plan, self.results)

                # Then neither result can qualify WireGuard for phase two.
                self.assertEqual(selection["selected"], [])
                self.assertEqual(selection["failed"], {"wireguard": ["wireguard-upgrade"]})


unittest.main(argv=["hosted-preflight-migrations"], verbosity=2)
PY
    pass 'NPM, Portainer and WireGuard acceptance require complete migration evidence'
else
    fail 'NPM, Portainer and WireGuard acceptance require complete migration evidence'
fi
summary

#!/usr/bin/env bash
# Hosted acceptance consumes data from image jobs; no Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
from preflight.model import FIXTURES, ROOT, build_plan, drift, fingerprint, rows, source_sha
from preflight.verify import accept, check_companions, check_result
from preflight.runner import sanitize
import yaml


class HostedEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = pathlib.Path(self.temp.name)
        self.old = rows(ROOT / "docs/operations/image-digests.lock")
        self.current = dict(self.old)
        prior = self.old["sonarr"]
        self.digest = "sha256:" + "1" * 64
        self.current["sonarr"] = drift.ImageDigest("sonarr", prior.image, self.digest)
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.plan = build_plan(self.old, self.current, ["sonarr"], source_sha(), "123-1", fixtures)
        self.job = next(j for j in self.plan["jobs"] if j["scenario"] == "fresh-install")
        self.result = {"schema": 1, "plan": fingerprint(self.plan), "source": source_sha(),
                       "run": "123-1", "scenario": "fresh-install", "run_id": self.job["run_id"],
                       "architecture": "x86_64", "rc": 0, "passes": 240, "failures": 0,
                       "skips": 0, "evidence_error": None, "elapsed_seconds": 600,
                       "disk_growth_bytes": 2_000_000_000}
        self.events = [{"action": "start", "id": "container-id", "service": "sonarr",
                        "image": self.plan["effective"]["sonarr"]}]
        self.images = [{"id": "image-id", "digests": [prior.image + "@" + self.digest],
                        "arch": "amd64", "os": "linux"}]
        receipt = "\t".join(["sonarr", prior.image, self.digest, "fresh-install", source_sha(),
                              self.job["run_id"], "x86_64", "2026-01-01T00:00:00Z"])
        (self.folder / "receipts.tsv").write_text(receipt + "\n")

    def write_result(self):
        for name, data in (("result", self.result), ("events", self.events), ("images", self.images)):
            (self.folder / (name + ".json")).write_text(json.dumps(data))

    def test_valid_evidence_qualifies(self):
        # Given complete evidence from the intended source, run and combination.
        self.write_result()

        # When the controlled publisher validates the job.
        path = check_result(self.plan, self.job, self.folder)

        # Then the exact receipt artifact qualifies for acceptance.
        self.assertEqual(path, self.folder / "receipts.tsv")

    def test_invalid_status_or_identity_blocks(self):
        for field, value in (("rc", 1), ("failures", 1), ("skips", 1), ("passes", 0),
                             ("source", "0" * 40), ("run", "old-run"), ("plan", "old-plan"),
                             ("architecture", "aarch64")):
            with self.subTest(field=field):
                # Given an otherwise valid artifact with one broken contract.
                original = copy.deepcopy(self.result)
                self.result[field] = value
                self.write_result()

                # When the publisher validates the result.
                # Then no failed, skipped, empty, stale or mismatched job qualifies.
                with self.assertRaises(ValueError):
                    check_result(self.plan, self.job, self.folder)
                self.result = original

    def test_wrong_companion_blocks(self):
        # Given a passing job whose companion ran another digest.
        self.events.append({"action": "start", "id": "companion", "service": "radarr",
                            "image": "example/wrong@sha256:" + "3" * 64})

        # When the companion combination is checked.
        # Then the passing candidate cannot authorize a different installation.
        with self.assertRaisesRegex(ValueError, "runtime companion"):
            check_companions(self.plan, self.events, self.images)

    def test_wrong_fixture_blocks(self):
        # Given the fixture used a floating image instead of its frozen digest.
        self.events.append({"action": "start", "id": "fixture", "service": None,
                            "image": "python:3.12-alpine"})

        # When fixture provenance is checked.
        # Then the result is refused even though service evidence matches.
        with self.assertRaisesRegex(ValueError, "fixture image"):
            check_companions(self.plan, self.events, self.images)

    def test_wrong_scenario_receipt_blocks(self):
        # Given a receipt from a scenario that did not test the required behavior.
        path = self.folder / "receipts.tsv"
        path.write_text(path.read_text().replace("fresh-install", "smoke"))
        self.write_result()

        # When the job's required receipt is checked.
        # Then the receipt cannot stand in for fresh-install.
        with self.assertRaisesRegex(ValueError, "not fresh-install"):
            check_result(self.plan, self.job, self.folder)

    def test_manual_gap_is_held(self):
        # Given a FlareSolverr candidate with no challenge-solve oracle.
        prior = self.old["flaresolverr"]
        self.current["flaresolverr"] = drift.ImageDigest("flaresolverr", prior.image, self.digest)

        # When routine automatic acceptance selects that image explicitly.
        # Then health-only evidence cannot authorize it.
        with self.assertRaisesRegex(ValueError, "complete automated coverage"):
            build_plan(self.old, self.current, ["flaresolverr"], source_sha(), "123-1", {})

    def test_required_upgrade_is_planned(self):
        # Given a changed Sonarr image and an unchanged companion baseline.
        # When its frozen plan is inspected.
        scenarios = {j["scenario"] for j in self.plan["jobs"]}

        # Then both fresh and existing-install evidence are required.
        self.assertEqual(scenarios, {"fresh-install", "upgrade-path"})
        ref = self.old["radarr"]
        self.assertEqual(self.plan["effective"]["radarr"], ref.image + "@" + ref.digest)

    def test_image_execution_has_no_publishing_permissions(self):
        # Given the workflow that executes privileged candidate containers.
        workflow = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())
        image_job = workflow["jobs"]["preflight-images"]

        # When its execution and publication permissions are inspected.
        permissions = image_job["permissions"]
        publisher = workflow["jobs"]["preflight-publish"]

        # Then only the separate default-branch publisher can write.
        self.assertEqual(permissions, {"contents": "read"})
        self.assertEqual(image_job["runs-on"], "ubuntu-24.04")
        self.assertNotIn("secrets.", json.dumps(image_job))
        self.assertIn("github.event.repository.default_branch", publisher["if"])

    def test_log_export_masks_fixture_credentials(self):
        # Given log text containing a fixture password and generated API key.
        password = 'Fr3sh!$tack"with\\special#chars^&*'
        key = "fixture-" + "a" * 32

        # When logs are prepared for artifact upload.
        text = sanitize(password + ' {"apiKey": "' + key + '"}')

        # Then neither complete credential reaches the artifact.
        self.assertNotIn(password, text)
        self.assertNotIn(key, text)

    def test_complete_combination_precedes_selective_write(self):
        # Given fresh evidence is present but the required upgrade result is missing.
        self.write_result()
        results = self.folder / "results"
        results.mkdir()
        first = results / "result-fresh-install"
        first.mkdir()
        for path in self.folder.glob("*.json"):
            shutil.copy2(path, first / path.name)
        shutil.copy2(self.folder / "receipts.tsv", first / "receipts.tsv")
        snapshot = self.folder / "current.tsv"
        drift.write_tsv(snapshot, list(self.current.values()))
        output = self.folder / "accepted"

        # When the publisher attempts acceptance without the migration artifact.
        # Then it writes no accepted directory or lock.
        with self.assertRaises(FileNotFoundError):
            accept(self.plan, snapshot, results, output)
        self.assertFalse(output.exists())

        # Given the same combination also has complete upgrade evidence.
        second = results / "result-upgrade-path"
        shutil.copytree(first, second)
        job = next(j for j in self.plan["jobs"] if j["scenario"] == "upgrade-path")
        result = dict(self.result, scenario="upgrade-path", run_id=job["run_id"])
        (second / "result.json").write_text(json.dumps(result))
        receipt = (second / "receipts.tsv").read_text()
        (second / "receipts.tsv").write_text(receipt.replace("fresh-install", "upgrade-path").replace(self.job["run_id"], job["run_id"]))

        # When the publisher accepts the complete evidence set.
        accept(self.plan, snapshot, results, output)

        # Then it changes only the selected digest and preserves unrelated rows.
        accepted = rows(output / "image-digests.lock")
        self.assertEqual(accepted["sonarr"].digest, self.digest)
        for service in self.old.keys() - {"sonarr"}:
            self.assertEqual(accepted[service], self.old[service])


unittest.main()
PY
    pass 'hosted preflight accepts complete evidence and rejects unsafe artifacts'
else
    fail 'hosted preflight accepts complete evidence and rejects unsafe artifacts'
fi
summary

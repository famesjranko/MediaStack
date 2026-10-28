#!/usr/bin/env bash
# Hosted preflight runner disk: cleanup, peak sampling and the headroom rule.
# A full runner disk must never read as an image failure. No Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-disk
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
from preflight import publish
from preflight.model import (FIXTURES, HEADROOM_BYTES, ROOT, build_plan, combination_plan, drift,
                             effective, fingerprint, headroom_error, rows, source_sha)
from preflight.runner import DiskSampler
from preflight.status import render
from preflight.verify import RunnerDiskError, check_result, job_failures, select_combination
import yaml

SOURCE = source_sha()
RUN = "123-1"
MAIN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}
NOTHING = {"outcome": "", "pr": "", "reason": ""}


class RunnerDisk(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.results = pathlib.Path(temp.name)
        old = rows(ROOT / "docs/operations/image-digests.lock")
        current = dict(old)
        for service, digit in (("sonarr", "1"), ("radarr", "4")):
            current[service] = drift.ImageDigest(service, old[service].image, "sha256:" + digit * 64)
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.plan = build_plan(old, current, ["radarr", "sonarr"], SOURCE, RUN, fixtures)

    def job(self, plan, job_id):
        return next(j for j in plan["jobs"] if j["id"] == job_id)

    def passing(self, plan, job):
        return {"schema": 1, "plan": fingerprint(plan), "source": SOURCE, "run": RUN,
                "job": job["id"], "scenario": job["scenario"], "run_id": job["run_id"],
                "architecture": "x86_64", "rc": 0, "passes": 240, "failures": 0, "skips": 0,
                "evidence_error": None, "elapsed_seconds": 300, "disk_error": None,
                "runner_error": None, "disk_samples": 150, "disk_free_start_bytes": 30_000_000_000,
                "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000}

    def full_disk(self, plan, job):
        # The disk filled up, so the scenario failed too.
        result = dict(self.passing(plan, job), rc=1, failures=3,
                      disk_free_start_bytes=14_000_000_000, disk_peak_growth_bytes=13_500_000_000)
        return dict(result, runner_error=headroom_error(result))

    def write(self, plan, job, result=None):
        folder = self.results / ("result-" + job["id"])
        folder.mkdir(parents=True, exist_ok=True)
        refs = effective(plan, job)
        data = {"result": result or self.passing(plan, job),
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
        return folder

    def test_unmeasured_result_is_rejected(self):
        job = self.job(self.plan, "p1-sonarr.fresh-install")
        sampler = DiskSampler(lambda: str(self.results / "absent"))
        unsampled = dict(self.passing(self.plan, job), **sampler.finish())
        absent = {k: v for k, v in self.passing(self.plan, job).items()
                  if k not in ("disk_free_start_bytes", "disk_peak_growth_bytes")}
        for name, result in (("sampler could not start", unsampled), ("peak fields absent", absent)):
            with self.subTest(name):
                # Given a passing result without a peak disk measurement.
                folder = self.write(self.plan, job, result)

                # When the verifier checks the result.
                with self.assertRaises(ValueError) as caught:
                    check_result(self.plan, job, folder)

                # Then it refuses the result as unmeasured.
                self.assertRegex(str(caught.exception), "unmeasured|resource measurements")
                # And it does not blame the runner disk for a missing measurement.
                self.assertNotIsInstance(caught.exception, RunnerDiskError)
        # And the failed sampler says why it has no numbers.
        self.assertIn("could not start", unsampled["disk_error"])
        self.assertIsNone(unsampled["disk_peak_growth_bytes"])

    def test_full_disk_in_phase_one_is_a_runner_problem(self):
        # Given Sonarr's fresh-install job ran out of disk and every other job passed.
        for job in self.plan["jobs"]:
            full = job["id"] == "p1-sonarr.fresh-install"
            self.write(self.plan, job, self.full_disk(self.plan, job) if full else None)

        # When the selection reads phase 1 and the status report is rendered.
        selection = select_combination(self.plan, self.results)
        jobs = {"combine": "skipped", "verify": "success", "publish": "skipped"}
        text = render(self.plan, selection, jobs, NOTHING, MAIN)

        # Then Sonarr is undecided because of the runner, and not failed.
        self.assertEqual((selection["failed"], selection["runner_failed"]),
                         ({}, {"sonarr": ["fresh-install"]}))
        self.assertIn("| sonarr | undecided: runner disk headroom exhausted in phase 1; "
                      "this is not an image result (", text)
        # And the full-disk result authorizes nothing and refuses no open PR.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertEqual(publish.rejected(self.plan, selection, "success"), {})
        # And the runner's own error names the free bytes against the minimum.
        result = self.full_disk(self.plan, self.job(self.plan, "p1-sonarr.fresh-install"))
        self.assertIn(f"500000000 bytes free at peak, below the {HEADROOM_BYTES}-byte minimum",
                      result["runner_error"])

    def test_full_disk_in_phase_two_is_a_runner_problem(self):
        # Given both candidates passed phase 1 and phase-2 upgrade-path ran out of disk.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})
        for job in selection["jobs"]:
            full = job["id"] == "p2-upgrade-path"
            self.write(selection, job, self.full_disk(selection, job) if full else None)

        # When the status job classifies the failed phase 2 and renders the report.
        failed, runner = job_failures(selection, self.results)
        jobs = {"combine": "failure", "verify": "skipped", "publish": "skipped"}
        text = render(self.plan, selection, jobs, NOTHING, MAIN, frozenset(runner.keys() - failed.keys()))

        # Then no candidate reads as an image failure in phase 2.
        self.assertEqual(failed, {})
        self.assertNotIn("failed in phase 2", text)
        self.assertIn("| sonarr | undecided: runner disk headroom exhausted in phase 2;", text)

    def test_image_jobs_free_disk_before_dind_with_read_only_permissions(self):
        # Given the workflow that runs candidate images.
        workflow = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())

        for name in ("preflight-isolate", "preflight-combine"):
            with self.subTest(name):
                # When the steps and permissions of one image job are inspected.
                job = workflow["jobs"][name]
                runs = [str(step.get("run", "")) for step in job["steps"]]
                cleanup = runs.index("bash tests/preflight/free-runner-disk.sh")
                scenario = next(i for i, run in enumerate(runs) if "hosted_preflight.py run" in run)

                # Then a plain run step frees disk before the scenario starts DinD.
                self.assertLess(cleanup, scenario)
                self.assertNotIn("uses", job["steps"][cleanup])
                # And the job can only read repository contents and receives no secrets.
                self.assertEqual(job["permissions"], {"contents": "read"})
                self.assertNotIn("secrets.", json.dumps(job))

    def test_cleanup_refuses_outside_a_github_runner(self):
        # Given a shell without the GitHub Actions marker.
        env = {"PATH": os.environ["PATH"]}

        # When the disk cleanup runs.
        proc = subprocess.run(["bash", str(ROOT / "tests/preflight/free-runner-disk.sh")],
                              env=env, capture_output=True, text=True, check=False)

        # Then it refuses before it deletes anything.
        self.assertEqual(proc.returncode, 2)
        self.assertIn("refused", proc.stderr)


unittest.main()
PY
    pass 'hosted preflight separates a full runner disk from an image failure'
else
    fail 'hosted preflight separates a full runner disk from an image failure'
fi
summary

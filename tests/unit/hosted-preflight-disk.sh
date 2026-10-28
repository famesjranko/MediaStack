#!/usr/bin/env bash
# Hosted preflight runner disk: cleanup, peak sampling and the headroom rule.
# Exhausted headroom never authorizes and never reads as an image failure. No Docker or network needed.
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
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
sys.path.insert(0, sys.path[0] + "/fixtures")
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight import publish
from preflight.model import (FIXTURES, HEADROOM_BYTES, ROOT, build_plan, combination_plan, drift,
                             effective, fingerprint, headroom_error, rows, source_sha)
from preflight import runner
from preflight.runner import DiskSampler
from preflight.status import render
from preflight.verify import RunnerDiskError, check_result, phase_two_undecided, select_combination
import yaml

SOURCE = source_sha()
RUN = "123-1"
MAIN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}
NOTHING = {"outcome": "", "pr": "", "reason": ""}
HEAD = "b" * 40
FULL_DISK = ("disk headroom exhausted (peak growth 13500000000 bytes, 500000000 bytes free at "
             f"peak, below the {HEADROOM_BYTES}-byte minimum); cause not determined")


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

    def image_failed(self, plan, job):
        return dict(self.passing(plan, job), rc=1, failures=2)

    def full_disk(self, plan, job):
        # The disk filled up, so the scenario failed too.
        result = dict(self.passing(plan, job), rc=1, failures=3,
                      disk_free_start_bytes=14_000_000_000, disk_peak_growth_bytes=13_500_000_000)
        return dict(result, runner_error=headroom_error(result))

    def write(self, plan, job, result=None, root=None):
        folder = (root or self.results) / ("result-" + job["id"])
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
        if job["scenario"] in TRACED_SCENARIOS:
            (folder / "contracts.json").write_text(json.dumps(covering(plan, job)))
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
                         ({}, {"sonarr": {"fresh-install": FULL_DISK}}))
        self.assertIn("| sonarr | undecided in phase 1: `result-p1-sonarr.fresh-install`: "
                      + FULL_DISK + " (", text)
        # And the full-disk result authorizes nothing and refuses no open PR.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertEqual(publish.rejected(self.plan, selection, "success"), [])

    def test_full_disk_in_phase_two_is_a_runner_problem(self):
        # Given both candidates passed phase 1 and phase-2 upgrade-path ran out of disk.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})
        for job in selection["jobs"]:
            full = job["id"] == "p2-upgrade-path"
            self.write(selection, job, self.full_disk(selection, job) if full else None)

        # When the status job classifies the failed phase 2 and renders the report.
        jobs = {"combine": "failure", "verify": "skipped", "publish": "skipped"}
        undecided = phase_two_undecided(selection, self.results)
        text = render(self.plan, selection, jobs, NOTHING, MAIN, undecided)

        # Then no candidate reads as an image failure in phase 2.
        self.assertNotIn("failed in phase 2", text)
        # And the report shows the peak growth of the job that ran out of disk.
        self.assertIn("| sonarr | undecided in phase 2: `result-p2-upgrade-path`: " + FULL_DISK,
                      text)

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
                # And a cleanup failure cannot skip the scenario.
                self.assertIs(job["steps"][cleanup].get("continue-on-error"), True)
                # And the job can only read repository contents and receives no secrets.
                self.assertEqual(job["permissions"], {"contents": "read"})
                self.assertNotIn("secrets.", json.dumps(job))

    def test_cleanup_refuses_outside_a_github_hosted_runner(self):
        # Given stand-ins for sudo and docker that record any call.
        stubs = self.results / "bin"
        stubs.mkdir()
        for tool in ("sudo", "docker"):
            (stubs / tool).write_text(f'#!/bin/sh\necho {tool} >>"{stubs}/calls"\n')
            (stubs / tool).chmod(0o755)
        path = {"PATH": f"{stubs}:{os.environ['PATH']}"}
        for name, env in (("no GitHub marker", path),
                          ("self-hosted runner", dict(path, GITHUB_ACTIONS="true",
                                                      RUNNER_ENVIRONMENT="self-hosted"))):
            with self.subTest(name):
                # When the disk cleanup runs.
                proc = subprocess.run(["bash", str(ROOT / "tests/preflight/free-runner-disk.sh")],
                                      env=env, capture_output=True, text=True, check=False)

                # Then it refuses before it deletes anything.
                self.assertEqual(proc.returncode, 2)
                self.assertIn("refused", proc.stderr)
                self.assertFalse((stubs / "calls").exists())

    def test_headroom_is_recomputed_from_the_numbers(self):
        # Given a result whose runner_error is null but whose peak left 500 MB free.
        job = self.job(self.plan, "p1-sonarr.fresh-install")
        full = dict(self.full_disk(self.plan, job), runner_error=None)
        folder = self.write(self.plan, job, full)

        # When the verifier checks the result.
        with self.assertRaises(RunnerDiskError) as caught:
            check_result(self.plan, job, folder)

        # Then it is undecided and shows the peak growth.
        self.assertIn("undecided: " + FULL_DISK, str(caught.exception))

    def test_inconsistent_disk_record_is_rejected(self):
        job = self.job(self.plan, "p1-sonarr.fresh-install")
        good = self.passing(self.plan, job)
        for name, result in (
            ("disk_error with numbers", dict(good, disk_error="disk sampler stopped")),
            ("runner_error absent", {k: v for k, v in good.items() if k != "runner_error"}),
            ("no disk sample", dict(good, disk_samples=0)),
            ("peak below end growth", dict(good, disk_peak_growth_bytes=11_000_000_000)),
        ):
            with self.subTest(name):
                # Given an otherwise passing result with an incomplete disk record.
                folder = self.write(self.plan, job, result)

                # When the verifier checks the result.
                with self.assertRaises(ValueError) as caught:
                    check_result(self.plan, job, folder)

                # Then it refuses the result, and does not call it undecided.
                self.assertNotIsInstance(caught.exception, RunnerDiskError)

    def test_image_failure_outranks_full_disk_in_phase_one(self):
        # Given Sonarr's fresh-install ran out of disk and its upgrade-path failed on the image.
        for job in self.plan["jobs"]:
            result = {"p1-sonarr.fresh-install": self.full_disk,
                      "p1-sonarr.upgrade-path": self.image_failed}.get(job["id"], self.passing)
            self.write(self.plan, job, result(self.plan, job))

        # When the selection reads phase 1 and the status report is rendered.
        selection = select_combination(self.plan, self.results)
        jobs = {"combine": "skipped", "verify": "success", "publish": "skipped"}
        text = render(self.plan, selection, jobs, NOTHING, MAIN)

        # Then Sonarr failed in phase 1.
        self.assertIn("| sonarr | failed in phase 1 (", text)
        # And the publisher counts it as refused.
        self.assertIn({"sonarr": self.plan["candidates"]["sonarr"]},
                      publish.rejected(self.plan, selection, "success"))

    def test_image_failure_outranks_full_disk_in_phase_two(self):
        # Given phase-2 upgrade-path ran out of disk and fresh-install failed on the image.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})
        for job in selection["jobs"]:
            result = {"p2-upgrade-path": self.full_disk,
                      "p2-fresh-install": self.image_failed}.get(job["id"], self.passing)
            self.write(selection, job, result(selection, job))

        # When the status job classifies the failed phase 2 and renders the report.
        jobs = {"combine": "failure", "verify": "skipped", "publish": "skipped"}
        undecided = phase_two_undecided(selection, self.results)
        text = render(self.plan, selection, jobs, NOTHING, MAIN, undecided)

        # Then Sonarr failed in phase 2.
        self.assertIn("| sonarr | failed in phase 2 (", text)

    def test_sampler_records_the_peak_not_the_end(self):
        # Given a filesystem whose free space falls from 10 GB to 4 GB and recovers.
        free = iter([10_000_000_000, 4_000_000_000])
        def statvfs(path):
            return types.SimpleNamespace(f_bavail=next(free, 10_000_000_000), f_frsize=1)

        # When the sampler watches it until the space has recovered.
        with mock.patch.object(runner.os, "statvfs", statvfs), \
                mock.patch.object(runner, "SAMPLE_SECONDS", 0.01):
            sampler = DiskSampler(lambda: str(self.results))
            deadline = time.monotonic() + 10
            while sampler.samples < 3 and time.monotonic() < deadline:
                time.sleep(0.01)
            fields = sampler.finish()

        # Then the peak growth is the 6 GB fall, and the end growth is zero.
        self.assertEqual((fields["disk_peak_growth_bytes"], fields["disk_growth_bytes"]),
                         (6_000_000_000, 0))

    def test_phase_two_full_disk_alone_keeps_the_open_pr(self):
        # Given an open digest PR that proposes both candidates of a failed phase 2.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})
        work = self.results / "work"
        facts = work / "facts"
        facts.mkdir(parents=True)
        lock = "".join("\t".join([s, *self.plan["candidates"][s].rsplit("@", 1),
                                   "2026-01-01T00:00:00Z", "scenario:fresh-install"]) + "\n"
                       for s in ("radarr", "sonarr"))
        compare = {"ahead_by": 1, "files": [{"filename": "docs/operations/image-digests.lock"}],
                   "commits": [{"commit": {"author": {"email": publish.AUTHOR_EMAIL},
                                           "committer": {"email": publish.AUTHOR_EMAIL},
                                           "message": publish.TITLE}}]}
        pr = {"number": 9, "user": {"login": publish.BOT, "type": "Bot"}, "head": {"sha": HEAD}}
        for name, text in (("head", HEAD), ("prs.json", json.dumps([pr])), ("closed.json", "[]"),
                           ("compare.json", json.dumps(compare)), ("branch.lock", lock)):
            (facts / name).write_text(text)
        for name, plan in (("plan.json", self.plan), ("selection.json", selection)):
            (work / name).write_text(json.dumps(plan))
        cases = (("only out of disk", {"p2-upgrade-path": self.full_disk}, "action=keep"),
                 ("also an image failure", {"p2-upgrade-path": self.full_disk,
                                            "p2-fresh-install": self.image_failed}, "action=close"))
        for name, broken, expected in cases:
            with self.subTest(name):
                results = work / name
                for job in selection["jobs"]:
                    result = broken.get(job["id"], self.passing)(selection, job)
                    self.write(selection, job, result, results)

                # When the publisher decides after phase 2 failed.
                proc = subprocess.run(
                    ["python3", str(ROOT / "tests/hosted_preflight.py"), "decide", "--run", RUN,
                     "--source", SOURCE, "--hash", fingerprint(self.plan),
                     "--plan", str(work / "plan.json"), "--selection", str(work / "selection.json"),
                     "--selection-hash", fingerprint(selection), "--verified", "skipped",
                     "--combined", "failure", "--results", str(results),
                     "--facts", str(facts)], capture_output=True, text=True, check=False)

                # Then it closes the PR only when an image failed.
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn(expected, proc.stdout.splitlines())

    def test_publisher_reads_failed_phase_two_results(self):
        # Given the workflow that publishes the digest PR.
        workflow = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())

        # When the publisher's steps are inspected.
        steps = workflow["jobs"]["preflight-publish"]["steps"]
        fetch = [s for s in steps if s.get("with", {}).get("pattern") == "result-p2-*"]
        decide = next(s for s in steps if s.get("id") == "decide")

        # Then it fetches phase-2 results as data when phase 2 failed.
        self.assertEqual([s["if"] for s in fetch], ["needs.preflight-combine.result == 'failure'"])
        # And it passes the phase-2 outcome and those results to the decision.
        self.assertIn("preflight-combine", workflow["jobs"]["preflight-publish"]["needs"])
        self.assertIn('--combined "$COMBINED" --results /tmp/preflight-results', decide["run"])


unittest.main()
PY
    pass 'hosted preflight separates a full runner disk from an image failure'
else
    fail 'hosted preflight separates a full runner disk from an image failure'
fi
summary

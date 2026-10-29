#!/usr/bin/env bash
# Accepted-image checks and issue lifecycle, without Docker or network access.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin baseline-canary
if python3 -I - "$REPO_ROOT" <<'PY'; then
import datetime as dt
import json
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

import yaml

ROOT = pathlib.Path(sys.argv.pop())
sys.path.insert(0, str(ROOT / "tests"))
import baseline_canary
from preflight import canary, runner
from preflight.model import FIXTURES, build_plan, effective, rows, source_sha

URL = "https://github.com/example/repo/actions/runs/1"
NOW = dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc)


class BaselineCanary(unittest.TestCase):
    def test_command_executes_one_baseline_job_and_only_resolves_fixtures(self):
        # Given the canary command with a disposable output directory.
        with tempfile.TemporaryDirectory() as temp:
            output = pathlib.Path(temp) / "artifact/result"
            argv = ["baseline_canary.py", "run", "--run", "1-1", "--output", str(output)]
            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.object(baseline_canary, "resolve", return_value="sha256:" + "a" * 64) as resolve, \
                 mock.patch.object(baseline_canary, "execute") as execute:

                # When the real command prepares and executes its job.
                baseline_canary.main()
                frozen, job_id, destination = execute.call_args.args
                saved = json.loads((output.parent / "plan.json").read_text())

        # Then it resolves fixture tags only and executes one accepted install without candidates.
        self.assertEqual([call.args[0] for call in resolve.call_args_list], list(FIXTURES.values()))
        self.assertEqual(frozen["candidates"], {})
        self.assertEqual((job_id, destination), ("baseline-install-e2e", output))
        self.assertEqual(saved, frozen)

    def test_no_drift_still_runs_the_accepted_install(self):
        # Given an accepted lock with no image changes and current fixture digests.
        baseline = rows(ROOT / "docs/operations/image-digests.lock")
        fixtures = {key: image + "@sha256:" + "a" * 64 for key, image in FIXTURES.items()}
        drift_plan = build_plan(baseline, baseline, [], source_sha(), "1-1", fixtures)

        # When the canary builds its plan separately from candidate selection.
        plan = canary.plan("1-1", fixtures)
        job, = plan["jobs"]

        # Then zero candidate jobs cannot suppress the baseline installer check.
        self.assertEqual(drift_plan["jobs"], [])
        self.assertEqual(job["scenario"], "install-e2e")
        self.assertEqual((job["combination"], job["services"], plan["candidates"]), ([], [], {}))
        self.assertEqual(effective(plan, job),
                         {s: f"{row.image}@{row.digest}" for s, row in baseline.items()})
        self.assertEqual(plan["fixtures"], fixtures)

    def test_runner_captures_inner_versions_before_other_evidence(self):
        # Given a DinD whose event file cannot be read after a failed install.
        def docker(*args):
            if args[-3:] == ("version", "--format", "{{json .}}"):
                return '{"Client":{"Version":"29.0.1"},"Server":{"Version":"29.0.2"}}'
            if args[-3:] == ("compose", "version", "--short"):
                return "v2.40.1\n"
            raise OSError("event file unavailable")

        with tempfile.TemporaryDirectory() as temp, mock.patch.object(runner, "docker", docker):
            folder = pathlib.Path(temp)

            # When evidence collection fails after reading the runtime versions.
            with self.assertRaises(OSError):
                runner.evidence("ms-test", folder)
            versions = json.loads((folder / "runtime.json").read_text())

        # Then the report can still name the actual inner client, daemon and Compose versions.
        self.assertEqual(versions, {"client": "29.0.1", "engine": "29.0.2", "compose": "v2.40.1"})

    def test_invalid_runtime_metadata_still_records_failure_and_removes_dind(self):
        # Given Docker version metadata with its required client field missing.
        with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryFile(mode="w+") as log:
            folder = pathlib.Path(temp)
            result = {"rc": 1}
            sampler = mock.Mock()
            sampler.finish.return_value = {"disk_error": None}
            with mock.patch.object(runner, "docker", return_value="{}"), \
                 mock.patch.object(runner.subprocess, "run") as cleanup:

                # When the runner records the failed scenario.
                runner.record(result, "ms-test", folder, log, sampler, time.monotonic())
                saved = json.loads((folder / "result.json").read_text())

        # Then missing version metadata is an evidence failure and cannot skip container removal.
        self.assertIn("Client", saved["evidence_error"])
        self.assertEqual(cleanup.call_args.args[0], ["docker", "rm", "-fv", "ms-test"])

    def test_failure_report_names_assertions_and_versions(self):
        # Given evidence from a failed installer assertion.
        with tempfile.TemporaryDirectory() as temp:
            folder = pathlib.Path(temp)
            (folder / "result").mkdir()
            (folder / "result/runtime.json").write_text(json.dumps(
                {"client": "29.0.1", "engine": "29.0.2", "compose": "v2.40.1"}))
            (folder / "result/scenario.log").write_text(
                "  [PASS] earlier step\n  [FAIL] installer exits 0\n    expected 0, got 1\n")

            # When the report is rendered for a failed job.
            report = canary.failure_report(folder, "failure", URL)

        # Then the issue names the failed assertion, runtime versions and evidence link.
        for text in ("installer exits 0", "29.0.1", "29.0.2", "v2.40.1", URL):
            self.assertIn(text, report)

    def test_missing_artifacts_cannot_report_success(self):
        # Given an apparently successful job with no result artifact.
        with tempfile.TemporaryDirectory() as temp:
            # When the report reads the absent result.
            report = canary.failure_report(pathlib.Path(temp), "success", URL)

        # Then a failure issue explains the missing evidence.
        self.assertIn("missing", report.lower())
        self.assertIn("unavailable", report)

    def test_only_complete_passing_results_clear_the_failure(self):
        passing = {"rc": 0, "passes": 280, "failures": 0, "skips": 0,
                   "evidence_error": None, "disk_error": None, "runner_error": None}
        cases = (({}, False), ({"skips": 1}, True), ({"passes": 0}, True),
                 ({"rc": 1}, True), ({"failures": 1}, True), ({"passes": "280"}, True),
                 ({"evidence_error": "no events"}, True), ({"disk_error": "unmeasured"}, True),
                 ({"runner_error": "disk full"}, True))
        for changes, failed in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as temp:
                # Given a passing result or one incomplete or failing result field.
                folder = pathlib.Path(temp)
                (folder / "result").mkdir()
                (folder / "result/result.json").write_text(json.dumps(dict(passing, **changes)))
                (folder / "result/runtime.json").write_text('{"client":"29","engine":"29","compose":"2"}')

                # When an otherwise successful job is reported.
                report = canary.failure_report(folder, "success", URL)

                # Then only a complete run with passing assertions clears the failure issue.
                self.assertIs(report is not None, failed)

    def test_malformed_artifact_still_generates_a_failure_issue(self):
        for invalid in ("{", "[]", "null"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temp:
                # Given a broken or truncated result artifact after a failed install.
                folder = pathlib.Path(temp)
                (folder / "result").mkdir()
                (folder / "result/result.json").write_text(invalid)

                # When the failure report reads the artifact as data.
                report = canary.failure_report(folder, "failure", URL)

                # Then the issue still opens and explains the invalid artifact.
                self.assertIn("invalid result.json", report)

    def test_missing_runtime_fields_cannot_clear_the_failure(self):
        # Given a complete scenario result but an empty runtime version object.
        with tempfile.TemporaryDirectory() as temp:
            folder = pathlib.Path(temp)
            (folder / "result").mkdir()
            (folder / "result/result.json").write_text(json.dumps(
                {"rc": 0, "passes": 238, "failures": 0, "skips": 0,
                 "evidence_error": None, "disk_error": None, "runner_error": None}))
            (folder / "result/runtime.json").write_text('{}')

            # When the reporter checks an otherwise successful job.
            report = canary.failure_report(folder, "success", URL)

        # Then it retains the failure issue because the required versions are missing.
        self.assertIsNotNone(report)

    def test_reminder_starts_at_45_days_and_clears_on_activity(self):
        # Given commits immediately before and at the reminder threshold.
        for age, expected in ((44, False), (45, True), (59, True), (0, False)):
            with self.subTest(age=age):
                timestamp = (NOW - dt.timedelta(days=age)).isoformat()

                # When the weekly reporter checks the default branch's last commit.
                reminder = canary.inactivity_report(timestamp, NOW, URL)

                # Then only a commit at least 45 days old needs a reminder.
                self.assertEqual(reminder is not None, expected)
                if reminder:
                    self.assertIn("60 days", reminder)
                    self.assertIn("gh workflow enable baseline-canary.yml", reminder)
                    self.assertIn("gh workflow enable image-drift.yml", reminder)

    def test_issue_is_created_updated_closed_and_reopened(self):
        for state, action in ((None, "create"), ("OPEN", "edit"), ("CLOSED", "reopen")):
            with self.subTest(state=state), mock.patch.object(canary, "gh") as gh:
                # Given no prior issue, an open issue, or a closed issue from the previous failure.
                gh.return_value = json.dumps([] if state is None else [{"number": 7, "state": state}])

                # When a failing run synchronizes its single tracking issue.
                canary.sync_issue("baseline-canary", "Baseline canary failed", "failure details")
                commands = [call.args for call in gh.call_args_list]

                # Then it creates, updates or reopens the issue without creating duplicates.
                self.assertTrue(any(cmd[:2] == ("issue", action) for cmd in commands), commands)
                self.assertEqual(sum(cmd[:2] == ("issue", "create") for cmd in commands),
                                 int(state is None))

        with mock.patch.object(canary, "gh", return_value='[{"number":7,"state":"OPEN"}]') as gh:
            # Given an open failure issue and a now passing run.
            # When the issue is synchronized with no failure body.
            canary.sync_issue("baseline-canary", "Baseline canary failed", None)

            # Then the existing issue closes.
            self.assertTrue(any(call.args[:2] == ("issue", "close") for call in gh.call_args_list))

    def test_duplicate_tracking_issues_fail_before_editing_any_issue(self):
        # Given two open issues that carry the dedicated tracking label.
        issues = '[{"number":7,"state":"OPEN"},{"number":8,"state":"OPEN"}]'
        with mock.patch.object(canary, "gh", return_value=issues) as gh:

            # When a report tries to update the ambiguous tracking issue.
            with self.assertRaisesRegex(ValueError, "multiple open"):
                canary.sync_issue("baseline-canary", "failure", "details")

            # Then it changes no issue and asks for the duplicate labels to be reconciled.
            self.assertFalse(any(call.args[:2] in (("issue", "edit"), ("issue", "close"),
                                                   ("issue", "create"), ("issue", "reopen"))
                                 for call in gh.call_args_list))

    def test_weekly_job_runs_without_drift_and_has_no_publication_permissions(self):
        # Given the standalone canary workflow.
        workflow = yaml.safe_load((ROOT / ".github/workflows/baseline-canary.yml").read_text())
        run, report = workflow["jobs"]["canary"], workflow["jobs"]["report"]

        # When its trigger, dependencies, commands and permissions are inspected.
        commands = "\n".join(step.get("run", "") for step in run["steps"])

        # Then each weekly or manual run executes the accepted baseline without a drift condition.
        self.assertEqual(len(workflow[True]["schedule"]), 1)
        self.assertIn("workflow_dispatch", workflow[True])
        self.assertNotIn("if", run)
        self.assertNotIn("needs", run)
        self.assertIn("baseline_canary.py run", commands)
        self.assertIn("docker build --pull --no-cache -t ms-hosted-dind:debian", commands)
        scenario = next(step for step in run["steps"] if "baseline_canary.py run" in step.get("run", ""))
        self.assertEqual(scenario.get("shell"), "bash")  # GitHub's explicit bash includes pipefail.
        self.assertEqual(run["permissions"], {"contents": "read"})
        self.assertNotIn("GH_TOKEN", json.dumps(run))
        self.assertNotIn("GITHUB_TOKEN", json.dumps(run))
        self.assertNotIn("contents: write", json.dumps(workflow))
        self.assertEqual(report["permissions"], {"contents": "read", "issues": "write"})
        self.assertIn("!cancelled()", report["if"])
        self.assertIn("default_branch", report["if"])
        self.assertNotIn("baseline_canary.py run", json.dumps(report))


unittest.main()
PY
    pass 'baseline runs without drift, records failures and maintains one tracking issue'
else
    fail 'baseline runs without drift, records failures and maintains one tracking issue'
fi
summary

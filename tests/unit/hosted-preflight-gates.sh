#!/usr/bin/env bash
# Hosted preflight gates that each guard one boundary: which failure closes the
# digest PR, the exact evidence checks, the token-free scenario environment,
# the disk headroom contract, and the job log that an image cannot command.
# No Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-gates
if python3 -I - "$REPO_ROOT" <<'PY'; then
import contextlib
import io
import json
import os
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
from preflight import publish, runner
from preflight.model import (FIXTURES, HEADROOM_BYTES, ROOT, build_plan, combination_plan, drift,
                             effective, fingerprint, headroom_error, rows, source_sha)
from preflight.verify import check_result

SOURCE = source_sha()
RUN = "123-1"
HEAD = "b" * 40
MEASURED = {"disk_error": None, "disk_samples": 3, "disk_free_start_bytes": 30_000_000_000,
            "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000}


def owned_branch():
    """The comparison GitHub returns for a branch the publisher built."""
    return {"commits": [{"commit": {"author": {"email": publish.AUTHOR_EMAIL},
                                    "committer": {"email": publish.AUTHOR_EMAIL},
                                    "message": publish.TITLE + "\n"}}],
            "ahead_by": 1, "files": [{"filename": "docs/operations/image-digests.lock"}]}


def bot_pr(user_type="Bot"):
    return {"number": 9, "user": {"login": publish.BOT, "type": user_type}, "head": {"sha": HEAD}}


def lock_line(service, ref):
    image, digest = ref.rsplit("@", 1)
    return "\t".join([service, image, digest, "2026-01-01T00:00:00Z", "scenario:fresh-install"]) + "\n"


class StubSampler:
    """A disk sampler that reports fixed measurements instead of reading a disk."""

    fields = MEASURED

    def __init__(self, locate):
        pass

    def stop(self):
        pass

    def finish(self):
        return dict(self.fields)


class Gates(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = pathlib.Path(temp.name)
        old = rows(ROOT / "docs/operations/image-digests.lock")
        current = dict(old)
        for service, digit in (("sonarr", "1"), ("radarr", "4")):
            current[service] = drift.ImageDigest(service, old[service].image, "sha256:" + digit * 64)
        fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.plan = build_plan(old, current, ["radarr", "sonarr"], SOURCE, RUN, fixtures)
        self.refs = self.plan["candidates"]

    def decide_after(self, selection, verified, branch_lock):
        facts = publish.Facts([bot_pr()], HEAD, owned_branch(), branch_lock, [])
        return publish.decide(None, publish.rejected(self.plan, selection, verified), facts)

    def test_failed_combination_keeps_a_pr_that_proposes_part_of_it(self):
        # Given an open PR that proposes Sonarr alone, proven alone in an earlier run.
        branch_lock = lock_line("sonarr", self.refs["sonarr"])
        # And this run's Radarr and Sonarr each passed phase 1, then failed together in phase 2.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})

        # When the publisher decides with nothing accepted.
        decision = self.decide_after(selection, "skipped", branch_lock)

        # Then it keeps the PR, because Sonarr with the accepted companions is still proven.
        self.assertEqual((decision.action, decision.pr), ("keep", 9))
        # And it does not claim that this run refused Sonarr.
        self.assertNotIn("refused sonarr", decision.reason)

    def test_failed_combination_closes_a_pr_that_proposes_all_of_it(self):
        # Given an open PR that proposes Radarr and Sonarr at this run's digests.
        branch_lock = lock_line("radarr", self.refs["radarr"]) + lock_line("sonarr", self.refs["sonarr"])
        # And the two failed together in phase 2.
        selection = combination_plan(self.plan, ["radarr", "sonarr"], {})

        # When the publisher decides with nothing accepted.
        decision = self.decide_after(selection, "skipped", branch_lock)

        # Then it closes the PR and names the refused combination.
        self.assertEqual(decision.action, "close")
        self.assertIn("refused radarr + sonarr at the exact digests that PR #9 proposes",
                      decision.reason)

    def test_phase_one_failure_at_the_exact_digest_closes_the_pr(self):
        # Given an open PR that proposes Sonarr alone at this run's digest.
        branch_lock = lock_line("sonarr", self.refs["sonarr"])
        # And Sonarr failed phase 1 while Radarr passed alone.
        selection = combination_plan(self.plan, ["radarr"], {"sonarr": ["upgrade-path"]})

        # When the publisher decides with nothing accepted.
        decision = self.decide_after(selection, "failure", branch_lock)

        # Then it closes the PR, because the exact proposed digest failed with the accepted companions.
        self.assertEqual(decision.action, "close")
        self.assertIn("refused sonarr at the exact digests", decision.reason)

    def test_publisher_refuses_a_pr_from_a_user_named_like_the_bot(self):
        # Given an open PR whose author has the bot's login but is a user account.
        facts = publish.Facts([bot_pr(user_type="User")], HEAD, owned_branch(), "", [])

        # When a passing run decides how to publish its lock.
        decision = publish.decide("proposed", [], facts)

        # Then it refuses, because only the Actions bot account owns the rolling PR.
        self.assertEqual(decision.action, "refuse")
        self.assertIn("was not opened by", decision.reason)

    def test_candidate_that_was_not_inspected_does_not_qualify(self):
        # Given a passing Sonarr job whose image inspection lists only another image.
        job = next(j for j in self.plan["jobs"] if j["id"] == "p1-sonarr.fresh-install")
        ref = self.refs["sonarr"]
        result = {"schema": 1, "plan": fingerprint(self.plan), "source": SOURCE, "run": RUN,
                  "job": job["id"], "scenario": job["scenario"], "run_id": job["run_id"],
                  "architecture": "x86_64", "rc": 0, "passes": 240, "failures": 0, "skips": 0,
                  "evidence_error": None, "runner_error": None, "elapsed_seconds": 600, **MEASURED}
        other = {"id": "other", "digests": ["example/other@sha256:" + "5" * 64],
                 "arch": "amd64", "os": "linux"}
        events = [{"action": "start", "id": "c", "service": "sonarr", "image": ref}]
        for name, value in (("result", result), ("images", [other]), ("events", events)):
            (self.folder / (name + ".json")).write_text(json.dumps(value))
        receipt = ["sonarr", *ref.rsplit("@", 1), job["scenario"], SOURCE, job["run_id"],
                   "x86_64", "2026-01-01T00:00:00Z"]
        (self.folder / "receipts.tsv").write_text("\t".join(receipt) + "\n")

        # When the verifier validates the job.
        # Then it refuses the evidence, because the candidate digest was never inspected.
        with self.assertRaisesRegex(ValueError, "sonarr: candidate was not inspected"):
            check_result(self.plan, job, self.folder)

    def test_runner_counts_skipped_assertions(self):
        # Given a scenario log with one pass, one failure and one skip.
        result = {"passes": 0, "failures": 0, "skips": 0}
        log = io.StringIO("  [PASS] a\n  [FAIL] b\n  [SKIP] c\n")

        # When the runner records the result without Docker.
        with mock.patch.object(runner, "evidence"), mock.patch.object(runner.subprocess, "run"):
            runner.record(result, "ms-test", self.folder, log, StubSampler(None), 0.0)

        # Then the skip is counted, so that the verifier refuses the job.
        self.assertEqual((result["passes"], result["failures"], result["skips"]), (1, 1, 1))

    def test_scenario_environment_has_no_github_token(self):
        # Given a job step environment that holds both GitHub token names.
        tokens = {"GITHUB_TOKEN": "ghs_example", "GH_TOKEN": "ghs_example"}
        job = self.plan["jobs"][0]

        # When the runner builds the environment of tests/run.sh.
        with mock.patch.dict(os.environ, tokens):
            child = runner.job_environment(self.plan, job, "ms-test", self.folder)

        # Then neither token reaches the scenario or the candidate images.
        self.assertEqual(sorted(set(tokens) & set(child)), [])

    def test_headroom_minimum_is_two_gibibytes(self):
        # Given the headroom minimum.
        exact = {"disk_free_start_bytes": 20 * 1024**3, "disk_peak_growth_bytes": 18 * 1024**3}

        # When a job left exactly 2 GiB, and one byte less, free at its peak.
        short = dict(exact, disk_peak_growth_bytes=exact["disk_peak_growth_bytes"] + 1)

        # Then the minimum is 2 GiB (2147483648 bytes).
        self.assertEqual(HEADROOM_BYTES, 2_147_483_648)
        # And exactly 2 GiB free qualifies, while one byte less is exhausted headroom.
        self.assertIsNone(headroom_error(exact))
        self.assertIn("2147483647 bytes free at peak", headroom_error(short))

    def test_scenario_log_cannot_issue_workflow_commands(self):
        forged = "::error title=Accepted::forged by the image\n::add-mask::ghs_example\n"
        for name, disk in (("failed scenario", MEASURED),
                           ("full disk", dict(MEASURED, disk_free_start_bytes=14_000_000_000))):
            with self.subTest(name):
                # Given a scenario whose log prints workflow commands.
                def scenario(env, scenario, log):
                    log.write("  [PASS] a\n" + forged)
                    return 1

                sampler = type("Sampler", (StubSampler,), {"fields": disk})
                printed = io.StringIO()

                # When the runner prints the log tail into the job log.
                with mock.patch.object(runner, "run_with_deadline", scenario), \
                        mock.patch.object(runner, "DiskSampler", sampler), \
                        mock.patch.object(runner, "evidence"), \
                        mock.patch.object(runner.subprocess, "check_output", return_value=""), \
                        mock.patch.object(runner.subprocess, "run"), \
                        contextlib.redirect_stdout(printed), self.assertRaises(ValueError):
                    runner.execute(self.plan, self.plan["jobs"][0]["id"], self.folder / name)

                # Then workflow commands stop before the log and resume only after it.
                lines = printed.getvalue().splitlines()
                stops = [i for i, line in enumerate(lines) if line.startswith("::stop-commands::")]
                self.assertEqual(len(stops), 1, lines)
                token = lines[stops[0]].split("::")[2]
                self.assertRegex(token, r"^[0-9a-f]{32}$")
                end = lines.index(f"::{token}::")
                commands = [i for i, line in enumerate(lines) if line.startswith("::")]
                self.assertEqual([i for i in commands if not stops[0] <= i <= end], [])
                # And the forged commands are inside that window, and the token is not in the log.
                self.assertTrue(stops[0] < lines.index("::add-mask::ghs_example") < end)
                self.assertNotIn(token, forged)


unittest.main()
PY
    pass 'hosted preflight gates keep a proven PR, check exact evidence and quote image logs'
else
    fail 'hosted preflight gates keep a proven PR, check exact evidence and quote image logs'
fi
summary

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
from preflight import publish
from preflight.model import (FIXTURES, ROOT, build_plan, check_plan, combination_plan, drift,
                             effective, fingerprint, rows, source_sha)
from preflight.verify import (accept, authorized_jobs, check_result, check_runtime_evidence,
                              select_combination)
from preflight.runner import sanitize
from preflight.status import render
import yaml

SOURCE = source_sha()
RUN = "123-1"


class HostedEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = pathlib.Path(self.temp.name)
        self.results = self.folder / "results"
        self.old = rows(ROOT / "docs/operations/image-digests.lock")
        self.current = dict(self.old)
        for service, digit in (("sonarr", "1"), ("radarr", "4")):
            prior = self.old[service]
            self.current[service] = drift.ImageDigest(service, prior.image, "sha256:" + digit * 64)
        self.digest = self.current["sonarr"].digest
        self.fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.snapshot = self.folder / "current.tsv"
        drift.write_tsv(self.snapshot, list(self.current.values()))
        self.plan = self.phase1(["sonarr"])
        self.job = next(j for j in self.plan["jobs"] if j["scenario"] == "fresh-install")
        self.result = self.result_for(self.plan, self.job)
        self.events = [{"action": "start", "id": "container-id", "service": "sonarr",
                        "image": self.plan["candidates"]["sonarr"]}]
        self.images = [{"id": "image-id", "digests": [self.plan["candidates"]["sonarr"]],
                        "arch": "amd64", "os": "linux"}]

    def phase1(self, selected):
        return build_plan(self.old, self.current, selected, SOURCE, RUN, self.fixtures)

    def result_for(self, plan, job):
        return {"schema": 1, "plan": fingerprint(plan), "source": SOURCE, "run": RUN,
                "job": job["id"], "scenario": job["scenario"], "run_id": job["run_id"],
                "architecture": "x86_64", "rc": 0, "passes": 240, "failures": 0, "skips": 0,
                "evidence_error": None, "elapsed_seconds": 600,
                "disk_growth_bytes": 2_000_000_000}

    def write_evidence(self, plan, job, folder=None, result=None, events=None, images=None):
        folder = folder or self.results / ("result-" + job["id"])
        folder.mkdir(parents=True, exist_ok=True)
        refs = effective(plan, job)
        data = {
            "result": result or self.result_for(plan, job),
            "events": events or [{"action": "start", "id": s, "service": s, "image": refs[s]}
                                 for s in job["combination"]],
            "images": images or [{"id": s, "digests": [refs[s]], "arch": "amd64", "os": "linux"}
                                 for s in job["combination"]],
        }
        for name, value in data.items():
            (folder / (name + ".json")).write_text(json.dumps(value))
        receipts = ["\t".join([s, *refs[s].rsplit("@", 1), job["scenario"], SOURCE,
                               job["run_id"], "x86_64", "2026-01-01T00:00:00Z"])
                    for s in job["services"]]
        (folder / "receipts.tsv").write_text("\n".join(receipts) + "\n")

    def pass_jobs(self, plan, skip=()):
        for job in plan["jobs"]:
            if job["id"] not in skip:
                self.write_evidence(plan, job)

    def test_valid_evidence_qualifies(self):
        # Given complete evidence from the intended source, run and combination.
        self.write_evidence(self.plan, self.job, self.folder)

        # When the controlled publisher validates the job.
        path = check_result(self.plan, self.job, self.folder)

        # Then the exact receipt artifact qualifies for acceptance.
        self.assertEqual(path, self.folder / "receipts.tsv")

    def test_invalid_status_or_identity_blocks(self):
        for field, value in (("rc", 1), ("failures", 1), ("skips", 1), ("passes", 0),
                             ("source", "0" * 40), ("run", "old-run"), ("plan", "old-plan"),
                             ("job", "p1-radarr.fresh-install"), ("architecture", "aarch64")):
            with self.subTest(field=field):
                # Given an otherwise valid artifact with one broken contract.
                result = dict(self.result, **{field: value})
                self.write_evidence(self.plan, self.job, self.folder, result=result)

                # When the publisher validates the result.
                # Then no failed, skipped, empty, stale or mismatched job qualifies.
                with self.assertRaises(ValueError):
                    check_result(self.plan, self.job, self.folder)

    def test_wrong_companion_blocks(self):
        # Given a passing job whose companion ran another digest.
        self.events.append({"action": "start", "id": "companion", "service": "radarr",
                            "image": "example/wrong@sha256:" + "3" * 64})

        # When the companion combination is checked.
        # Then the passing candidate cannot authorize a different installation.
        with self.assertRaisesRegex(ValueError, "runtime companion"):
            check_runtime_evidence(self.plan, self.job, self.events, self.images)

    def test_missing_candidate_start_blocks(self):
        # Given valid receipts and inspections but only a companion started.
        events = [{"action": "start", "id": "companion", "service": "radarr",
                   "image": self.plan["accepted"]["radarr"]}]
        self.write_evidence(self.plan, self.job, self.folder, events=events)

        # When the candidate's runtime evidence is checked.
        # Then a pulled image and receipt cannot replace its start event.
        with self.assertRaisesRegex(ValueError, "sonarr.*start"):
            check_result(self.plan, self.job, self.folder)

    def test_wrong_fixture_blocks(self):
        # Given the fixture used a floating image instead of its frozen digest.
        self.events.append({"action": "start", "id": "fixture", "service": None,
                            "image": "python:3.12-alpine"})

        # When fixture provenance is checked.
        # Then the result is refused even though service evidence matches.
        with self.assertRaisesRegex(ValueError, "fixture image"):
            check_runtime_evidence(self.plan, self.job, self.events, self.images)

    def test_wrong_scenario_receipt_blocks(self):
        # Given a receipt from a scenario that did not test the required behavior.
        self.write_evidence(self.plan, self.job, self.folder)
        path = self.folder / "receipts.tsv"
        path.write_text(path.read_text().replace("fresh-install", "smoke"))

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
            build_plan(self.old, self.current, ["flaresolverr"], SOURCE, RUN, {})

    def test_each_candidate_is_isolated_in_phase_one(self):
        # Given two changed candidates selected together.
        plan = self.phase1(["radarr", "sonarr"])

        # When their phase-1 jobs are planned.
        jobs = {j["id"]: j for j in plan["jobs"]}

        # Then each candidate runs alone through fresh and existing-install scenarios.
        self.assertEqual(set(jobs), {"p1-radarr.fresh-install", "p1-radarr.upgrade-path",
                                     "p1-sonarr.fresh-install", "p1-sonarr.upgrade-path"})
        refs = effective(plan, jobs["p1-sonarr.upgrade-path"])
        # And the other candidate stays at its accepted digest in that job.
        self.assertEqual(refs["radarr"], plan["accepted"]["radarr"])
        self.assertEqual(refs["sonarr"], plan["candidates"]["sonarr"])

    def test_selection_excludes_phase_one_failure(self):
        # Given Sonarr passed phase 1 and Radarr failed its upgrade-path job.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan)
        job = next(j for j in plan["jobs"] if j["id"] == "p1-radarr.upgrade-path")
        self.write_evidence(plan, job, result=dict(self.result_for(plan, job), rc=1))

        # When the read-only selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then only Sonarr continues, and Radarr's failure is recorded.
        self.assertEqual(selection["selected"], ["sonarr"])
        self.assertEqual(selection["failed"], {"radarr": ["upgrade-path"]})
        # And the frozen selection is bound to the phase-1 plan.
        self.assertEqual(selection["parent"], fingerprint(plan))

    def test_single_candidate_authorizes_from_phase_one(self):
        # Given one selected candidate with complete phase-1 evidence.
        self.pass_jobs(self.plan)
        selection = select_combination(self.plan, self.results)
        output = self.folder / "accepted"

        # When the verifier accepts the run.
        accept(self.plan, selection, self.snapshot, self.results, output)

        # Then phase-1 evidence authorizes that exact combination without phase 2.
        self.assertEqual((selection["authority"], selection["jobs"]), ("phase-1", []))
        accepted = rows(output / "image-digests.lock")
        self.assertEqual(accepted["sonarr"].digest, self.digest)
        # And every other row, including the drifted Radarr, keeps its accepted digest.
        for service in self.old.keys() - {"sonarr"}:
            self.assertEqual(accepted[service], self.old[service])

    def test_phase_one_cannot_authorize_combination(self):
        # Given two candidates that each passed phase 1 alone.
        plan = self.phase1(["radarr", "sonarr"])
        selection = combination_plan(plan, ["radarr", "sonarr"], {})

        # When a selection claims phase-1 evidence for their combination.
        forged = dict(selection, authority="phase-1")

        # Then the verifier refuses, because neither phase-1 job ran both candidates.
        with self.assertRaisesRegex(ValueError, "phase-1 evidence cannot authorize"):
            authorized_jobs(plan, forged)

    def test_stale_phase_two_plan_is_rejected(self):
        # Given phase-1 results in which Radarr failed.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan, skip={"p1-radarr.fresh-install"})
        current = select_combination(plan, self.results)
        stale = combination_plan(plan, ["radarr", "sonarr"], {})
        self.pass_jobs(stale)

        # When a job receives the current plan with the hash of the stale plan.
        # Then the immutable plan hash refuses it.
        with self.assertRaisesRegex(ValueError, "immutable plan hash"):
            check_plan(current, SOURCE, RUN, fingerprint(stale))
        # And a stale plan that does not follow from phase 1 cannot authorize its evidence.
        with self.assertRaisesRegex(ValueError, "stale or does not follow"):
            accept(plan, stale, self.snapshot, self.results, self.folder / "accepted")
        self.assertFalse((self.folder / "accepted").exists())

    def test_complete_combination_precedes_selective_write(self):
        # Given both candidates passed phase 1 but phase 2 lacks upgrade-path evidence.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        self.pass_jobs(selection, skip={"p2-upgrade-path"})
        output = self.folder / "accepted"

        # When the verifier attempts acceptance after the failed phase 2.
        # Then it writes no accepted directory or lock.
        with self.assertRaises(FileNotFoundError):
            accept(plan, selection, self.snapshot, self.results, output)
        self.assertFalse(output.exists())

        # Given the same combination also has complete phase-2 evidence.
        self.pass_jobs(selection)

        # When the verifier accepts the complete evidence set.
        accept(plan, selection, self.snapshot, self.results, output)

        # Then it changes both selected digests and preserves unrelated rows.
        accepted = rows(output / "image-digests.lock")
        for service in self.old:
            expected = self.current if service in ("radarr", "sonarr") else self.old
            self.assertEqual(accepted[service].digest, expected[service].digest)

    def test_image_execution_has_no_publishing_permissions(self):
        # Given the workflow that executes privileged candidate containers.
        workflow = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())
        jobs = workflow["jobs"]

        # When its execution, selection, publication and report permissions are inspected.
        image_jobs = [jobs["preflight-isolate"], jobs["preflight-combine"]]
        publisher, report = jobs["preflight-publish"], jobs["preflight-report"]

        # Then image jobs are read-only, bounded and receive no secrets.
        for job in image_jobs:
            self.assertEqual(job["permissions"], {"contents": "read"})
            self.assertEqual(job["runs-on"], "ubuntu-24.04")
            self.assertEqual((job["strategy"]["max-parallel"], job["timeout-minutes"]), (2, 85))
            self.assertNotIn("secrets.", json.dumps(job))
        # And the planner, selector and verifier are read-only too.
        for name in ("preflight-plan", "preflight-select", "preflight-verify"):
            self.assertEqual(jobs[name]["permissions"], {"contents": "read"})
        self.assertIn("workflow_dispatch", jobs["preflight-plan"]["if"])
        # And only the separate default-branch publisher can write repository content.
        self.assertIn("github.event.repository.default_branch", publisher["if"])
        self.assertEqual(publisher["permissions"], {"contents": "write", "pull-requests": "write"})
        self.assertNotIn("gh workflow run", json.dumps(publisher))
        self.assertEqual((publisher["env"]["BRANCH"], publisher["env"]["TITLE"]),
                         (publish.BRANCH, publish.TITLE))
        # And the status reporter can only comment and never runs an image job.
        self.assertEqual(report["permissions"], {"issues": "write"})
        self.assertNotIn("hosted_preflight.py run", json.dumps(report))

    def test_publisher_refuses_foreign_branch_or_pr(self):
        head = "a" * 40
        owned = {"commits": [{"commit": {"author": {"email": publish.AUTHOR_EMAIL},
                                         "committer": {"email": publish.AUTHOR_EMAIL},
                                         "message": publish.TITLE}}],
                 "ahead_by": 1, "files": [{"filename": "README.md"}]}
        bot_pr = {"number": 7, "user": {"login": publish.BOT, "type": "Bot"}, "head": {"sha": head}}
        foreign_commit = copy.deepcopy(owned)
        foreign_commit["commits"][0]["commit"]["author"]["email"] = "someone@example.com"
        extra_commit = dict(owned, ahead_by=2, commits=owned["commits"] * 2)
        other_file = dict(owned, files=[{"filename": "setup.sh"}])
        human_pr = dict(bot_pr, user={"login": "someone", "type": "User"})
        for name, prs, compare in (("human PR", [human_pr], owned),
                                   ("foreign commit", [bot_pr], foreign_commit),
                                   ("extra commit", [bot_pr], extra_commit),
                                   ("file outside the record", [], other_file)):
            with self.subTest(name):
                # Given a rolling branch or PR that the publisher did not create.
                # When a passing run decides how to publish its lock.
                decision = publish.decide("proposed", prs, head, compare, "old")

                # Then it refuses and changes nothing.
                self.assertEqual(decision.action, "refuse")

    def test_publisher_keeps_one_rolling_pr(self):
        head = "b" * 40
        owned = {"commits": [{"commit": {"author": {"email": publish.AUTHOR_EMAIL},
                                         "committer": {"email": publish.AUTHOR_EMAIL},
                                         "message": publish.TITLE + "\n"}}],
                 "ahead_by": 1, "files": [{"filename": "docs/operations/image-digests.lock"}]}
        pr = [{"number": 9, "user": {"login": publish.BOT, "type": "Bot"}, "head": {"sha": head}}]
        lock = "s\ti\tsha256:1\t2026-01-01T00:00:00Z\tscenario:fresh-install\n"
        restamped = lock.replace("2026-01-01", "2026-02-02")
        for name, args, expected in (
            ("first proposal", ("new", [], "", {}, None), ("create", None, "")),
            ("newer combination", ("new", pr, head, owned, lock), ("update", 9, head)),
            ("same lock", (restamped, pr, head, owned, lock), ("unchanged", 9, head)),
            ("nothing accepted", (None, pr, head, owned, lock), ("keep", 9, head)),
            ("nothing open", (None, [], "", {}, None), ("none", None, "")),
        ):
            with self.subTest(name):
                # Given the open rolling PR state and this run's proposal.
                # When the publisher decides.
                decision = publish.decide(*args)

                # Then it makes exactly the expected change under a lease on the observed head.
                self.assertEqual((decision.action, decision.pr, decision.lease), expected)

    def test_report_names_each_service_outcome(self):
        # Given Radarr failed phase 1, Sonarr was proposed, and two services were not tested.
        plan = self.phase1(["radarr", "sonarr"])
        plan["pending"] = {"bazarr": "subtitle database migration is not covered",
                           "lidarr": "not selected"}
        selection = combination_plan(plan, ["sonarr"], {"radarr": ["upgrade-path"]})
        publication = {"result": "success", "outcome": "created", "pr": "12", "reason": "new"}

        # When the status report is rendered.
        text = render(plan, selection, "success", publication, "https://example.test/run/1")

        # Then each service has exactly one visible state.
        self.assertIn("| sonarr | proposed in PR #12 |", text)
        self.assertIn("| radarr | failed in phase 1 (", text)
        self.assertIn("`result-p1-radarr.upgrade-path`", text)
        self.assertIn("| bazarr | held: subtitle database migration is not covered |", text)
        self.assertIn("| lidarr | not selected |", text)

    def test_log_export_masks_fixture_credentials(self):
        # Given log text containing a fixture password and generated API key.
        password = 'Fr3sh!$tack"with\\special#chars^&*'
        key = "fixture-" + "a" * 32

        # When logs are prepared for artifact upload.
        text = sanitize(password + ' {"apiKey": "' + key + '"}')

        # Then neither complete credential reaches the artifact.
        self.assertNotIn(password, text)
        self.assertNotIn(key, text)


unittest.main()
PY
    pass 'hosted preflight isolates, combines and publishes only qualifying evidence'
else
    fail 'hosted preflight isolates, combines and publishes only qualifying evidence'
fi
summary

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
sys.path.insert(0, sys.path[0] + "/fixtures")
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight import publish
from preflight.model import (FIXTURES, ROOT, build_plan, check_plan, combination_plan, drift,
                             effective, fingerprint, rows, source_sha)
from preflight.verify import (accept, authorized_jobs, check_result, check_runtime_evidence,
                              select_combination)
from preflight.runner import sanitize
from preflight.status import abort, render
import yaml

SOURCE = source_sha()
RUN = "123-1"
HEAD = "b" * 40
MAIN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}


def owned_branch():
    """The comparison GitHub returns for a branch the publisher built."""
    return {"commits": [{"commit": {"author": {"email": publish.AUTHOR_EMAIL},
                                    "committer": {"email": publish.AUTHOR_EMAIL},
                                    "message": publish.TITLE + "\n"}}],
            "ahead_by": 1, "files": [{"filename": "docs/operations/image-digests.lock"}]}


def bot_pr(number=9, head=HEAD, **fields):
    return dict({"number": number, "user": {"login": publish.BOT, "type": "Bot"},
                 "head": {"sha": head}}, **fields)


def lock_line(service, ref, stamp="2026-01-01T00:00:00Z"):
    image, digest = ref.rsplit("@", 1)
    return "\t".join([service, image, digest, stamp, "scenario:fresh-install"]) + "\n"


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
                "evidence_error": None, "elapsed_seconds": 600, "disk_error": None,
                "runner_error": None, "disk_samples": 300, "disk_free_start_bytes": 30_000_000_000,
                "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000}

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
        if job["scenario"] in TRACED_SCENARIOS:
            (folder / "contracts.json").write_text(json.dumps(covering(plan, job)))

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

        # Then each candidate runs alone through fresh, installer and existing-install scenarios.
        self.assertEqual(set(jobs), {f"p1-{s}.{n}" for s in ("radarr", "sonarr")
                                     for n in ("fresh-install", "install-e2e", "upgrade-path")})
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

        # Then every job declares its own permissions, so none inherits the workflow's.
        self.assertEqual([n for n, job in jobs.items() if "permissions" not in job], [])
        self.assertEqual(jobs["image-drift"]["permissions"], {"contents": "read", "issues": "write"})
        # And image jobs are read-only, bounded and receive no secrets.
        for job in image_jobs:
            self.assertEqual(job["permissions"], {"contents": "read"})
            self.assertEqual(job["runs-on"], "ubuntu-24.04")
            self.assertEqual((job["strategy"]["max-parallel"], job["timeout-minutes"]), (4, 85))
            self.assertNotIn("secrets.", json.dumps(job))
        # And the planner, selector and verifier are read-only too.
        for name in ("preflight-plan", "preflight-select", "preflight-verify"):
            self.assertEqual(jobs[name]["permissions"], {"contents": "read"})
        # And only the separate default-branch publisher can write repository content.
        self.assertIn("github.event.repository.default_branch", publisher["if"])
        self.assertEqual(publisher["permissions"], {"contents": "write", "pull-requests": "write"})
        self.assertNotIn("gh workflow run", json.dumps(publisher))
        self.assertEqual((publisher["env"]["BRANCH"], publisher["env"]["TITLE"]),
                         (publish.BRANCH, publish.TITLE))
        # And the status reporter can only comment and never runs an image job.
        self.assertEqual(report["permissions"], {"issues": "write"})
        self.assertNotIn("hosted_preflight.py run", json.dumps(report))

    def test_report_runs_when_the_plan_fails(self):
        # Given the status job of the workflow.
        workflow = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())
        report = workflow["jobs"]["preflight-report"]

        # When the planner fails and the status job renders its notice.
        text = abort("failure", MAIN)

        # Then the status job does not depend on a successful planner.
        self.assertNotIn("preflight-plan.result", report["if"])
        # And its notice names the planner failure and links the run.
        self.assertIn("the planner failed", text)
        self.assertIn("(https://example.test/run/1)", text)

    def test_partial_rerun_is_refused_with_guidance(self):
        # Given a plan frozen by attempt 1 of a workflow run.
        expected = fingerprint(self.plan)

        # When a job of attempt 2 checks that plan.
        # Then it refuses and tells the operator to re-run all jobs.
        with self.assertRaisesRegex(ValueError, "Re-run all jobs"):
            check_plan(self.plan, SOURCE, "123-2", expected)

    def test_publisher_refuses_foreign_branch_or_pr(self):
        owned = owned_branch()
        foreign_commit = copy.deepcopy(owned)
        foreign_commit["commits"][0]["commit"]["author"]["email"] = "someone@example.com"
        extra_commit = dict(owned, ahead_by=2, commits=owned["commits"] * 2)
        other_file = dict(owned, files=[{"filename": "setup.sh"}])
        human_pr = dict(bot_pr(), user={"login": "someone", "type": "User"})
        closed = bot_pr(merged_at=None)
        for name, prs, compare, gone, why in (
            ("human PR", [human_pr], owned, [], "not opened by"),
            ("foreign commit", [bot_pr()], foreign_commit, [], "did not create"),
            ("extra commit", [bot_pr()], extra_commit, [], "exactly one publisher commit"),
            ("file outside the record", [], other_file, [], "outside the digest record"),
            ("two open PRs", [bot_pr(), bot_pr(10)], owned, [], "more than one open PR"),
            ("PR head behind the branch", [bot_pr(head="c" * 40)], owned, [], "head differs"),
            ("branch of a PR closed unmerged", [], owned, [closed], "delete the branch"),
        ):
            with self.subTest(name):
                # Given a rolling branch or PR that the publisher may not replace.
                facts = publish.Facts(prs, HEAD, compare, "old", gone)

                # When a passing run decides how to publish its lock.
                decision = publish.decide("proposed", [], facts)

                # Then it refuses for that reason and changes nothing.
                self.assertEqual(decision.action, "refuse")
                self.assertIn(why, decision.reason)

    def test_publisher_keeps_one_rolling_pr(self):
        owned, pr = owned_branch(), [bot_pr()]
        lock = lock_line("s", "i@sha256:1")
        restamped = lock.replace("2026-01-01", "2026-02-02")
        merged = [bot_pr(merged_at="2026-01-02T00:00:00Z")]
        for name, proposed, facts, expected in (
            ("first proposal", "new", publish.Facts([], "", {}, None, []), ("create", None, "")),
            ("newer combination", "new", publish.Facts(pr, HEAD, owned, lock, []),
             ("update", 9, HEAD)),
            ("same lock", restamped, publish.Facts(pr, HEAD, owned, lock, []),
             ("unchanged", 9, HEAD)),
            ("nothing accepted", None, publish.Facts(pr, HEAD, owned, lock, []),
             ("keep", 9, HEAD)),
            ("nothing open", None, publish.Facts([], "", {}, None, []), ("none", None, "")),
            ("branch left by a merged PR", "new", publish.Facts([], HEAD, {}, lock, merged),
             ("create", None, HEAD)),
            ("branch whose PR creation failed", "new", publish.Facts([], HEAD, owned, lock, []),
             ("create", None, HEAD)),
        ):
            with self.subTest(name):
                # Given the rolling PR state and this run's proposal.
                # When the publisher decides.
                decision = publish.decide(proposed, [], facts)

                # Then it makes exactly the expected change under a lease on the observed head.
                self.assertEqual((decision.action, decision.pr, decision.lease), expected)

    def test_refused_digest_closes_the_open_pr(self):
        # Given an open PR that proposes the Radarr and Sonarr candidates of this run.
        both, alone = self.phase1(["radarr", "sonarr"]), self.phase1(["sonarr"])
        refs = both["candidates"]
        proposed = lock_line("radarr", refs["radarr"]) + lock_line("sonarr", refs["sonarr"])
        facts = publish.Facts([bot_pr()], HEAD, owned_branch(), proposed, [])
        older = facts._replace(branch_lock=lock_line("sonarr", refs["sonarr"][:-1] + "0"))
        failed = combination_plan(alone, [], {"sonarr": ["upgrade-path"]})
        together = combination_plan(both, ["radarr", "sonarr"], {})
        for name, plan, selection, verified, facts, expected in (
            ("Sonarr failed phase 1", alone, failed, "skipped", facts, ("close", ["sonarr"])),
            ("final verification refused both", both, together, "failure", facts,
             ("close", ["radarr", "sonarr"])),
            ("the PR holds another Sonarr digest", alone, failed, "skipped", older,
             ("keep", [])),
        ):
            with self.subTest(name):
                # When this run accepted nothing and the publisher decides.
                decision = publish.decide(None, publish.rejected(plan, selection, verified), facts)

                # Then it closes the PR only when this run refused one of its exact digests.
                named = [s for s in ("radarr", "sonarr") if s in decision.reason]
                self.assertEqual((decision.action, named), expected)
                self.assertEqual((decision.pr, decision.lease), (9, HEAD))
                # And it never claims that evidence from another run is still valid.
                self.assertNotIn("valid", decision.reason)

    def test_report_names_each_service_outcome(self):
        # Given Radarr failed phase 1, Sonarr was proposed, and two services were not tested.
        plan = self.phase1(["radarr", "sonarr"])
        plan["pending"] = {"bazarr": "subtitle database migration is not covered",
                           "lidarr": "not selected"}
        selection = combination_plan(plan, ["sonarr"], {"radarr": ["upgrade-path"]})
        decided = publish.decide("new", [], publish.Facts([], "", {}, None, []))
        publication = {"outcome": decided.action, "pr": "12", "reason": decided.reason}
        jobs = {"combine": "skipped", "verify": "success", "publish": "success"}

        # When the status report is rendered.
        text = render(plan, selection, jobs, publication, MAIN)

        # Then each service has exactly one visible state.
        self.assertIn("| sonarr | proposed in PR #12 |", text)
        self.assertIn("| radarr | failed in phase 1 (", text)
        self.assertIn("`result-p1-radarr.upgrade-path`", text)
        self.assertIn("| bazarr | held: subtitle database migration is not covered |", text)
        self.assertIn("| lidarr | not selected |", text)
        # And a default-branch run is not marked as a trial.
        self.assertIn("Ref: `refs/heads/main`\n", text)

    def test_report_separates_phase_two_from_final_verification(self):
        # Given Radarr and Sonarr passed phase 1 and the publisher did not run.
        plan = self.phase1(["radarr", "sonarr"])
        selection = combination_plan(plan, ["radarr", "sonarr"], {})
        publication = {"outcome": "", "pr": "", "reason": ""}
        for name, combined, expected in (("phase 2 failed", "failure", "failed in phase 2"),
                                         ("verification refused", "success",
                                          "failed final verification")):
            with self.subTest(name):
                jobs = {"combine": combined, "verify": "failure", "publish": "skipped"}

                # When the report is rendered for a trial branch.
                text = render(plan, selection, jobs, publication, dict(MAIN, ref="refs/heads/x"))

                # Then it names the stage that refused the combination.
                self.assertIn(f"| sonarr | {expected} (", text)
                # And it marks the trial ref so that nobody reads it as a main result.
                self.assertIn("`refs/heads/x` (a trial run", text)

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

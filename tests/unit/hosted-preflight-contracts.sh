#!/usr/bin/env bash
# Hosted preflight wiring of the contract-coverage gate: selection, acceptance
# and both reports read each traced job's contracts.json, and the event export
# keeps no exec command line. Synthetic artifacts; no Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-contracts
if python3 -I - "$REPO_ROOT" <<'PY'; then
import argparse
import contextlib
import io
import json
import pathlib
import re
import sys
import tempfile
import unittest
from collections import Counter

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
sys.path.insert(0, sys.path[0] + "/fixtures")
import hosted_preflight
from contract_evidence import covering
from preflight.contracts import TRACED_SCENARIOS
from preflight.model import (FIXTURES, ROOT, build_plan, drift, effective, fingerprint, rows,
                             source_sha)
from preflight.runner import canonical, job_environment, lifecycle_events
from preflight.status import render
from preflight.verify import (accept, contract_verdict, phase_two_contract_failures,
                              select_combination)

SOURCE = source_sha()
RUN = "123-1"
MAIN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}
NOTHING = {"outcome": "", "pr": "", "reason": ""}
# Where product code runs with MS_CONTRACT_TRACE set: the product command, or
# the named helper that sources product modules. Each count is a call site.
TRACE_HELPERS = {"upgrade_launcher", "ie2e_user_exec", "fresh_install_product_probe"}
EXPECTED_TRACE_SITES = Counter({
    ("assertions/drift.sh", "./scripts/configure.sh --only sonarr,radarr,jellyfin"): 1,
    ("assertions/jackett.sh", "./scripts/configure.sh --only jackett"): 1,
    ("assertions/jellyfin-encoding.sh", "./scripts/configure.sh --only jellyfin"): 6,
    ("assertions/seerr.sh", "./scripts/configure.sh --only seerr"): 2,
    ("assertions/uptime-kuma.sh", "./scripts/configure.sh --only uptime-kuma"): 1,
    ("scenarios/fresh-install.sh", "./scripts/configure.sh"): 1,
    ("scenarios/fresh-install.sh", "fresh_install_product_probe()"): 1,
    ("scenarios/install-e2e.sh", "ie2e_user_exec()"): 1,
    ("scenarios/upgrade-path.sh", "upgrade_launcher()"): 1,
    ("scenarios/upgrade-path.sh", "./scripts/update.sh"): 1,
    ("scenarios/upgrade-path.sh", "./scripts/configure.sh --only "
     "qbittorrent,jackett,sonarr,radarr,jellyfin,seerr"): 1,
    ("scenarios/portainer-upgrade.sh", "./scripts/configure.sh --only portainer"): 1,
    ("scenarios/portainer-upgrade.sh", "./scripts/update.sh"): 1,
})
PRODUCT = re.compile(r"\./(?:scripts/[\w./-]+|setup\.sh|mediastack)\b[^\"'>|&;]*")


def trace_sites(path):
    """Each line that sets MS_CONTRACT_TRACE: its function, and what it runs."""
    function = None
    for line in path.read_text().splitlines():
        defined = re.match(r"(\w+)\(\) \{", line)
        function = defined.group(1) if defined else None if line.startswith("}") else function
        if line.lstrip().startswith("#") or not re.search(r"MS_CONTRACT_TRACE\b", line):
            continue
        product = PRODUCT.search(line)
        if product:
            yield function, product.group().strip()
        elif function in TRACE_HELPERS:
            yield function, function + "()"
        else:
            yield function, "traced, but runs no product command: " + line.strip()


def calls_any(path, functions):
    """Whether a file calls one of ``functions`` that it does not define itself."""
    text = path.read_text()
    own = set(re.findall(r"^(\w+)\(\) \{", text, re.M))
    return any(re.search(rf"\b{name}\b", text) for name in functions - own)


def tracing_scenarios(files):
    """Scenarios with a trace site, or that call another file's function holding one."""
    functions = {function for path in files for function, _ in trace_sites(path) if function}
    return {path.stem for path in files if path.parent.name == "scenarios"
            and (any(trace_sites(path)) or calls_any(path, functions))}


class ContractGate(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = pathlib.Path(temp.name)
        self.results = self.folder / "results"
        self.old = rows(ROOT / "docs/operations/image-digests.lock")
        self.current = dict(self.old)
        for service, digit in (("sonarr", "1"), ("radarr", "4"), ("socket-proxy", "5")):
            prior = self.old[service]
            self.current[service] = drift.ImageDigest(service, prior.image, "sha256:" + digit * 64)
        self.fixtures = {key: ref + "@sha256:" + "2" * 64 for key, ref in FIXTURES.items()}
        self.snapshot = self.folder / "current.tsv"
        drift.write_tsv(self.snapshot, list(self.current.values()))

    def phase1(self, selected):
        return build_plan(self.old, self.current, selected, SOURCE, RUN, self.fixtures)

    def test_fail2ban_candidate_needs_upgrade_path(self):
        # Given a changed fail2ban candidate, whose regex-count exec runs only in update.sh.
        prior = self.old["fail2ban"]
        self.current["fail2ban"] = drift.ImageDigest("fail2ban", prior.image, "sha256:" + "6" * 64)

        # When its phase-1 jobs are planned.
        plan = self.phase1(["fail2ban"])

        # Then it runs exactly drift, fresh-install and upgrade-path.
        self.assertEqual(sorted(job["id"] for job in plan["jobs"]),
                         ["p1-fail2ban.fail2ban-drift", "p1-fail2ban.fresh-install",
                          "p1-fail2ban.upgrade-path"])

    def write(self, plan, job, contracts):
        """Passing job artifacts; ``contracts`` None writes no contracts.json."""
        folder = self.results / ("result-" + job["id"])
        folder.mkdir(parents=True, exist_ok=True)
        refs = effective(plan, job)
        result = {"schema": 1, "plan": fingerprint(plan), "source": SOURCE,
                  "run": RUN, "job": job["id"], "scenario": job["scenario"],
                  "run_id": job["run_id"], "architecture": "x86_64", "rc": 0, "passes": 240,
                  "failures": 0, "skips": 0, "evidence_error": None, "elapsed_seconds": 600,
                  "disk_error": None, "runner_error": None, "disk_samples": 300,
                  "disk_free_start_bytes": 30_000_000_000,
                  "disk_peak_growth_bytes": 13_000_000_000, "disk_growth_bytes": 12_000_000_000}
        data = {"result": result,
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
        if contracts is not None:
            (folder / "contracts.json").write_text(json.dumps(contracts))

    def pass_jobs(self, plan, change=None):
        """Every job passes with covering evidence; ``change`` edits it per job id."""
        for job in plan["jobs"]:
            data = covering(plan, job) if job["scenario"] in TRACED_SCENARIOS else None
            if change and job["id"] in change:
                data = change[job["id"]](data)
            self.write(plan, job, data)

    def test_missing_contracts_fails_the_candidate(self):
        # Given Sonarr's install-e2e job passed but uploaded no contracts.json.
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan, {"p1-sonarr.install-e2e": lambda data: None})

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then Sonarr fails as an image failure, not as undecided.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertIn("sonarr", selection["failed"])
        self.assertNotIn("sonarr", selection["runner_failed"])
        # And the contract report names the job without evidence.
        self.assertEqual(selection["contracts"]["failed"]["sonarr"],
                         ["p1-sonarr.install-e2e: contracts.json is missing or unreadable"])

    def test_phase_one_contract_failure_excludes_the_candidate(self):
        # Given no Sonarr job saw the quality profile items on the candidate.
        plan = self.phase1(["radarr", "sonarr"])

        def without_items(data):
            reads = data["entries"]["sonarr"]["quality-profile-list"]["reads"]
            reads.remove("items[].quality.id")
            return data

        self.pass_jobs(plan, {job["id"]: without_items for job in plan["jobs"]
                              if job["combination"] == ["sonarr"]
                              and job["scenario"] in TRACED_SCENARIOS})

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then only Radarr continues, and Sonarr failed every scenario it was judged on.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertEqual(selection["failed"]["sonarr"],
                         ["fresh-install", "install-e2e", "upgrade-path"])
        # And the status report names the exact entry and read.
        text = render(plan, selection, {"combine": "success", "verify": "success",
                                        "publish": "skipped"}, NOTHING, MAIN)
        self.assertIn("`sonarr quality-profile-list: missing reads items[].quality.id`", text)

    def test_an_entry_covered_only_by_the_union_of_jobs_passes(self):
        # Given Sonarr's notification test ran only in upgrade-path, and the
        # profile items were read only in install-e2e.
        plan = self.phase1(["sonarr"])

        def drop(entry=None, read=None):
            def change(data):
                item = data["entries"]["sonarr"]["quality-profile-list"]
                if read:
                    item["reads"].remove(read)
                if entry:
                    del data["entries"]["sonarr"][entry]
                return data
            return change

        self.pass_jobs(plan, {
            "p1-sonarr.fresh-install": drop("notification-test", "items[].quality.id"),
            "p1-sonarr.install-e2e": drop("notification-test"),
            "p1-sonarr.upgrade-path": drop(read="items[].quality.id"),
        })

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then Sonarr passes, because coverage is the union over its jobs.
        self.assertEqual(selection["selected"], ["sonarr"])
        self.assertEqual(selection["contracts"]["failed"], {})

    def refused_phase_two(self):
        """Radarr and Sonarr passed phase 1 alone; together Radarr's root folder list is 404."""
        plan = self.phase1(["radarr", "sonarr"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        self.assertEqual(selection["authority"], "phase-2")

        def not_found(data):
            if "radarr" in data["entries"]:
                data["entries"]["radarr"]["root-folder-list"]["candidate"] = {"404": 1}
            return data

        self.pass_jobs(selection, {job["id"]: not_found for job in selection["jobs"]})
        return plan, selection

    def test_phase_two_contract_failure_blocks_acceptance(self):
        # Given both candidates passed phase 1 alone.
        # And together, Radarr's root folder list returned 404 in every phase-2 job.
        plan, selection = self.refused_phase_two()
        output = self.folder / "accepted"

        # When final verification judges the combination.
        # Then it refuses and names the entry and what was seen.
        with self.assertRaisesRegex(ValueError, "radarr root-folder-list: not exercised on "
                                    "candidate \\(seen 404×1 in fresh-install"):
            accept(plan, selection, self.snapshot, self.results, output)
        # And it writes no lock.
        self.assertFalse(output.exists())
        # And the status report names the failed entry for the refused combination.
        jobs = {"combine": "success", "verify": "failure", "publish": "skipped"}
        failures = phase_two_contract_failures(selection, self.results)
        text = render(plan, selection, jobs, NOTHING, MAIN, contract=failures)
        self.assertIn("| radarr | failed final verification (", text)
        self.assertIn("`radarr root-folder-list: not exercised on candidate", text)

    def test_report_command_names_phase_two_contract_failures(self):
        # Given a phase-2 combination that final verification refused for a contract failure.
        plan, selection = self.refused_phase_two()
        files = {}
        for name, value in (("plan", plan), ("selection", selection)):
            files[name] = self.folder / (name + ".json")
            files[name].write_text(json.dumps(value))
        args = argparse.Namespace(
            plan=files["plan"], selection=files["selection"], results=self.results,
            hash=fingerprint(plan), selection_hash=fingerprint(selection), source=SOURCE,
            run=RUN, combined="success", verified="failure", publish_result="skipped",
            outcome="", pr="", reason="", run_url=MAIN["url"], ref=MAIN["ref"],
            default_branch=MAIN["default_branch"])

        # When the report command renders the run status.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            hosted_preflight.report(args)

        # Then Radarr's row names the failed entry.
        self.assertRegex(out.getvalue(), r"\| radarr \| failed final verification \(.*; contract: "
                         r"`radarr root-folder-list: not exercised on candidate \(seen 404")

    def test_job_problems_fail_every_candidate_the_job_ran(self):
        # Given Radarr and socket-proxy passed phase 1 alone.
        plan = self.phase1(["radarr", "socket-proxy"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        # And the phase-2 upgrade-path job, which proves only Radarr but runs
        # both candidates, uploaded no contracts.json.
        self.pass_jobs(selection, {"p2-upgrade-path": lambda data: None})

        # When the report reads the phase-2 contract evidence.
        failures = phase_two_contract_failures(selection, self.results)

        # Then socket-proxy fails too, because its candidate ran in that job.
        self.assertEqual(failures["socket-proxy"],
                         ["p2-upgrade-path: contracts.json is missing or unreadable"])

    def test_a_service_with_entries_but_no_traced_job_fails(self):
        # Given Sonarr, which has contract entries, judged only on untraced jobs.
        plan = self.phase1(["sonarr"])
        jobs = [dict(job, scenario="ddns-seed") for job in plan["jobs"]]

        # When the contract verdict judges those jobs.
        report = contract_verdict(plan, jobs, self.results, ["sonarr"])

        # Then Sonarr fails for lack of evidence, and is not reported as uncovered.
        self.assertEqual(report["failed"], {"sonarr": ["sonarr: no qualifying contract evidence"]})
        self.assertEqual(report["uncovered"], [])

    def test_unsafe_unlisted_path_is_filtered(self):
        # Given Radarr's fresh-install job made an unlisted call whose path carries markup.
        plan = self.phase1(["radarr"])

        def unlisted(data):
            data["unmatched"]["radarr GET /api/v3/`id`|<b>x</b>"] = {"candidate": 1, "other": 0}
            return data

        self.pass_jobs(plan, {"p1-radarr.fresh-install": unlisted})

        # When the selection job reads the phase-1 results.
        selection = select_combination(plan, self.results)

        # Then the message keeps the path with each unsafe character replaced.
        self.assertEqual(selection["contracts"]["failed"]["radarr"],
                         ["radarr GET /api/v3/?id???b?x?/b?: unlisted call (fresh-install)"])

    def test_contract_messages_are_capped_per_service(self):
        # Given Radarr's fresh-install job made 25 different unlisted calls.
        plan = self.phase1(["radarr"])

        def unlisted(data):
            for number in range(25):
                data["unmatched"][f"radarr GET /api/v3/extra{number:02d}"] = {
                    "candidate": 1, "other": 0}
            return data

        self.pass_jobs(plan, {"p1-radarr.fresh-install": unlisted})

        # When the selection job reads the phase-1 results.
        messages = select_combination(plan, self.results)["contracts"]["failed"]["radarr"]

        # Then 20 messages are kept, and the last line says that more were omitted.
        self.assertEqual(len(messages), 21)
        self.assertEqual(messages[19], "radarr GET /api/v3/extra19: unlisted call (fresh-install)")
        self.assertEqual(messages[20], "further contract failures omitted; see the artifacts")

    def test_digest_pr_body_lists_the_exempt_entries(self):
        # Given Radarr passed every job alone.
        plan = self.phase1(["radarr"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        output = self.folder / "accepted"

        # When the verifier accepts it.
        accept(plan, selection, self.snapshot, self.results, output)

        # Then the digest PR body lists Radarr's exempt entries with their reasons.
        self.assertIn("- Exempt contract entries, not exercised by the image jobs: radarr: "
                      "quality-profile-get (launcher-menu), notification-update (launcher-menu)\n",
                      (output / "body.md").read_text())

    def test_an_exercised_exemption_is_reported_stale(self):
        # Given Radarr's fresh-install job did update a notification on the candidate.
        plan = self.phase1(["radarr"])

        def exercised(data):
            data["entries"]["radarr"]["notification-update"] = {
                "candidate": {"202": 1}, "other": {}, "reads": []}
            return data

        self.pass_jobs(plan, {"p1-radarr.fresh-install": exercised})

        # When the selection job judges it and the status report renders.
        selection = select_combination(plan, self.results)
        text = render(plan, selection, {"combine": "skipped", "verify": "success",
                                        "publish": "skipped"}, NOTHING, MAIN)

        # Then Radarr still passes, and the report lists the exemption as stale.
        self.assertEqual(selection["selected"], ["radarr"])
        self.assertIn("- Stale exemptions, exercised on the candidate: radarr "
                      "notification-update: exempt as launcher-menu but exercised on candidate "
                      "in fresh-install\n", text)

    def test_traced_job_writes_evidence_for_its_own_candidates(self):
        # Given a phase-1 plan with two candidates.
        plan = self.phase1(["radarr", "sonarr"])
        job = next(job for job in plan["jobs"] if job["id"] == "p1-sonarr.fresh-install")

        # When the runner builds the environment of Sonarr's fresh-install job.
        env = job_environment(plan, job, "ms-hosted-unit", self.folder / "out")

        # Then the scenario writes contracts.json into the job's artifact folder.
        self.assertEqual(env["MS_CONTRACTS_FILE"], str(self.folder / "out" / "contracts.json"))
        # And the evidence names only Sonarr's candidate, not Radarr's or the companions.
        self.assertEqual(env["MS_CONTRACT_CANDIDATES"], "sonarr=" + plan["candidates"]["sonarr"])

    def test_untraced_job_writes_no_evidence(self):
        # Given socket-proxy's autoheal job, a scenario that traces nothing.
        plan = self.phase1(["socket-proxy"])
        job = next(job for job in plan["jobs"] if job["scenario"] == "autoheal")

        # When the runner builds the environment of that job.
        env = job_environment(plan, job, "ms-hosted-unit", self.folder / "out")

        # Then contract capture is off.
        self.assertNotIn("MS_CONTRACTS_FILE", env)
        self.assertNotIn("MS_CONTRACT_CANDIDATES", env)

    def test_a_service_without_entries_is_reported(self):
        # Given socket-proxy, which has no contract entries, passed every job alone.
        plan = self.phase1(["socket-proxy"])
        self.pass_jobs(plan)
        selection = select_combination(plan, self.results)
        output = self.folder / "accepted"

        # When the verifier accepts it.
        accept(plan, selection, self.snapshot, self.results, output)

        # Then the digest PR body says its acceptance rests on its scenarios.
        body = (output / "body.md").read_text()
        self.assertIn("- No contract entries: socket-proxy: no contract entries; acceptance "
                      "rests on its scenarios", body)
        # And the status report lists it too.
        text = render(plan, selection, {"combine": "skipped", "verify": "success",
                                        "publish": "skipped"}, NOTHING, MAIN)
        self.assertIn("socket-proxy: no contract entries", text)

    def test_tracing_is_set_only_on_the_expected_product_commands(self):
        # Given every scenario and assertion file.
        files = [*(ROOT / "tests/scenarios").glob("*.sh"), *(ROOT / "tests/assertions").glob("*.sh")]

        # When each line that sets MS_CONTRACT_TRACE is named by what it runs.
        sites = Counter((str(path.relative_to(ROOT / "tests")), site)
                        for path in files for _, site in trace_sites(path))

        # Then tracing covers exactly the expected product commands and helpers,
        # so no product call goes untraced and no assertion request is traced.
        self.assertEqual(sites, EXPECTED_TRACE_SITES)

    def test_traced_scenarios_are_the_scenarios_that_trace(self):
        # Given the scenarios that set MS_CONTRACT_TRACE, themselves or through
        # an assertion they call.
        tracing = tracing_scenarios([*(ROOT / "tests/scenarios").glob("*.sh"),
                                     *(ROOT / "tests/assertions").glob("*.sh")])

        # When the verifier decides which jobs must carry contract evidence.
        # Then it expects evidence from exactly those scenarios.
        self.assertEqual(tracing, set(TRACED_SCENARIOS))

    def test_event_export_keeps_no_exec_argv(self):
        # Given docker events for an exec whose command line carries a password.
        secret = "hub-password-0123456789"
        actor = {"ID": "c1", "Attributes": {"com.docker.compose.service": "beszel",
                                            "image": "henrygd/beszel:latest", "execID": "e1"}}
        raw = "\n".join(json.dumps({"Type": "container", "Action": action, "Actor": actor})
                        for action in ("start", f"exec_create: /beszel superuser upsert a@b {secret}",
                                       f"exec_start: /beszel superuser upsert a@b {secret}",
                                       "health_status: healthy"))

        # When the runner reduces them for events.json.
        events = lifecycle_events(raw)

        # Then only the bare lifecycle actions remain.
        self.assertEqual([event["action"] for event in events],
                         ["start", "exec_create", "exec_start", "health_status"])
        # And the password appears nowhere in the artifact bytes.
        self.assertNotIn(secret.encode(), canonical(events))


unittest.main()
PY
    pass 'hosted preflight judges contract evidence and exports no exec argv'
else
    fail 'hosted preflight judges contract evidence and exports no exec argv'
fi
summary

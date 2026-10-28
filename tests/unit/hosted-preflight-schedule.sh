#!/usr/bin/env bash
# The scheduled image preflight: which jobs each trigger runs, how preflights
# queue, and the bounds of the image jobs. It reads the workflow and runs only
# its mode step; no Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-schedule
if python3 -I - "$REPO_ROOT" <<'PY'; then
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = pathlib.Path(sys.argv.pop())
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/image-drift.yml").read_text())
JOBS = WORKFLOW["jobs"]
CRONS = [entry["cron"] for entry in WORKFLOW[True]["schedule"]]  # PyYAML reads "on" as True.
ALERT = {"mode", "image-drift"}
PREFLIGHT = {"mode", "preflight-plan", "preflight-isolate", "preflight-select", "preflight-combine",
             "preflight-verify", "preflight-publish", "preflight-report"}
# Outputs of a successful run with two candidates, so that every later phase runs.
OUTPUTS = {"preflight-plan": {"has_work": "true"},
           "preflight-select": {"has_work": "true", "authority": "phase-2"}}
STATUS_CHECK = re.compile(r"\b(?:always|cancelled|failure|success)\(\)")


class Context(dict):
    """A GitHub context: a missing property reads as null, like in an expression."""

    def __getattr__(self, name):
        value = self.get(name)
        return Context(value) if isinstance(value, dict) else value


def evaluate(expression, context, needs=None):
    """Evaluate the subset of GitHub expression syntax that this workflow uses."""
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    text = re.sub(r"needs\.([\w-]+)\.(result|outputs\.\w+)",
                  lambda m: f"need({m.group(1)!r}, {m.group(2)!r})", text)
    text = re.sub(r"!(?!=)", " not ", text.replace("&&", " and ").replace("||", " or "))

    def need(job, field):
        state = (needs or {})[job]
        return state["result"] if field == "result" else state["outputs"].get(field[8:], "")

    names = {"need": need, "github": Context(context["github"]), "inputs": Context(context["inputs"]),
             "cancelled": lambda: False, "format": lambda text, *args: text.format(*args)}
    return eval(text, {"__builtins__": {}}, names)


def rendered(expression, context):
    """A value as GitHub writes it into a step environment."""
    if not str(expression).startswith("${{"):
        return str(expression)
    value = evaluate(expression, context)
    return "" if value is None else str(value).lower() if isinstance(value, bool) else str(value)


def resolve(context):
    """Run the real mode step with the environment GitHub would give it."""
    step = next(s for s in JOBS["mode"]["steps"] if s.get("id") == "resolve")
    with tempfile.TemporaryDirectory() as folder:
        output = pathlib.Path(folder) / "output"
        output.touch()
        env = {name: rendered(value, context) for name, value in step["env"].items()}
        env.update(PATH=os.environ["PATH"], GITHUB_OUTPUT=str(output))
        proc = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                              env=env, capture_output=True, text=True, check=False)
        pairs = (line.split("=", 1) for line in output.read_text().splitlines())
        return ("success" if proc.returncode == 0 else "failure"), dict(pairs)


def simulate(context):
    """Map each job to its result, from the needs and if conditions of the workflow."""
    results = {}
    while len(results) < len(JOBS):
        ready = [n for n, job in JOBS.items() if n not in results
                 and all(need in results for need in as_list(job.get("needs", [])))]
        if not ready:
            raise AssertionError("the needs of the workflow form a cycle")
        for name in ready:
            job = JOBS[name]
            condition = job.get("if")
            # Without a status check, GitHub requires that every needed job succeeded.
            needs_met = all(results[n]["result"] == "success" for n in as_list(job.get("needs", [])))
            gate = needs_met or bool(STATUS_CHECK.search(str(condition)))
            if not (gate and (condition is None or evaluate(condition, context, results))):
                results[name] = {"result": "skipped", "outputs": {}}
            elif name == "mode":
                result, outputs = resolve(context)
                results[name] = {"result": result, "outputs": outputs}
            else:
                results[name] = {"result": "success", "outputs": OUTPUTS.get(name, {})}
    return {name: state["result"] for name, state in results.items()}


def ran(context):
    return {name for name, result in simulate(context).items() if result != "skipped"}


def as_list(value):
    return [value] if isinstance(value, str) else value


def github(event, ref="refs/heads/main", run_id="100", **fields):
    return {"event_name": event, "ref": ref, "run_id": run_id,
            "event": dict(fields, repository={"default_branch": "main"})}


def scheduled(cron, run_id="100"):
    return {"github": github("schedule", run_id=run_id, schedule=cron), "inputs": {}}


def dispatched(preflight, publish, ref="refs/heads/main", run_id="200"):
    inputs = {"preflight": preflight, "publish": publish, "services": ""}
    return {"github": github("workflow_dispatch", ref, run_id, inputs=inputs), "inputs": inputs}


class ScheduledPreflight(unittest.TestCase):
    def test_each_cron_runs_the_alert_or_the_publishing_preflight(self):
        # Given the two crons of the schedule trigger.
        self.assertEqual(len(CRONS), 2)

        # When a scheduled run of each cron is simulated.
        jobs = [ran(scheduled(cron)) for cron in CRONS]

        # Then one cron runs only the alert.
        # And the other runs every preflight job, including the publisher.
        self.assertCountEqual(jobs, [ALERT, PREFLIGHT])

    def test_an_unmapped_cron_fails_and_runs_nothing(self):
        # Given a scheduled run whose cron the mode step does not know.
        context = scheduled("0 0 * * 0")

        # When the run is simulated.
        results = simulate(context)

        # Then the mode job fails and every other job is skipped.
        self.assertEqual(results.pop("mode"), "failure")
        self.assertEqual(set(results.values()), {"skipped"})

    def test_dispatch_inputs_select_the_task(self):
        cases = (((False, True), ALERT), ((True, False), PREFLIGHT - {"preflight-publish"}),
                 ((True, True), PREFLIGHT))
        for (preflight, publish), expected in cases:
            with self.subTest(preflight=preflight, publish=publish):
                # Given a manual dispatch on the default branch with these inputs.
                context = dispatched(preflight, publish)

                # When the run is simulated.
                jobs = ran(context)

                # Then the preflight runs only when it was requested, and publishes only on request.
                self.assertEqual(jobs, expected)

    def test_publisher_runs_only_on_the_default_branch(self):
        # Given a publishing preflight dispatched on a feature branch.
        context = dispatched(True, True, ref="refs/heads/feat/trial")

        # When the run is simulated.
        jobs = ran(context)

        # Then every preflight job runs except the publisher.
        self.assertEqual(jobs, PREFLIGHT - {"preflight-publish"})

    def test_preflights_share_one_group_that_does_not_cancel(self):
        # Given every kind of trigger, each with its own run ID.
        contexts = [scheduled(cron, run_id=str(i)) for i, cron in enumerate(CRONS)]
        contexts += [dispatched(p, u, run_id=str(10 + i))
                     for i, (p, u) in enumerate(((False, False), (True, False), (True, True)))]
        concurrency = WORKFLOW["concurrency"]

        # When the group of each run and the task of its mode step are resolved.
        groups = {"alert": [], "preflight": []}
        for context in contexts:
            groups[resolve(context)[1]["task"]].append(evaluate(concurrency["group"], context))

        # Then a group never cancels the run in progress.
        self.assertIs(concurrency["cancel-in-progress"], False)
        # And every preflight, scheduled or dispatched, is in one group.
        self.assertEqual(len(groups["preflight"]), 3)
        self.assertEqual(len(set(groups["preflight"])), 1)
        # And each alert has a group of its own, so it never waits for a preflight.
        self.assertEqual(len(set(groups["alert"])), 2)
        self.assertNotIn(groups["preflight"][0], groups["alert"])
        # And the publisher's job-level group is a different group.
        self.assertNotEqual(JOBS["preflight-publish"]["concurrency"]["group"], groups["preflight"][0])

    def test_image_jobs_keep_their_bounds(self):
        # Given every job that runs a candidate image.
        image_jobs = {name: job for name, job in JOBS.items()
                      if any("hosted_preflight.py run" in str(s.get("run", "")) for s in job["steps"])}
        self.assertEqual(set(image_jobs), {"preflight-isolate", "preflight-combine"})

        for name, job in image_jobs.items():
            with self.subTest(name):
                # When its permissions, concurrency and timeout are read.
                parallel, timeout = job["strategy"]["max-parallel"], job["timeout-minutes"]

                # Then it can only read the repository.
                self.assertEqual(job["permissions"], {"contents": "read"})
                # And at most four of its jobs run at a time.
                self.assertTrue(isinstance(parallel, int) and 1 <= parallel <= 4, parallel)
                # And each job ends within 85 minutes.
                self.assertTrue(isinstance(timeout, int) and 1 <= timeout <= 85, timeout)


unittest.main()
PY
    pass 'scheduled preflight resolves its task, queues and keeps image jobs bounded'
else
    fail 'scheduled preflight resolves its task, queues and keeps image jobs bounded'
fi
summary

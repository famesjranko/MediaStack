#!/usr/bin/env bash
# The scheduled image preflight: which jobs each trigger and each job outcome
# runs, how preflights queue, and the bounds of the image and publisher jobs.
# It reads the workflow and runs only its mode step; no Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-schedule
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
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
# Outputs of a successful run with three candidates, so that every later phase runs.
OUTPUTS = {"preflight-plan": {"has_work": "true"},
           "preflight-select": {"has_work": "true", "authority": "phase-2"}}
STATUS_FUNCTIONS = {"always", "cancelled", "failure", "success"}
# Every token of the expression subset that this workflow uses; anything else fails loudly.
TOKEN = re.compile(r"\s*(?:(?P<string>'(?:[^']|'')*')|(?P<op>&&|\|\||==|!=|!|\(|\)|,)"
                   r"|(?P<name>[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*))")


def tokenize(text):
    found, pos, text = [], 0, text.strip()
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match:
            raise SyntaxError(f"unsupported expression syntax at {text[pos:]!r}")
        found.append((match.lastgroup, match.group(match.lastgroup)))
        pos = match.end()
    return found


def truthy(value):
    return bool(value) and value == value  # NaN is falsy in GitHub expressions.


def number(value):
    if value is None or isinstance(value, bool):
        return int(bool(value))
    try:
        return float(value) if value.strip() else 0
    except ValueError:
        return float("nan")


def equal(left, right):
    """GitHub ==: strings compare without case; mixed types compare as numbers."""
    if isinstance(left, str) and isinstance(right, str):
        return left.casefold() == right.casefold()
    return left == right if type(left) is type(right) else number(left) == number(right)


class Expression:
    """A recursive-descent evaluator for the GitHub expression subset of this workflow.

    It evaluates every operand, so that a read of an undeclared job fails even
    where GitHub would short-circuit.
    """

    def __init__(self, text, scope):
        self.tokens, self.pos, self.scope = tokenize(text), 0, scope

    def value(self):
        result = self.either()
        if self.pos != len(self.tokens):
            raise SyntaxError(f"unexpected token {self.tokens[self.pos][1]!r}")
        return result

    def take(self, op):
        if self.pos < len(self.tokens) and self.tokens[self.pos] == ("op", op):
            self.pos += 1
            return True
        return False

    def either(self):
        left = self.both()
        while self.take("||"):
            right = self.both()
            left = left if truthy(left) else right
        return left

    def both(self):
        left = self.comparison()
        while self.take("&&"):
            right = self.comparison()
            left = right if truthy(left) else left
        return left

    def comparison(self):
        left = self.unary()
        for op, same in (("==", True), ("!=", False)):
            if self.take(op):
                return equal(left, self.unary()) is same
        return left

    def unary(self):
        return not truthy(self.unary()) if self.take("!") else self.primary()

    def primary(self):
        if self.take("("):
            inner = self.either()
            if not self.take(")"):
                raise SyntaxError("missing )")
            return inner
        kind, text = self.tokens[self.pos]
        self.pos += 1
        if kind == "string":
            return text[1:-1].replace("''", "'")
        if kind != "name":
            raise SyntaxError(f"unexpected token {text!r}")
        if not self.take("("):
            return self.scope.read(text)
        args = []
        while not self.take(")"):
            args.append(self.either())
            self.take(",")
        return self.scope.call(text, args)


class Scope:
    """The contexts of one job: github, inputs, and only the needs that it declares."""

    def __init__(self, context, needs=None, ancestors=()):
        self.context, self.needs, self.ancestors = context, needs or {}, list(ancestors)

    def read(self, path):
        literals = {"true": True, "false": False, "null": None}
        if path in literals:
            return literals[path]
        root, *keys = path.split(".")
        if root == "needs":
            if keys[0] not in self.needs:
                raise AssertionError(f"needs.{keys[0]} is read but not declared in needs")
            value, keys = self.needs[keys[0]], keys[1:]
        elif root in ("github", "inputs"):
            value = self.context[root]
        else:
            raise SyntaxError(f"unsupported context {root!r}")
        for key in keys:
            value = value.get(key) if isinstance(value, dict) else None
        return value

    def call(self, name, args):
        # Status functions see every ancestor job, not only the direct needs.
        ended = [state["result"] for state in self.ancestors]
        functions = {
            "always": lambda: True,
            "cancelled": lambda: False,
            "failure": lambda: "failure" in ended,
            "success": lambda: (all(s["result"] == "success" for s in self.needs.values())
                                and "failure" not in ended and "cancelled" not in ended),
            "format": lambda text, *values: text.format(*values),
        }
        if name not in functions:
            raise SyntaxError(f"unsupported function {name}()")
        return functions[name](*args)


def unwrap(expression):
    text = str(expression).strip()
    return text[3:-2] if text.startswith("${{") and text.endswith("}}") else text


def evaluate(expression, context, needs=None, ancestors=()):
    return Expression(unwrap(expression), Scope(context, needs, ancestors)).value()


def job_runs(job, context, needs, ancestors):
    """GitHub adds success() to a job condition that calls no status function."""
    condition = unwrap(job.get("if", "success()"))
    if not {text for kind, text in tokenize(condition) if kind == "name"} & STATUS_FUNCTIONS:
        condition = f"success() && ({condition})"
    return truthy(evaluate(condition, context, needs, ancestors))


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


def as_list(value):
    return [value] if isinstance(value, str) else value


def ancestors_of(name):
    found, pending = [], list(as_list(JOBS[name].get("needs", [])))
    while pending:
        job = pending.pop()
        if job not in found:
            found.append(job)
            pending += as_list(JOBS[job].get("needs", []))
    return found


def simulate(context, overrides=None):
    """Map each job to its result, from the needs and if conditions of the workflow.

    A job that runs succeeds with OUTPUTS, unless ``overrides`` gives it
    another result or other outputs.
    """
    results = {}
    while len(results) < len(JOBS):
        ready = [n for n, job in JOBS.items() if n not in results
                 and all(need in results for need in as_list(job.get("needs", [])))]
        if not ready:
            raise AssertionError("the needs of the workflow form a cycle")
        for name in ready:
            needs = {n: results[n] for n in as_list(JOBS[name].get("needs", []))}
            ancestors = [results[n] for n in ancestors_of(name)]
            override = (overrides or {}).get(name, {})
            if not job_runs(JOBS[name], context, needs, ancestors):
                results[name] = {"result": "skipped", "outputs": {}}
            elif name == "mode":
                result, outputs = resolve(context)
                results[name] = {"result": result, "outputs": outputs}
            else:
                outputs = dict(OUTPUTS.get(name, {}), **override.get("outputs", {}))
                results[name] = {"result": override.get("result", "success"), "outputs": outputs}
    return {name: state["result"] for name, state in results.items()}


def ran(context, overrides=None):
    return {name for name, result in simulate(context, overrides).items() if result != "skipped"}


def github(event, ref="refs/heads/main", run_id="100", **fields):
    return {"event_name": event, "ref": ref, "run_id": run_id,
            "event": dict(fields, repository={"default_branch": "main"})}


def scheduled(cron, run_id="100"):
    return {"github": github("schedule", run_id=run_id, schedule=cron), "inputs": {}}


def dispatched(preflight, publish, ref="refs/heads/main", run_id="200"):
    inputs = {"preflight": preflight, "publish": publish, "services": ""}
    # The inputs context keeps boolean types. github.event.inputs holds strings,
    # as GitHub passes them, so "false" is truthy there.
    event = {name: str(value).lower() if isinstance(value, bool) else value
             for name, value in inputs.items()}
    return {"github": github("workflow_dispatch", ref, run_id, inputs=event), "inputs": inputs}


WEEKLY = scheduled(CRONS[1])


class ScheduledPreflight(unittest.TestCase):
    def test_each_cron_runs_the_alert_or_the_publishing_preflight(self):
        # Given the two crons of the schedule trigger.
        self.assertEqual(len(CRONS), 2)

        # When a scheduled run of each cron is simulated.
        jobs = [ran(scheduled(cron)) for cron in CRONS]

        # Then one cron runs only the alert.
        # And the other runs every preflight job, including the publisher.
        self.assertEqual(jobs, [ALERT, PREFLIGHT])

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

    def test_one_failed_phase_one_job_does_not_stop_the_others(self):
        # Given one of three phase-1 jobs failed, and the two that passed form phase 2.
        overrides = {"preflight-isolate": {"result": "failure"}}

        # When the weekly preflight is simulated.
        jobs = ran(WEEKLY, overrides)

        # Then the selection, phase 2, verification, publisher and report still run.
        self.assertEqual(jobs, PREFLIGHT)

    def test_a_plan_without_work_runs_no_image_job(self):
        # Given a planner that found no drifted service to test.
        overrides = {"preflight-plan": {"outputs": {"has_work": "false"}}}

        # When the weekly preflight is simulated.
        jobs = ran(WEEKLY, overrides)

        # Then no image job, selection or publication runs.
        # And the report still runs.
        self.assertEqual(jobs, {"mode", "preflight-plan", "preflight-report"})

    def test_a_failed_planner_still_posts_the_report(self):
        # Given a planner that failed, for example on a registry outage.
        overrides = {"preflight-plan": {"result": "failure", "outputs": {"has_work": ""}}}

        # When the weekly preflight is simulated.
        jobs = ran(WEEKLY, overrides)

        # Then only the report runs after the planner.
        self.assertEqual(jobs, {"mode", "preflight-plan", "preflight-report"})

    def test_a_failed_phase_two_publishes_nothing_and_reports(self):
        # Given phase 2 failed for the combination that passed phase 1.
        overrides = {"preflight-combine": {"result": "failure"}}

        # When the weekly preflight is simulated.
        jobs = ran(WEEKLY, overrides)

        # Then final verification does not run, so no lock is accepted.
        # And the publisher runs to keep or close the open PR, and the report runs.
        self.assertEqual(jobs, PREFLIGHT - {"preflight-verify"})

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

    def test_unsupported_expression_syntax_fails_loudly(self):
        for expression in ("needs.mode.outputs.task == 'x' && __import__('os')",
                           "github.event_name[0] == 's'", "toJSON(github)"):
            with self.subTest(expression):
                # Given an expression outside the supported subset.
                # When it is evaluated.
                # Then the simulator refuses it instead of guessing.
                with self.assertRaises(SyntaxError):
                    evaluate(expression, WEEKLY, {"mode": {"result": "success", "outputs": {}}})

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

    def test_publisher_never_merges_or_approves(self):
        # Given the publisher job, the only job with write access to pull requests.
        publisher = json.dumps(JOBS["preflight-publish"])

        # When its steps are searched for merge and review commands and API paths.
        found = re.findall(r"pr\s+merge|pr\s+review|--approve|/merge\b|pulls/[^\s\"']*/reviews",
                           publisher)

        # Then it contains none: a person reviews and merges every digest PR.
        self.assertEqual(found, [])


unittest.main()
PY
    pass 'scheduled preflight resolves its task, survives job failures and keeps jobs bounded'
else
    fail 'scheduled preflight resolves its task, survives job failures and keeps jobs bounded'
fi
summary

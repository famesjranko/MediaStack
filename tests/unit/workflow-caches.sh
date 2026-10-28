#!/usr/bin/env bash
# Workflows restore no Actions cache: a forged cache entry from a privileged
# image job could overwrite verifier scripts in other runs. See the no-cache
# note in .github/workflows/ci.yml. No Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin workflow-caches
if python3 -I - "$REPO_ROOT" <<'PY'; then
import pathlib
import subprocess
import sys
import unittest

import yaml

ROOT = pathlib.Path(sys.argv.pop())
# An allowlist, not a denylist: many actions cache by default (setup-go,
# setup-node, build-push-action with type=gha), and a local composite action
# or reusable workflow hides its steps from this check. Adding an action here
# needs a review of its cache behavior at the pinned commit.
CACHE_FREE = {"actions/checkout", "actions/upload-artifact", "actions/download-artifact"}
# setup-uv defaults to enable-cache: "auto", which caches on hosted runners.
NEEDS_CACHE_OFF = {"astral-sh/setup-uv"}


def violations(workflow):
    found = []
    for job_name, job in (workflow.get("jobs") or {}).items():
        if "uses" in job:
            found.append(f"{job_name}: calls reusable workflow {job['uses']}")
        for step in job.get("steps") or []:
            if "uses" not in step:
                continue
            uses = str(step["uses"])
            action = uses.split("@")[0]
            label = f"{job_name}: {step.get('name') or uses}"
            if action in NEEDS_CACHE_OFF:
                if (step.get("with") or {}).get("enable-cache") is not False:
                    found.append(f"{label} leaves the {action} cache on")
            elif action not in CACHE_FREE:
                found.append(f"{label} uses an action outside the cache-free allowlist")
    return found


def step(uses, **inputs):
    return {"jobs": {"build": {"steps": [{"uses": uses, "with": inputs}]}}}


class WorkflowCaches(unittest.TestCase):
    def test_repository_workflows_restore_no_cache(self):
        # Given every tracked workflow file.
        listed = subprocess.check_output(
            ["git", "ls-files", ".github/workflows/*.yml", ".github/workflows/*.yaml"],
            cwd=ROOT, text=True,
        ).split()
        self.assertTrue(listed, "no workflow files found")

        # When each workflow is checked for cache use.
        found = [v for name in listed for v in violations(yaml.safe_load((ROOT / name).read_text()))]

        # Then every action is cache-free or has its cache turned off.
        self.assertEqual(found, [])

    def test_actions_cache_step_is_rejected(self):
        # Given a step that restores a pinned tool directory from actions/cache.
        workflow = step("actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830", path="~/.cache/x", key="k")

        # When the workflow is checked.
        found = violations(workflow)

        # Then the step is reported.
        self.assertEqual(len(found), 1)
        self.assertIn("outside the cache-free allowlist", found[0])

    def test_setup_uv_default_cache_is_rejected(self):
        # Given setup-uv without an explicit enable-cache: false.
        workflow = step("astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b", version="0.11.31")

        # When the workflow is checked.
        found = violations(workflow)

        # Then its default hosted-runner cache is reported.
        self.assertEqual(found, ["build: astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b leaves the astral-sh/setup-uv cache on"])

    def test_default_caching_action_is_rejected(self):
        # Given setup-go, which caches by default with no cache input set.
        workflow = step("actions/setup-go@v5", **{"go-version": "1.23"})

        # When the workflow is checked.
        found = violations(workflow)

        # Then the action is reported because it is not on the allowlist.
        self.assertEqual(found, ["build: actions/setup-go@v5 uses an action outside the cache-free allowlist"])

    def test_local_action_and_reusable_workflow_are_rejected(self):
        # Given a local composite action and a reusable workflow call.
        workflow = step("./.github/actions/setup")
        workflow["jobs"]["shared"] = {"uses": "./.github/workflows/shared.yml"}

        # When the workflow is checked.
        found = violations(workflow)

        # Then both are reported, because their steps are hidden from this check.
        self.assertEqual(found, [
            "build: ./.github/actions/setup uses an action outside the cache-free allowlist",
            "shared: calls reusable workflow ./.github/workflows/shared.yml",
        ])


unittest.main()
PY
    pass 'workflows restore no Actions cache'
else
    fail 'workflows restore no Actions cache'
fi
summary

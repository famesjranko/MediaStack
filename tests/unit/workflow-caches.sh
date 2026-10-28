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
# Inputs that turn on an action's built-in cache (setup-python/node/go use
# `cache`, setup-uv uses `enable-cache` with a default of "auto").
CACHE_INPUTS = ("cache", "enable-cache", "cache-python")


def violations(workflow):
    found = []
    for job_name, job in (workflow.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            uses = str(step.get("uses", ""))
            inputs = step.get("with") or {}
            label = f"{job_name}: {step.get('name') or uses}"
            if uses.split("@")[0].startswith("actions/cache"):
                found.append(f"{label} uses actions/cache")
            if uses.startswith("astral-sh/setup-uv"):
                if inputs.get("enable-cache") is not False:
                    found.append(f"{label} leaves the setup-uv cache on")
                continue
            for key in CACHE_INPUTS:
                if inputs.get(key) not in (None, False, ""):
                    found.append(f"{label} sets {key}")
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

        # Then no workflow restores or saves a cache.
        self.assertEqual(found, [])

    def test_actions_cache_step_is_rejected(self):
        # Given a step that restores a pinned tool directory from actions/cache.
        workflow = step("actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830", path="~/.cache/x", key="k")

        # When the workflow is checked.
        found = violations(workflow)

        # Then the cache step is reported.
        self.assertEqual(len(found), 1)
        self.assertIn("uses actions/cache", found[0])

    def test_setup_uv_default_cache_is_rejected(self):
        # Given setup-uv without an explicit enable-cache: false.
        workflow = step("astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b", version="0.11.31")

        # When the workflow is checked.
        found = violations(workflow)

        # Then its default hosted-runner cache is reported.
        self.assertEqual(found, ["build: astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b leaves the setup-uv cache on"])

    def test_setup_action_cache_input_is_rejected(self):
        # Given setup-python with its pip cache turned on.
        workflow = step("actions/setup-python@v5", **{"python-version": "3.12", "cache": "pip"})

        # When the workflow is checked.
        found = violations(workflow)

        # Then the cache input is reported.
        self.assertEqual(found, ["build: actions/setup-python@v5 sets cache"])


unittest.main()
PY
    pass 'workflows restore no Actions cache'
else
    fail 'workflows restore no Actions cache'
fi
summary

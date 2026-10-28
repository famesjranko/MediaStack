#!/usr/bin/env bash
# Every workflow `uses:` names a full commit SHA. A tag or branch can move to
# other code after review; a commit cannot. No Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin workflow-pins
if python3 -I - "$REPO_ROOT" <<'PY'; then
import pathlib
import re
import subprocess
import sys
import unittest

import yaml

ROOT = pathlib.Path(sys.argv.pop())
PINNED = re.compile(r"[^@\s]+@[0-9a-f]{40}")


def unpinned(workflow):
    """Each step or job `uses:` that does not end in a 40-hex commit SHA."""
    found = []
    for job_name, job in (workflow.get("jobs") or {}).items():
        refs = [job["uses"]] if "uses" in job else []
        refs += [step["uses"] for step in job.get("steps") or [] if "uses" in step]
        found += [f"{job_name}: {ref}" for ref in refs if not PINNED.fullmatch(str(ref))]
    return found


def step(uses):
    return {"jobs": {"build": {"steps": [{"uses": uses}]}}}


class WorkflowPins(unittest.TestCase):
    def test_repository_workflows_pin_every_action_to_a_commit(self):
        # Given every tracked workflow file.
        listed = subprocess.check_output(
            ["git", "ls-files", ".github/workflows/*.yml", ".github/workflows/*.yaml"],
            cwd=ROOT, text=True,
        ).split()
        self.assertTrue(listed, "no workflow files found")

        # When each `uses:` is checked.
        found = [f"{name}: {v}" for name in listed
                 for v in unpinned(yaml.safe_load((ROOT / name).read_text()))]

        # Then every action names a full commit SHA.
        self.assertEqual(found, [])

    def test_tag_branch_short_sha_and_local_references_are_rejected(self):
        for uses in ("actions/checkout@v4", "actions/checkout@main", "actions/checkout@fbc6f39",
                     "actions/checkout@" + "F" * 40, "./.github/actions/setup"):
            with self.subTest(uses):
                # Given a step whose reference is not a full lowercase commit SHA.
                workflow = step(uses)

                # When the workflow is checked.
                found = unpinned(workflow)

                # Then the step is reported.
                self.assertEqual(found, [f"build: {uses}"])

    def test_reusable_workflow_call_is_checked(self):
        # Given a job that calls a reusable workflow by tag.
        workflow = {"jobs": {"shared": {"uses": "octo/repo/.github/workflows/x.yml@v1"}}}

        # When the workflow is checked.
        found = unpinned(workflow)

        # Then the call is reported.
        self.assertEqual(found, ["shared: octo/repo/.github/workflows/x.yml@v1"])

    def test_commit_pinned_action_passes(self):
        # Given a step pinned to a full commit SHA with a version comment.
        workflow = step("actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09")

        # When the workflow is checked.
        found = unpinned(workflow)

        # Then nothing is reported.
        self.assertEqual(found, [])


unittest.main()
PY
    pass 'workflows pin every action to a commit SHA'
else
    fail 'workflows pin every action to a commit SHA'
fi
summary

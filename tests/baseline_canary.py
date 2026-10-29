#!/usr/bin/env python3
"""Run the accepted stack, or report its result from a separate trusted job."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import pathlib
import subprocess
import sys

from preflight.canary import failure_report, gh, inactivity_report, plan, sync_issue
from preflight.model import FIXTURES, canonical, one_line, resolve
from preflight.runner import execute


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--run", required=True)
    run.add_argument("--output", required=True, type=pathlib.Path)
    report = commands.add_parser("report")
    report.add_argument("--folder", required=True, type=pathlib.Path)
    report.add_argument("--outcome", required=True)
    report.add_argument("--run-url", required=True)
    args = parser.parse_args()
    if args.command == "run":
        # Resolve only fixtures. Product images come from the accepted lock, even on no-drift weeks.
        fixtures = {key: f"{image}@{resolve(image)}" for key, image in FIXTURES.items()}
        frozen = plan(args.run, fixtures)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        (args.output.parent / "plan.json").write_bytes(canonical(frozen))
        execute(frozen, frozen["jobs"][0]["id"], args.output)
        return
    failure = failure_report(args.folder, args.outcome, args.run_url)
    summary = failure or f"Accepted Stable install-e2e passed. [Run]({args.run_url}).\n"
    with pathlib.Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
        stream.write(summary)
    sync_issue("baseline-canary", "Baseline canary: accepted Stable install failed", failure)
    timestamp = gh(
        "api",
        f"repos/{os.environ['GH_REPO']}/commits",
        "--method",
        "GET",
        "-f",
        f"sha={os.environ['DEFAULT_BRANCH']}",
        "-f",
        "per_page=1",
        "--jq",
        ".[0].commit.committer.date",
    ).strip()
    reminder = inactivity_report(timestamp, dt.datetime.now(dt.timezone.utc), args.run_url)
    sync_issue("schedule-inactivity", "Scheduled checks: review repository inactivity", reminder)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        print(f"baseline canary failed: {one_line(exc)}", file=sys.stderr)
        raise SystemExit(1) from exc

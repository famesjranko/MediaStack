#!/usr/bin/env bash
# The weekly runs comment on the image-drift issue only when their table
# changed: the alert compares drift sets, the preflight compares per-service
# status tables. No Docker or network needed.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin hosted-preflight-notify
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests"))
from preflight.model import ROOT, drift
from preflight.notify import BOT, drift_changed, report_changed
from preflight.status import abort, render

RUN = {"url": "https://example.test/run/1", "ref": "refs/heads/main", "default_branch": "main"}
NOTHING = {"outcome": "", "pr": "", "reason": ""}
JOBS = {"combine": "skipped", "verify": "skipped", "publish": "skipped"}


def row(service, digit):
    return drift.ImageDigest(service, f"example/{service}:1", "sha256:" + digit * 64)


def alert(changed):
    """An issue body as the alert writes it: the drift report and a dated footer."""
    report = drift.markdown_summary([], [(row(s, "0"), row(s, d)) for s, d in changed], [])
    return report, report + "\n---\n_Filed by the alert on 2026-10-26 03:17 UTC._\n"


def plan(pending, run="100-1"):
    # Sonarr has no selection, so its status links to the run, and each run links elsewhere.
    return {"run": run, "selected": ["sonarr"], "pending": pending}


def report(pending, run="100-1", url="https://example.test/run/1"):
    return render(plan(pending, run), None, JOBS, NOTHING, dict(RUN, url=url))


def comment(body, login=BOT, kind="Bot"):
    return {"user": {"login": login, "type": kind}, "body": body}


HELD = {"bazarr": "subtitle database migration is not covered"}


class Notify(unittest.TestCase):
    def test_alert_comments_only_on_a_new_drift_set(self):
        _, body = alert([("bazarr", "1"), ("sonarr", "2")])
        for name, changed, expected in (
            ("same drift a week later", [("sonarr", "2"), ("bazarr", "1")], False),
            ("a service moved again", [("bazarr", "1"), ("sonarr", "3")], True),
            ("a service drifted", [("bazarr", "1"), ("sonarr", "2"), ("radarr", "4")], True),
        ):
            with self.subTest(name):
                # Given the issue body of last week's alert and this week's drift report.
                current, _ = alert(changed)

                # When the alert compares the two drift sets.
                result = drift_changed(body, current)

                # Then it comments only when the set of drifted digests changed.
                self.assertIs(result, expected)

    def test_unchanged_status_table_writes_no_comment(self):
        # Given the last bot report on the issue, from another run with other links.
        previous = report(HELD, run="90-1", url="https://example.test/run/90")
        comments = [[comment(previous), comment("Drift set changed. [Run](x)")]]

        # When this run's report has the same per-service states.
        result = report_changed(comments, report(HELD))

        # Then the report goes to the step summary only.
        self.assertIs(result, False)

    def test_changed_status_table_comments(self):
        # Given the last bot report on the issue.
        comments = [[comment(report(HELD, run="90-1"))]]

        # When a service is newly held in this run.
        result = report_changed(comments, report(dict(HELD, beszel="hub migration")))

        # Then the report is posted as a comment.
        self.assertIs(result, True)

    def test_only_the_newest_bot_report_counts(self):
        same, other = report(HELD, run="80-1"), report({"lidarr": "not selected"}, run="90-1")
        for name, comments, expected in (
            ("an older report matches, the newest differs", [[comment(same)], [comment(other)]],
             True),
            ("a matching report from a person", [[comment(other), comment(same, "someone", "User")]],
             True),
            ("a matching report from a user named like the bot",
             [[comment(other), comment(same, kind="User")]], True),
            ("no report yet", [[]], True),
        ):
            with self.subTest(name):
                # Given issue comments in API page order.
                # When this run's report is compared with the newest report by the workflow.
                result = report_changed(comments, report(HELD))

                # Then only a newest bot report with an equal table suppresses the comment.
                self.assertIs(result, expected)

    def test_failure_notice_always_comments(self):
        # Given a failure notice after an earlier failure notice.
        notice = abort("failure", RUN)
        comments = [[comment(notice)]]

        # When the notice is compared.
        result = report_changed(comments, notice)

        # Then it is posted, because a notice has no status table to compare.
        self.assertIs(result, True)

    def test_command_reads_paginated_comments(self):
        with tempfile.TemporaryDirectory() as folder:
            # Given two pages of comments from gh api --paginate --slurp, and this run's report.
            work = pathlib.Path(folder)
            pages = [[comment(report(HELD, run="80-1"))], [comment(report(HELD, run="90-1"))]]
            (work / "comments.json").write_text(json.dumps(pages))
            (work / "report.md").write_text(report(HELD))
            (work / "bad.json").write_text(json.dumps({"message": "Not Found"}))

            # When the workflow command compares them, and compares a malformed reply.
            def command(name):
                return subprocess.run(
                    ["python3", str(ROOT / "tests/hosted_preflight.py"), "report-changed",
                     "--comments", str(work / name), "--report", str(work / "report.md")],
                    capture_output=True, text=True, check=False)

            same, bad = command("comments.json"), command("bad.json")

        # Then it prints false for an unchanged table.
        self.assertEqual((same.returncode, same.stdout), (0, "false\n"))
        # And it fails on a reply that is not a list of pages.
        self.assertEqual((bad.returncode, bad.stdout), (1, ""))


unittest.main()
PY
    pass 'weekly runs comment on the drift issue only when their table changed'
else
    fail 'weekly runs comment on the drift issue only when their table changed'
fi
summary

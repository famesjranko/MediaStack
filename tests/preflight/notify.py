"""Decide whether a weekly run comments on the image-drift issue.

Held services keep drift open for weeks, so a comment for every run is noise.
A run comments only when its table differs from the one that it would repeat.
"""

from __future__ import annotations

import re
from typing import Any

BOT = "github-actions[bot]"
DRIFT_HEADER = "| Service | Previous | Current | Local preflight |"
STATUS_HEADER = "| Service | Status |"
REPORT_HEADING = "### Image preflight "
# A link target names the run, so it differs on every run; the link text stays.
LINK_TARGET = re.compile(r"\]\([^)]*\)")


def table(markdown: str, header: str) -> list[str] | None:
    """The rows of the first table with ``header``, or None when it has no such table."""
    lines = markdown.splitlines()
    if header not in lines:
        return None
    rows = []
    for line in lines[lines.index(header) + 2 :]:
        if not line.startswith("|"):
            break
        rows.append(LINK_TARGET.sub("]", line.strip()))
    return sorted(rows)


def drift_changed(previous_body: str, report: str) -> bool:
    """True when the drift set of ``report`` differs from the issue body it refreshes."""
    return table(previous_body, DRIFT_HEADER) != table(report, DRIFT_HEADER)


def last_report(comments: list[Any]) -> str | None:
    """The body of the newest status report that the workflow posted, from API pages."""
    found = None
    for page in comments:
        if not isinstance(page, list):
            raise ValueError("issue comments are not a list of pages")
        for comment in page:
            user = comment["user"] or {}
            body = comment["body"] or ""
            own = user.get("login") == BOT and user.get("type") == "Bot"
            if own and body.startswith(REPORT_HEADING):
                found = body
    return found


def report_changed(comments: list[Any], report: str) -> bool:
    """True when the per-service status table differs from the last report comment.

    A report without a status table is a failure notice; it always comments.
    """
    current = table(report, STATUS_HEADER)
    if current is None:
        return True
    previous = last_report(comments)
    return previous is None or table(previous, STATUS_HEADER) != current

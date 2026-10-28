"""Decide how one rolling digest PR changes. Pure decisions over GitHub API data."""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any, NamedTuple

BRANCH = "chore/tested-images"
LABEL = "tested-digests"
TITLE = "chore: refresh tested Stable image digests"
AUTHOR_EMAIL = "andrewmcdonald42@gmail.com"
BOT = "github-actions[bot]"
FILES = {"docs/operations/image-digests.lock", "README.md"}


class Decision(NamedTuple):
    action: str  # create, update, unchanged, keep, none or refuse
    reason: str
    pr: int | None
    lease: str  # the branch head the push must replace; empty means "must not exist"


def branch_problem(compare: dict[str, Any]) -> str | None:
    # The publisher always rebuilds the branch as one commit on the default
    # branch. Any other shape means a person or another tool changed it.
    commits = compare.get("commits") or []
    if compare.get("ahead_by") != 1 or len(commits) != 1:
        return "the rolling branch does not hold exactly one publisher commit"
    commit = commits[0]["commit"]
    identity = (commit["author"]["email"], commit["committer"]["email"], commit["message"].strip())
    if identity != (AUTHOR_EMAIL, AUTHOR_EMAIL, TITLE):
        return "the rolling branch has a commit that the publisher did not create"
    if not {f["filename"] for f in compare.get("files") or []} <= FILES:
        return "the rolling branch changes files outside the digest record"
    return None


def ownership_problem(prs: list[Any], head: str, compare: dict[str, Any]) -> str | None:
    if len(prs) > 1:
        return "more than one open PR uses the rolling branch"
    if prs:
        pr = prs[0]
        if pr["user"]["login"] != BOT or pr["user"]["type"] != "Bot":
            return f"PR #{pr['number']} was not opened by {BOT}"
        if pr["head"]["sha"] != head:
            return f"PR #{pr['number']} head differs from the rolling branch head"
    return branch_problem(compare) if head else None


def lock_rows(text: str) -> list[tuple[str, ...]]:
    """Lock rows without the test timestamp, which differs on every run."""
    found = []
    for line in text.splitlines():
        if not line.strip() or line.startswith(("#", "service\t")):
            continue
        cols = line.split("\t")
        found.append(tuple(cols[:3] + cols[4:]))
    return found


def decide(
    proposed: str | None,
    prs: list[Any],
    head: str,
    compare: dict[str, Any],
    branch_lock: str | None,
) -> Decision:
    """Choose the single change to the rolling PR; ``proposed`` is None when nothing passed."""
    problem = ownership_problem(prs, head, compare)
    if problem:
        return Decision("refuse", problem + "; nothing changed", None, head)
    pr = prs[0]["number"] if prs else None
    if proposed is None and pr:
        return Decision(
            "keep",
            f"this run accepted no candidate; PR #{pr} is unchanged and its tested digests "
            "remain valid",
            pr,
            head,
        )
    if proposed is None:
        return Decision(
            "none", "this run accepted no candidate and no digest PR is open", None, head
        )
    if pr and branch_lock is not None and lock_rows(branch_lock) == lock_rows(proposed):
        return Decision("unchanged", f"PR #{pr} already proposes the same lock", pr, head)
    if pr:
        return Decision("update", f"PR #{pr} now proposes this run's combination", pr, head)
    return Decision("create", "a new PR proposes this run's combination", None, head)


def decide_from_files(facts: pathlib.Path, proposed: pathlib.Path | None) -> Decision:
    """Read the facts the workflow fetched; any malformed fact stops publication."""
    head = (facts / "head").read_text().strip()
    if head and not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("rolling branch head is not a commit SHA")
    prs = json.loads((facts / "prs.json").read_text())
    if not isinstance(prs, list):
        raise ValueError("open PR list is malformed")
    compare = json.loads((facts / "compare.json").read_text()) if head else {}
    lock = facts / "branch.lock"
    return decide(
        proposed.read_text() if proposed and proposed.is_file() else None,
        prs,
        head,
        compare,
        lock.read_text() if head and lock.is_file() else None,
    )

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
    action: str  # create, update, unchanged, keep, close, none or refuse
    reason: str
    pr: int | None
    lease: str  # the branch head the push must replace; empty means "must not exist"


class Facts(NamedTuple):
    """What the workflow read from GitHub about the rolling branch."""

    prs: list[Any]  # open PRs whose head is the rolling branch
    head: str  # the rolling branch head; empty when the branch does not exist
    compare: dict[str, Any]  # default branch...head comparison
    branch_lock: str | None  # the digest record on the rolling branch
    closed: list[Any]  # recently closed PRs whose head is the rolling branch


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


def pr_problem(pr: dict[str, Any], head: str) -> str | None:
    if pr["user"]["login"] != BOT or pr["user"]["type"] != "Bot":
        return f"PR #{pr['number']} was not opened by {BOT}"
    if pr["head"]["sha"] != head:
        return f"PR #{pr['number']} head differs from the rolling branch head"
    return None


def orphan_problem(facts: Facts) -> str | None:
    """Judge a branch that has no open PR by the closed PR that last held its head.

    The repository squash-merges and deletes merged branches, so a merged
    head is never an ancestor of the default branch; only the PR records it.
    A head that no PR held is the publisher's own push whose PR creation failed.
    """
    closed = next((p for p in facts.closed if p["head"]["sha"] == facts.head), None)
    if closed is None:
        return branch_problem(facts.compare)
    if closed.get("merged_at"):
        return None
    return (
        f"the rolling branch was left by PR #{closed['number']}, which was closed without "
        "merging; delete the branch to re-enable publication"
    )


def ownership_problem(facts: Facts) -> str | None:
    if len(facts.prs) > 1:
        return "more than one open PR uses the rolling branch"
    if facts.prs:
        return pr_problem(facts.prs[0], facts.head) or branch_problem(facts.compare)
    return orphan_problem(facts) if facts.head else None


def lock_rows(text: str) -> list[tuple[str, ...]]:
    """Lock rows without the test timestamp, which differs on every run."""
    found = []
    for line in text.splitlines():
        if not line.strip() or line.startswith(("#", "service\t")):
            continue
        cols = line.split("\t")
        found.append(tuple(cols[:3] + cols[4:]))
    return found


def rejected(plan: dict[str, Any], selection: dict[str, Any], verified: str) -> dict[str, str]:
    """Candidate references that this run tested and did not accept.

    A phase-1 failure rejects its candidate. When final verification did not
    succeed, every candidate of the frozen combination was refused with it.
    """
    refused = set(selection["failed"])
    if verified != "success":
        refused |= set(selection["selected"])
    return {service: plan["candidates"][service] for service in sorted(refused)}


def contradicted(branch_lock: str | None, refused: dict[str, str]) -> list[str]:
    """Services whose exact digest the rolling branch proposes and this run refused."""
    proposed = {(row[0], f"{row[1]}@{row[2]}") for row in lock_rows(branch_lock or "")}
    return [service for service, ref in refused.items() if (service, ref) in proposed]


def without_proposal(pr: int | None, refused: dict[str, str], facts: Facts) -> Decision:
    if pr is None:
        return Decision(
            "none", "this run accepted no candidate and no digest PR is open", None, facts.head
        )
    failed = contradicted(facts.branch_lock, refused)
    if failed:
        return Decision(
            "close",
            f"this run refused {', '.join(failed)} at the exact digest that PR #{pr} proposes; "
            "the PR is closed and its branch deleted",
            pr,
            facts.head,
        )
    return Decision(
        "keep",
        f"this run accepted no candidate and refused none of PR #{pr}'s digests; the PR is "
        "unchanged, and its evidence is the source and run that its description cites",
        pr,
        facts.head,
    )


def decide(proposed: str | None, refused: dict[str, str], facts: Facts) -> Decision:
    """Choose the single change to the rolling PR; ``proposed`` is None when nothing passed."""
    problem = ownership_problem(facts)
    if problem:
        return Decision("refuse", problem + "; nothing changed", None, facts.head)
    pr = facts.prs[0]["number"] if facts.prs else None
    if proposed is None:
        return without_proposal(pr, refused, facts)
    if pr and facts.branch_lock is not None and lock_rows(facts.branch_lock) == lock_rows(proposed):
        return Decision(
            "unchanged",
            f"PR #{pr} already proposes the same lock; its description now cites this run",
            pr,
            facts.head,
        )
    if pr:
        return Decision("update", f"PR #{pr} now proposes this run's combination", pr, facts.head)
    return Decision("create", "a new PR proposes this run's combination", None, facts.head)


def read_facts(folder: pathlib.Path) -> Facts:
    """Read the facts the workflow fetched; any malformed fact stops publication."""
    head = (folder / "head").read_text().strip()
    if head and not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("rolling branch head is not a commit SHA")
    prs = json.loads((folder / "prs.json").read_text())
    closed = json.loads((folder / "closed.json").read_text())
    if not isinstance(prs, list) or not isinstance(closed, list):
        raise ValueError("PR list is malformed")
    lock = folder / "branch.lock"
    return Facts(
        prs,
        head,
        json.loads((folder / "compare.json").read_text()) if head else {},
        lock.read_text() if head and lock.is_file() else None,
        closed,
    )

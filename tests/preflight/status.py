"""Render one per-run status report from validated plan data and job results."""

from __future__ import annotations

from typing import Any

PROPOSED = ("created", "updated", "unchanged")


def selected_status(
    service: str,
    selection: dict[str, Any] | None,
    verified: str,
    publication: dict[str, str],
    link: str,
) -> str:
    if selection is None:
        return f"undecided: phase 1 or the selection did not complete ({link})"
    if service in selection["failed"]:
        names = ", ".join(f"`result-p1-{service}.{s}`" for s in selection["failed"][service])
        return f"failed in phase 1 ({link}; {names})"
    if verified != "success":
        if selection["authority"] == "phase-2":
            return f"failed in phase 2 ({link}; `result-p2-*`)"
        return f"failed final verification ({link})"
    if publication["outcome"] in PROPOSED and publication["pr"]:
        return f"proposed in PR #{publication['pr']}"
    if publication["result"] == "skipped":
        return "passed; the publisher did not run"
    return f"passed; not proposed ({link})"


def render(
    plan: dict[str, Any],
    selection: dict[str, Any] | None,
    verified: str,
    publication: dict[str, str],
    run_url: str,
) -> str:
    link = f"[run]({run_url}), [artifacts]({run_url}#artifacts)"
    status = {
        s: selected_status(s, selection, verified, publication, link) for s in plan["selected"]
    }
    for service, reason in plan["pending"].items():
        status[service] = "not selected" if reason == "not selected" else "held: " + reason
    lines = [f"### Image preflight `{plan['run']}`", "", "| Service | Status |", "|---|---|"]
    lines += [f"| {service} | {text} |" for service, text in sorted(status.items())]
    if not status:
        lines.append("| none | no drifted service |")
    reason = publication["reason"] or (
        "the publisher did not run: publication was not requested, the ref is not the "
        "default branch, or the selection did not complete"
        if publication["result"] == "skipped"
        else "the publisher did not finish; see the run"
    )
    lines += ["", f"Publication: {reason}."]
    return "\n".join(lines) + "\n"

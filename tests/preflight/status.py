"""Render one per-run status report from validated plan data and job results."""

from __future__ import annotations

from typing import Any

# publish.decide actions after which the open PR carries this run's lock.
PROPOSED = ("create", "update", "unchanged")


def runner_text(phase: int, details: dict[str, str], link: str) -> str:
    """Name each job whose disk headroom ran out, with its measurement.

    The cause can be the runner or the image, so the candidate stays undecided.
    """
    jobs = "; ".join(f"`{name}`: {detail}" for name, detail in sorted(details.items()))
    return f"undecided in phase {phase}: {jobs} ({link})"


def phase_one_status(service: str, selection: dict[str, Any], link: str) -> str | None:
    # An image failure outranks exhausted headroom in another job of the same candidate.
    if service in selection["failed"]:
        names = ", ".join(f"`result-p1-{service}.{s}`" for s in selection["failed"][service])
        return f"failed in phase 1 ({link}; {names})"
    if service in selection["runner_failed"]:
        details = {
            f"result-p1-{service}.{scenario}": detail
            for scenario, detail in selection["runner_failed"][service].items()
        }
        return runner_text(1, details, link)
    return None


def selected_status(
    service: str,
    selection: dict[str, Any] | None,
    jobs: dict[str, str],
    publication: dict[str, str],
    link: str,
    runner: dict[str, dict[str, str]],
) -> str:
    if selection is None:
        return f"undecided: phase 1 or the selection did not complete ({link})"
    first = phase_one_status(service, selection, link)
    if first:
        return first
    if jobs["verify"] != "success":
        if selection["authority"] == "phase-2" and jobs["combine"] != "success":
            if service in runner:
                details = {f"result-p2-{s}": d for s, d in runner[service].items()}
                return runner_text(2, details, link)
            return f"failed in phase 2 ({link}; `result-p2-*`)"
        return f"failed final verification ({link})"
    if publication["outcome"] in PROPOSED and publication["pr"] and jobs["publish"] == "success":
        return f"proposed in PR #{publication['pr']}"
    if jobs["publish"] == "skipped":
        return "passed; the publisher did not run"
    return f"passed; not proposed ({link})"


def publication_line(result: str, publication: dict[str, str]) -> str:
    reason = publication["reason"]
    if result == "success":
        return reason
    if result == "skipped":
        return (
            "the publisher did not run: publication was not requested, the ref is not the "
            "default branch, or the selection did not complete"
        )
    if publication["outcome"] == "refuse":
        return "the publisher refused: " + reason
    decided = f" after it decided: {reason}" if reason else ""
    return f"the publisher did not finish{decided}; see the run"


def heading(title: str, run: dict[str, str]) -> list[str]:
    ref = f"`{run['ref']}`"
    if run["ref"] != "refs/heads/" + run["default_branch"]:
        ref += " (a trial run; not a default-branch result)"
    return [f"### Image preflight {title}", "", f"Ref: {ref}", ""]


def render(
    plan: dict[str, Any],
    selection: dict[str, Any] | None,
    jobs: dict[str, str],
    publication: dict[str, str],
    run: dict[str, str],
    runner: dict[str, dict[str, str]] | None = None,
) -> str:
    """``jobs`` maps combine, verify and publish to their job results.

    ``runner`` is ``verify.phase_two_undecided`` for a failed phase 2.
    """
    link = f"[run]({run['url']}), [artifacts]({run['url']}#artifacts)"
    status = {
        s: selected_status(s, selection, jobs, publication, link, runner or {})
        for s in plan["selected"]
    }
    for service, reason in plan["pending"].items():
        status[service] = "not selected" if reason == "not selected" else "held: " + reason
    lines = [*heading(f"`{plan['run']}`", run), "| Service | Status |", "|---|---|"]
    lines += [f"| {service} | {text} |" for service, text in sorted(status.items())]
    if not status:
        lines.append("| none | no drifted service |")
    lines += ["", f"Publication: {publication_line(jobs['publish'], publication)}."]
    return "\n".join(lines) + "\n"


def abort(plan_result: str, run: dict[str, str]) -> str:
    """The report when no validated plan is available, so that a failure is never silent."""
    if plan_result != "success":
        cause = (
            "the planner failed, for example on a registry outage, an invalid `services` "
            "input or a lock that differs from compose"
        )
    else:
        cause = (
            "the status job could not validate this run's plan. Partial re-runs are not "
            "supported; use **Re-run all jobs**"
        )
    lines = heading("did not report", run)
    lines.append(f"No per-service status: {cause}. See the [run]({run['url']}).")
    return "\n".join(lines) + "\n"

"""Treat image-job artifacts as data; never execute an artifact's code or commands."""

from __future__ import annotations

import pathlib
import re
import sys
from typing import Any

from . import contracts
from .model import (
    ROOT,
    build_plan,
    canonical,
    combination_plan,
    drift,
    effective,
    fingerprint,
    headroom_error,
    load_json,
    one_line,
    rows,
)
from .status import contract_lines, coverage_lines

# Any malformed artifact classifies its job as failed instead of stopping selection.
MALFORMED = (ValueError, OSError, KeyError, TypeError, AttributeError)
# Every result must carry these non-negative integers. A disk sampler that could
# not measure the whole run writes null, so its result never qualifies.
RESOURCES = (
    "elapsed_seconds",
    "disk_free_start_bytes",
    "disk_peak_growth_bytes",
    "disk_growth_bytes",
    "disk_samples",
)


# Contract messages can quote artifact text (an unlisted path, an unknown entry
# id). They reach Markdown tables and logs, so only these characters pass, and
# each service reports a bounded number of them.
UNSAFE_TEXT = re.compile(r"[^A-Za-z0-9 ._/{}()\[\],:=@#+\u00d7-]")
MESSAGES_PER_SERVICE = 20
CONTRACTS_FILE = "contracts.json"


class RunnerDiskError(ValueError):
    """The disk headroom ran out, so the job decides nothing about its images.

    The cause can be the runner or an image that writes much more data.
    """

    def __init__(self, job_id: str, detail: str) -> None:
        super().__init__(f"{job_id}: undecided: {detail}")
        self.detail = detail


def folder_of(results: pathlib.Path, job: dict[str, Any]) -> pathlib.Path:
    return results / ("result-" + str(job["id"]))


def check_status(plan: dict[str, Any], job: dict[str, Any], result: dict[str, Any]) -> None:
    identity = {
        "schema": 1,
        "plan": fingerprint(plan),
        "source": plan["source"],
        "run": plan["run"],
        "job": job["id"],
        "scenario": job["scenario"],
        "run_id": job["run_id"],
        "architecture": plan["architecture"],
    }
    if any(result.get(k) != v for k, v in identity.items()):
        raise ValueError(f"{job['id']}: stale or mismatched result")
    check_measured(result)
    # Before the outcome: a full disk can also fail the scenario. The numbers
    # decide, not the runner's own runner_error field.
    exhausted = headroom_error(result)
    if exhausted:
        raise RunnerDiskError(job["id"], exhausted)
    # An absent error field is not a null one: it comes from a runner that did not measure.
    outcome = {"rc": 0, "failures": 0, "skips": 0, "evidence_error": None, "runner_error": None}
    if any(k not in result or result[k] != v for k, v in outcome.items()):
        raise ValueError(f"{job['id']}: failed, skipped, or unmeasured result")
    if type(result.get("passes")) is not int or result["passes"] < 1:
        raise ValueError("result contains no passing assertions")


def check_measured(result: dict[str, Any]) -> None:
    """Refuse a result whose disk use was not measured over the whole run."""
    if "disk_error" not in result or result["disk_error"] is not None:
        raise ValueError("result is unmeasured: the disk sampler failed or did not report")
    for field in RESOURCES:
        if type(result.get(field)) is not int or result[field] < 0:
            raise ValueError("result lacks resource measurements")
    if result["disk_samples"] < 1:
        raise ValueError("result lacks resource measurements: no disk sample")
    if result["disk_peak_growth_bytes"] < result["disk_growth_bytes"]:
        raise ValueError("result has inconsistent resource measurements: peak below end growth")


def check_result(plan: dict[str, Any], job: dict[str, Any], folder: pathlib.Path) -> pathlib.Path:
    check_status(plan, job, load_json(folder / "result.json"))
    images = load_json(folder / "images.json")
    events = load_json(folder / "events.json")
    if not images or not events:
        raise ValueError("result lacks runtime image and event evidence")
    check_runtime_evidence(plan, job, events, images)
    receipt_path = folder / "receipts.tsv"
    if receipt_path.is_symlink() or receipt_path.stat().st_size > 1_000_000:
        raise ValueError("invalid receipt artifact")
    receipts = drift.read_pass_receipts(receipt_path)
    policy = drift.ReceiptPolicy(plan["source"], frozenset([job["run_id"]]), plan["architecture"])
    for service in job["services"]:
        image, digest = plan["candidates"][service].rsplit("@", 1)
        row = drift.ImageDigest(service, image, digest)
        why = drift._receipt_failure(receipts.get(service, []), row, job["scenario"], policy)
        if why:
            raise ValueError(f"{service}/{job['scenario']}: {why}")
        if not any(
            digest in [d.rsplit("@", 1)[-1] for d in i.get("digests", []) or []] for i in images
        ):
            raise ValueError(f"{service}: candidate was not inspected in the image job")
    return receipt_path


def check_runtime_evidence(
    plan: dict[str, Any], job: dict[str, Any], events: list[Any], images: list[Any]
) -> None:
    refs = effective(plan, job)
    latest = {
        event["service"]: event["image"]
        for event in events
        if event["action"] == "start" and event["service"] in refs
    }
    if not latest:
        raise ValueError("no known service started in the scenario")
    missing = sorted(set(job["services"]) - latest.keys())
    if missing:
        raise ValueError(f"{', '.join(missing)}: candidate has no runtime start event")
    for service, ref in latest.items():
        if ref != refs[service]:
            raise ValueError(f"{service}: runtime companion differs from the frozen combination")
    fixtures = {drift.repo_of(ref): ref for ref in plan["fixtures"].values()}
    for event in events:
        ref = event["image"]
        if (
            isinstance(ref, str)
            and drift.repo_of(ref) in fixtures
            and ref != fixtures[drift.repo_of(ref)]
        ):
            raise ValueError("test fixture image differs from the frozen plan")
    for image in images:
        if image["arch"] != "amd64" or image["os"] != "linux":
            raise ValueError("runtime inspection architecture differs from linux/amd64")


def safe_text(text: str) -> str:
    return UNSAFE_TEXT.sub("?", one_line(text))[:300]


def _add_message(failed: dict[str, list[str]], service: str, message: str) -> None:
    messages = failed.setdefault(service, [])
    if len(messages) < MESSAGES_PER_SERVICE:
        messages.append(safe_text(message))
    elif len(messages) == MESSAGES_PER_SERVICE:
        messages.append("further contract failures omitted; see the artifacts")


def contract_verdict(
    plan: dict[str, Any], jobs: list[dict[str, Any]], results: pathlib.Path, services: list[str]
) -> dict[str, Any]:
    """Judge the contract evidence of ``jobs`` for the candidate ``services``.

    The rules are tests/preflight/contracts.py, against the verifier's own
    inventory: this checkout is the plan's source. Only jobs of the traced
    scenarios carry evidence. A traced job whose contracts.json is missing,
    malformed or not its own fails every candidate it ran. Only the other
    services get the per-entry verdict, so that incomplete evidence never reads
    as an unexercised entry. A service without entries and without a traced job
    has nothing to judge; it is reported. Returns JSON data: contract failures
    by service, and the exempt entries, stale exemptions and services without
    entries that the reports list.
    """
    found, own = contracts.own_inventory()
    failed: dict[str, list[str]] = {}
    evidence = []
    traced = [job for job in jobs if job["scenario"] in contracts.TRACED_SCENARIOS]
    untraced = [
        service
        for service in services
        if not any(service in job["services"] for job in traced)
        and not any(entry.service == service for entry in found)
    ]
    for job in traced:
        try:
            data = contracts.read_contracts(folder_of(results, job) / CONTRACTS_FILE)
        except (OSError, ValueError):
            problems = [f"{CONTRACTS_FILE} is missing or unreadable"]
        else:
            problems = contracts.check_job(job, data, plan["candidates"], own, found)
            if not problems:
                evidence.append((job, data))
        for service in job["combination"]:
            for problem in problems:
                _add_message(failed, service, f"{job['id']}: {problem}")
    judged = contracts.verdict(
        evidence,
        [s for s in services if s not in failed and s not in untraced],
        plan["candidates"],
        own,
        found,
    )
    judged.uncovered += [
        f"{service}: no contract entries and no traced scenario; acceptance rests on its scenarios"
        for service in untraced
    ]
    for failure in judged.failures:
        service, message = failure.scope, failure.message
        named = message.startswith((service + " ", service + ":"))
        _add_message(failed, service, message if named else f"{service}: {message}")
    return {
        "failed": {service: failed[service] for service in sorted(failed)},
        "exempt": judged.exempt,
        "stale": [safe_text(text) for text in judged.stale],
        "uncovered": judged.uncovered,
    }


def select_combination(plan: dict[str, Any], results: pathlib.Path) -> dict[str, Any]:
    """Freeze phase 2 from phase-1 results; a candidate passes only if all its jobs qualify.

    A candidate whose jobs all passed must also pass the contract verdict over
    those jobs. A contract failure is an image failure, never undecided.
    """
    if plan["phase"] != 1:
        raise ValueError("selection needs the phase-1 plan")
    failed, runner = job_failures(plan, results)
    judged = [s for s in plan["selected"] if s not in failed and s not in runner]
    jobs = [job for job in plan["jobs"] if set(job["combination"]) <= set(judged)]
    report = contract_verdict(plan, jobs, results, judged)
    for service in report["failed"]:
        print(f"{service}: contract coverage failed", file=sys.stderr)
        failed[service] = sorted(job["scenario"] for job in jobs if service in job["services"])
    passed = [s for s in judged if s not in failed]
    selection = combination_plan(plan, passed, failed, runner)
    selection["contracts"] = report
    return selection


def job_failures(
    plan: dict[str, Any], results: pathlib.Path
) -> tuple[dict[str, list[str]], dict[str, dict[str, str]]]:
    """Map each candidate to its failed scenarios, and to those whose disk headroom ran out.

    A missing or malformed result counts as failed.
    """
    failed: dict[str, list[str]] = {}
    runner: dict[str, dict[str, str]] = {}
    for job in plan["jobs"]:
        try:
            check_result(plan, job, folder_of(results, job))
        except RunnerDiskError as exc:
            print(exc, file=sys.stderr)
            for service in job["combination"]:
                runner.setdefault(service, {})[job["scenario"]] = exc.detail
        except MALFORMED as exc:
            # The text may quote artifact data; the frozen job id comes first.
            print(f"{job['id']}: {one_line(exc)}", file=sys.stderr)
            for service in job["combination"]:
                failed.setdefault(service, []).append(job["scenario"])
    return failed, runner


def phase_two_undecided(
    selection: dict[str, Any], results: pathlib.Path
) -> dict[str, dict[str, str]]:
    """Candidates whose failed phase-2 jobs ran out of disk headroom and did nothing else.

    An image failure or a missing or malformed result in any job keeps the
    candidate refused. These results are data only; they never change the lock.
    """
    failed, runner = job_failures(selection, results)
    return {service: scenarios for service, scenarios in runner.items() if service not in failed}


def phase_two_contract_failures(
    selection: dict[str, Any], results: pathlib.Path
) -> dict[str, list[str]]:
    """The contract failures of a combination whose phase-2 jobs all passed.

    Final verification refuses such a combination; the status report names
    each failed entry. These results are data only; they never change the lock.
    """
    if selection["authority"] != "phase-2":
        return {}
    failed, runner = job_failures(selection, results)
    if failed or runner:
        return {}
    report = contract_verdict(selection, selection["jobs"], results, selection["selected"])
    return dict(report["failed"])


def authorized_jobs(
    phase1: dict[str, Any], phase2: dict[str, Any]
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    """Return the only jobs whose evidence may change the lock.

    Evidence authorizes exactly the combination it ran. Phase-1 jobs ran one
    candidate each, so they can authorize only a single-candidate combination.
    """
    combination = phase2["selected"]
    if phase2["authority"] == "phase-1" and len(combination) == 1:
        source = phase1
    elif phase2["authority"] == "phase-2" and len(combination) > 1:
        source = phase2
    else:
        raise ValueError(
            f"{phase2['authority']} evidence cannot authorize the combination "
            + (", ".join(combination) or "of no candidates")
        )
    jobs = [(source, job) for job in source["jobs"] if job["combination"] == combination]
    if not jobs:
        raise ValueError("no job tested the exact combination")
    return jobs


def accept(
    phase1: dict[str, Any],
    phase2: dict[str, Any],
    snapshot: pathlib.Path,
    results: pathlib.Path,
    output: pathlib.Path,
) -> None:
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    current = rows(snapshot)
    rebuilt = build_plan(
        baseline, current, phase1["selected"], phase1["source"], phase1["run"], phase1["fixtures"]
    )
    if canonical(rebuilt) != canonical(phase1):
        raise ValueError("snapshot and selection do not reproduce the trusted plan")
    if canonical(select_combination(phase1, results)) != canonical(phase2):
        raise ValueError("phase-2 plan is stale or does not follow from the phase-1 results")
    evidence = authorized_jobs(phase1, phase2)
    receipts = [check_result(p, job, folder_of(results, job)).read_text() for p, job in evidence]
    report = contract_verdict(
        evidence[0][0], [job for _, job in evidence], results, phase2["selected"]
    )
    if report["failed"]:
        raise ValueError("contract coverage failed: " + "; ".join(contract_lines(report)))
    # Validate the complete combination before writing any publication file.
    output.mkdir(parents=True, exist_ok=False)
    receipt_path = output / "receipts.tsv"
    receipt_path.write_text("\n".join(receipts))
    selected = set(phase2["selected"])
    manifest = drift.read_preflights(ROOT / "docs/operations/upgrades.md")
    enriched = drift.enrich_rows(
        list(current.values()),
        list(baseline.values()),
        manifest,
        drift.datetime.now(drift.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    policy = drift.ReceiptPolicy(
        phase2["source"], frozenset(job["run_id"] for _, job in evidence), phase2["architecture"]
    )
    drift.verify_preflight_receipts(
        selected, list(baseline.values()), enriched, drift.read_pass_receipts(receipt_path), policy
    )
    drift.write_tsv(
        output / "image-digests.lock",
        drift.merge_selective(list(baseline.values()), enriched, selected),
    )
    write_body(phase2, evidence, results, report, output / "body.md")


def write_body(
    phase2: dict[str, Any],
    evidence: list[tuple[dict[str, Any], dict[str, Any]]],
    results: pathlib.Path,
    report: dict[str, Any],
    path: pathlib.Path,
) -> None:
    # No artifact value becomes a shell command, branch name or executable path.
    services = ", ".join(phase2["selected"])
    lines = [
        "",
        "Source: `" + phase2["source"] + "`; workflow run: `" + phase2["run"] + "`; "
        "authorizing evidence: " + phase2["authority"] + ".",
        "",
        "| Job | Scenario | Passed | Seconds | Peak disk growth (bytes) "
        "| End disk growth (bytes) |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for _, job in evidence:
        result = load_json(folder_of(results, job) / "result.json")
        lines.append(
            f"| {job['id']} | {job['scenario']} | {result['passes']} | "
            f"{result['elapsed_seconds']} | {result['disk_peak_growth_bytes']} | "
            f"{result['disk_growth_bytes']} |"
        )
    failed = ", ".join(sorted(phase2["failed"])) or "none"
    path.write_text(
        "## What & why\n\nUpdate tested Stable digests for " + services + ".\n\n"
        "## Linked issue\n\nPart of #134.\n\n## How it was verified\n\n"
        "Each selected candidate first ran alone with the accepted companions. "
        "The candidates that passed then ran together, unless only one passed. "
        "Every required scenario of this exact combination passed without skips. "
        "Results bind the source commit, workflow run, architecture, companions and exact digests. "
        "Resource measurements and sanitized logs are in the workflow artifacts. "
        "Candidates that failed phase 1: " + failed + ".\n" + "\n".join(lines) + "\n\n"
        "Every inventoried API call of each candidate was made on its candidate digest with "
        "an accepted status, every declared read was seen, and no unlisted call was made. "
        "These are the limits of that proof:\n\n" + "\n".join(coverage_lines(report)) + "\n\n"
        "## Notes\n\nOther lock rows and timestamps are preserved. Image updates can migrate "
        "persistent databases; reverting the lock alone does not undo those migrations. "
        "Review the compatibility matrix and artifacts before merging. A later accepted run "
        "replaces this proposal on the same branch.\n"
    )

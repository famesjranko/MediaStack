"""Treat image-job artifacts as data; never execute an artifact's code or commands."""

from __future__ import annotations

import pathlib
import sys
from typing import Any

from .model import (
    ROOT,
    build_plan,
    canonical,
    combination_plan,
    drift,
    effective,
    fingerprint,
    load_json,
    rows,
)

# Any malformed artifact classifies its job as failed instead of stopping selection.
MALFORMED = (ValueError, OSError, KeyError, TypeError, AttributeError)


def folder_of(results: pathlib.Path, job: dict[str, Any]) -> pathlib.Path:
    return results / ("result-" + str(job["id"]))


def check_result(plan: dict[str, Any], job: dict[str, Any], folder: pathlib.Path) -> pathlib.Path:
    result = load_json(folder / "result.json")
    expected = {
        "schema": 1,
        "plan": fingerprint(plan),
        "source": plan["source"],
        "run": plan["run"],
        "job": job["id"],
        "scenario": job["scenario"],
        "run_id": job["run_id"],
        "architecture": plan["architecture"],
        "rc": 0,
        "failures": 0,
        "skips": 0,
        "evidence_error": None,
    }
    if any(result.get(k) != v for k, v in expected.items()):
        raise ValueError(f"{job['id']}: stale, failed, skipped, or mismatched result")
    if type(result.get("passes")) is not int or result["passes"] < 1:
        raise ValueError("result contains no passing assertions")
    for field in ("elapsed_seconds", "disk_growth_bytes"):
        if type(result.get(field)) is not int or result[field] < 0:
            raise ValueError("result lacks resource measurements")
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


def select_combination(plan: dict[str, Any], results: pathlib.Path) -> dict[str, Any]:
    """Freeze phase 2 from phase-1 results; a candidate passes only if all its jobs qualify."""
    if plan["phase"] != 1:
        raise ValueError("selection needs the phase-1 plan")
    failed: dict[str, list[str]] = {}
    for job in plan["jobs"]:
        try:
            check_result(plan, job, folder_of(results, job))
        except MALFORMED as exc:
            # The log may quote artifact text; the plan carries only frozen names.
            print(f"{job['id']}: {exc}", file=sys.stderr)
            failed.setdefault(job["combination"][0], []).append(job["scenario"])
    passed = [s for s in plan["selected"] if s not in failed]
    return combination_plan(plan, passed, failed)


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
    write_body(phase2, evidence, results, output / "body.md")


def write_body(
    phase2: dict[str, Any],
    evidence: list[tuple[dict[str, Any], dict[str, Any]]],
    results: pathlib.Path,
    path: pathlib.Path,
) -> None:
    # No artifact value becomes a shell command, branch name or executable path.
    services = ", ".join(phase2["selected"])
    lines = [
        "",
        "Source: `" + phase2["source"] + "`; workflow run: `" + phase2["run"] + "`; "
        "authorizing evidence: " + phase2["authority"] + ".",
        "",
        "| Job | Scenario | Passed | Seconds | Disk growth (bytes) |",
        "|---|---|---:|---:|---:|",
    ]
    for _, job in evidence:
        result = load_json(folder_of(results, job) / "result.json")
        lines.append(
            f"| {job['id']} | {job['scenario']} | {result['passes']} | "
            f"{result['elapsed_seconds']} | {result['disk_growth_bytes']} |"
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
        "## Notes\n\nOther lock rows and timestamps are preserved. Image updates can migrate "
        "persistent databases; reverting the lock alone does not undo those migrations. "
        "Review the compatibility matrix and artifacts before merging. A later accepted run "
        "replaces this proposal on the same branch.\n"
    )

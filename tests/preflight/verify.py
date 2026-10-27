"""Treat image-job artifacts as data; never execute an artifact's code or commands."""

from __future__ import annotations

import pathlib
from typing import Any

from .model import ROOT, build_plan, canonical, drift, fingerprint, load_json, rows


def check_result(plan: dict[str, Any], job: dict[str, Any], folder: pathlib.Path) -> pathlib.Path:
    result = load_json(folder / "result.json")
    expected = {
        "schema": 1,
        "plan": fingerprint(plan),
        "source": plan["source"],
        "run": plan["run"],
        "scenario": job["scenario"],
        "run_id": job["run_id"],
        "architecture": plan["architecture"],
        "rc": 0,
        "failures": 0,
        "skips": 0,
        "evidence_error": None,
    }
    if any(result.get(k) != v for k, v in expected.items()):
        raise ValueError(f"{job['scenario']}: stale, failed, skipped, or mismatched result")
    if type(result.get("passes")) is not int or result["passes"] < 1:
        raise ValueError("result contains no passing assertions")
    for field in ("elapsed_seconds", "disk_growth_bytes"):
        if type(result.get(field)) is not int or result[field] < 0:
            raise ValueError("result lacks resource measurements")
    images = load_json(folder / "images.json")
    events = load_json(folder / "events.json")
    if not images or not events:
        raise ValueError("result lacks runtime image and event evidence")
    check_companions(plan, events, images)
    receipt_path = folder / "receipts.tsv"
    if receipt_path.is_symlink() or receipt_path.stat().st_size > 1_000_000:
        raise ValueError("invalid receipt artifact")
    receipts = drift.read_pass_receipts(receipt_path)
    policy = drift.ReceiptPolicy(plan["source"], frozenset([job["run_id"]]), plan["architecture"])
    for service in job["services"]:
        ref = plan["effective"][service]
        image, digest = ref.rsplit("@", 1)
        row = drift.ImageDigest(service, image, digest)
        why = drift._receipt_failure(receipts.get(service, []), row, job["scenario"], policy)
        if why:
            raise ValueError(f"{service}/{job['scenario']}: {why}")
        if not any(
            digest in [d.rsplit("@", 1)[-1] for d in i.get("digests", []) or []] for i in images
        ):
            raise ValueError(f"{service}: candidate was not inspected in the image job")
    return receipt_path


def check_companions(plan: dict[str, Any], events: list[Any], images: list[Any]) -> None:
    latest = {}
    for event in events:
        if event["action"] == "start" and event["service"] in plan["effective"]:
            latest[event["service"]] = event["image"]
    if not latest:
        raise ValueError("no known service started in the scenario")
    for service, ref in latest.items():
        if ref != plan["effective"][service]:
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


def accept(
    plan: dict[str, Any], snapshot: pathlib.Path, results: pathlib.Path, output: pathlib.Path
) -> None:
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    current = rows(snapshot)
    rebuilt = build_plan(
        baseline, current, plan["selected"], plan["source"], plan["run"], plan["fixtures"]
    )
    if canonical(rebuilt) != canonical(plan):
        raise ValueError("snapshot and selection do not reproduce the trusted plan")
    if not plan["selected"]:
        raise ValueError("no candidates selected")
    receipts = []
    for job in plan["jobs"]:
        path = check_result(plan, job, results / ("result-" + job["scenario"]))
        receipts.append(path.read_text())
    # Validate the complete combination before writing any publication file.
    output.mkdir(parents=True, exist_ok=False)
    receipt_path = output / "receipts.tsv"
    receipt_path.write_text("\n".join(receipts))
    selected = set(plan["selected"])
    manifest = drift.read_preflights(ROOT / "docs/operations/upgrades.md")
    enriched = drift.enrich_rows(
        list(current.values()),
        list(baseline.values()),
        manifest,
        drift.datetime.now(drift.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    policy = drift.ReceiptPolicy(
        plan["source"], frozenset(j["run_id"] for j in plan["jobs"]), plan["architecture"]
    )
    drift.verify_preflight_receipts(
        selected, list(baseline.values()), enriched, drift.read_pass_receipts(receipt_path), policy
    )
    drift.write_tsv(
        output / "image-digests.lock",
        drift.merge_selective(list(baseline.values()), enriched, selected),
    )
    # No artifact value becomes a shell command, branch name or executable path.
    services = ", ".join(sorted(selected))
    evidence = [
        "",
        "Source: `" + plan["source"] + "`; workflow run: `" + plan["run"] + "`.",
        "",
        "| Scenario | Passed | Seconds | Disk growth (bytes) |",
        "|---|---:|---:|---:|",
    ]
    for job in plan["jobs"]:
        result = load_json(results / ("result-" + job["scenario"]) / "result.json")
        evidence.append(
            f"| {job['scenario']} | {result['passes']} | {result['elapsed_seconds']} | "
            f"{result['disk_growth_bytes']} |"
        )
    (output / "body.md").write_text(
        "## What & why\n\nUpdate tested Stable digests for " + services + ".\n\n"
        "## Linked issue\n\nPart of #134.\n\n## How it was verified\n\n"
        "Every required scenario passed without skips on the frozen candidate combination. "
        "Results bind the source commit, workflow run, architecture, companions and exact digests. "
        "Resource measurements and sanitized logs are in the workflow artifacts.\n"
        + "\n".join(evidence)
        + "\n\n"
        "## Notes\n\nOther lock rows and timestamps are preserved. Image updates can migrate "
        "persistent databases; reverting the lock alone does not undo those migrations. "
        "Review the compatibility matrix and artifacts before merging.\n"
    )

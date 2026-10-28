"""Frozen inputs and strict validation for the hosted image preflight."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import image_drift as drift  # noqa: E402

# Existing-install or behavioral gaps require an operator's separate review.
HELD = {
    "bazarr": "subtitle database migration is not covered",
    "beszel": "hub database migration is not covered",
    "portainer": "database migration is not covered",
    "uptime-kuma": "monitor history migration is not covered",
    "npm": "proxy and certificate database migration is not covered",
    "wireguard": "existing-peer migration is not covered",
    "flaresolverr": "health alone cannot prove a challenge solve",
}
# fail2ban needs upgrade-path: its regex-count exec runs only in scripts/update.sh.
EXTRA = {
    "ddns-updater": ["ddns-seed"],
    "socket-proxy": ["autoheal"],
    "fail2ban": ["fresh-install", "upgrade-path"],
}
FIXTURES = {
    "pebble": "ghcr.io/letsencrypt/pebble:latest",
    "challtestsrv": "ghcr.io/letsencrypt/pebble-challtestsrv:latest",
    "torznab": "python:3.12-alpine",
}
# Free space that a job must keep at its peak. Below this, a failure can come
# from the runner disk or from an image that writes much more data; the job
# cannot tell which, so it decides nothing.
HEADROOM_BYTES = 2 * 1024**3


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def load_json(path: pathlib.Path) -> Any:
    if path.is_symlink() or path.stat().st_size > 2_000_000:
        raise ValueError(f"invalid evidence file: {path.name}")
    return json.loads(path.read_text())


def headroom_error(result: dict[str, Any]) -> str | None:
    """Describe a job whose peak disk use left less than HEADROOM_BYTES free.

    The text shows the peak growth, so that an image that bloats the disk stays visible.
    """
    start, peak = result.get("disk_free_start_bytes"), result.get("disk_peak_growth_bytes")
    if type(start) is not int or type(peak) is not int or start - peak >= HEADROOM_BYTES:
        return None
    return (
        f"disk headroom exhausted (peak growth {peak} bytes, {start - peak} bytes free at "
        f"peak, below the {HEADROOM_BYTES}-byte minimum); cause not determined"
    )


def one_line(text: object) -> str:
    """Artifact text on one line. Callers print a trusted label first, so that
    no line of the log can start a workflow command."""
    return " ".join(str(text).split())


def source_sha() -> str:
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("source SHA is invalid")
    return sha


def rows(path: pathlib.Path) -> dict[str, drift.ImageDigest]:
    values = drift.read_tsv(path)
    indexed = {row.service: row for row in values}
    if not indexed or len(indexed) != len(values):
        raise ValueError("digest snapshot is empty or has duplicate services")
    for row in values:
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", row.digest):
            raise ValueError(f"invalid digest for {row.service}")
        if not re.fullmatch(r"[A-Za-z0-9._:/-]+", row.image):
            raise ValueError(f"invalid image for {row.service}")
    return indexed


def resolve(image: str) -> str:
    proc = subprocess.run(
        [
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            "--format",
            "{{json .Manifest.Digest}}",
            image,
        ],
        capture_output=True,
        text=True,
        timeout=90,
        check=True,
    )
    digest = json.loads(proc.stdout)
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError(f"registry returned an invalid digest for {image}")
    return digest


def required_scenarios(services: list[str]) -> dict[str, list[str]]:
    preflights = drift.read_preflights(ROOT / "docs/operations/upgrades.md")
    required = {}
    for service in services:
        names = drift.scenarios_of(preflights.get(service, ""))
        if not names:
            raise ValueError(f"{service} has no scenario oracle")
        required[service] = sorted(set(names + EXTRA.get(service, [])))
    return required


def make_job(
    plan: dict[str, Any], job_id: str, scenario: str, combination: list[str], services: list[str]
) -> dict[str, Any]:
    """One image job: the ``combination`` candidates run; ``services`` must prove ``scenario``."""
    return {
        "id": job_id,
        "scenario": scenario,
        "combination": combination,
        "services": services,
        "run_id": "run-20260101T000000Z-" + fingerprint([plan["source"], plan["run"], job_id])[:8],
    }


def build_plan(
    baseline: dict[str, drift.ImageDigest],
    current: dict[str, drift.ImageDigest],
    selected: list[str],
    source: str,
    run: str,
    fixtures: dict[str, str],
) -> dict[str, Any]:
    """Phase 1: each selected candidate runs alone with the accepted companions."""
    if baseline.keys() != current.keys():
        raise ValueError(
            "service additions and removals require a separate reviewed baseline change"
        )
    if any(current[s].image != baseline[s].image for s in baseline):
        raise ValueError("routine acceptance cannot change image tags or repositories")
    changed = {s for s in current if current[s].digest != baseline[s].digest}
    requested = set(selected) if selected else changed - HELD.keys()
    if len(set(selected)) != len(selected) or requested - changed or requested & HELD.keys():
        raise ValueError(
            "selection must name distinct, drifted services with complete automated coverage"
        )
    plan: dict[str, Any] = {
        "schema": 2,
        "phase": 1,
        "source": source,
        "run": run,
        "architecture": "x86_64",
        "accepted": {s: f"{r.image}@{r.digest}" for s, r in baseline.items()},
        "candidates": {s: f"{current[s].image}@{current[s].digest}" for s in sorted(requested)},
        "selected": sorted(requested),
        "fixtures": fixtures,
        "pending": {s: HELD.get(s, "not selected") for s in sorted(changed - requested)},
    }
    plan["jobs"] = [
        make_job(plan, f"p1-{service}.{scenario}", scenario, [service], [service])
        for service, scenarios in required_scenarios(plan["selected"]).items()
        for scenario in scenarios
    ]
    return plan


def combination_plan(
    parent: dict[str, Any],
    passed: list[str],
    failed: dict[str, list[str]],
    runner: dict[str, dict[str, str]] | None = None,
) -> dict[str, Any]:
    """Phase 2: freeze the combination of every candidate that passed phase 1.

    ``failed`` holds image failures. ``runner`` maps a candidate to the scenarios
    whose disk headroom ran out, with the measurement; those candidates neither
    pass nor fail.

    ``authority`` names the only evidence that may change the lock. A single
    passing candidate already ran as this exact combination in phase 1, so it
    needs no phase 2. Several passing candidates must pass again together.
    """
    authority = "none" if not passed else "phase-1" if len(passed) == 1 else "phase-2"
    plan = {key: parent[key] for key in ("schema", "source", "run", "architecture", "accepted")}
    plan.update(
        {
            "phase": 2,
            "parent": fingerprint(parent),
            "candidates": {s: parent["candidates"][s] for s in passed},
            "selected": passed,
            "fixtures": parent["fixtures"],
            "pending": parent["pending"],
            "failed": failed,
            "runner_failed": runner or {},
            "authority": authority,
        }
    )
    groups: dict[str, list[str]] = {}
    if authority == "phase-2":
        for service, scenarios in required_scenarios(passed).items():
            for scenario in scenarios:
                groups.setdefault(scenario, []).append(service)
    plan["jobs"] = [
        make_job(plan, f"p2-{scenario}", scenario, passed, services)
        for scenario, services in sorted(groups.items())
    ]
    return plan


def effective(plan: dict[str, Any], job: dict[str, Any]) -> dict[str, str]:
    """Every service reference one job runs: accepted companions plus its candidates."""
    refs = dict(plan["accepted"])
    refs.update({s: plan["candidates"][s] for s in job["combination"]})
    return refs


def check_plan(plan: dict[str, Any], source: str, run: str, expected_hash: str) -> None:
    # The run is "<run id>-<attempt>". "Re-run failed jobs" reuses attempt-1
    # job outputs, but which attempt's artifacts a re-run job reads is not
    # documented and upload-artifact will not overwrite a name; only a complete
    # re-run gives every job one coherent plan.
    if plan["run"] != run and plan["run"].rpartition("-")[0] == run.rpartition("-")[0]:
        raise ValueError(
            "plan comes from another attempt of this workflow run; partial re-runs are "
            "not supported, use Re-run all jobs"
        )
    if fingerprint(plan) != expected_hash or plan["source"] != source or plan["run"] != run:
        raise ValueError("plan does not match the source, workflow run, and immutable plan hash")
    if plan["schema"] != 2 or plan["architecture"] != "x86_64":
        raise ValueError("plan schema or architecture mismatch")
    if source_sha() != source:
        raise ValueError("checkout is not the source that was tested")
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    if plan["accepted"] != {s: f"{r.image}@{r.digest}" for s, r in baseline.items()}:
        raise ValueError("plan baseline does not match the accepted lock")
    if not set(plan["candidates"]) <= set(baseline) or set(plan["fixtures"]) != set(FIXTURES):
        raise ValueError("plan has an unexpected image population")
    for ref in [*plan["candidates"].values(), *plan["fixtures"].values()]:
        if not isinstance(ref, str) or not re.fullmatch(
            r"[A-Za-z0-9._:/-]+@sha256:[0-9a-f]{64}", ref
        ):
            raise ValueError("plan contains an invalid image reference")

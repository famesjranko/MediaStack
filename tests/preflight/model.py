"""Frozen inputs and strict validation for the manual hosted image preflight."""

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
EXTRA = {"ddns-updater": ["ddns-seed"], "socket-proxy": ["autoheal"], "fail2ban": ["fresh-install"]}
FIXTURES = {
    "pebble": "ghcr.io/letsencrypt/pebble:latest",
    "challtestsrv": "ghcr.io/letsencrypt/pebble-challtestsrv:latest",
    "torznab": "python:3.12-alpine",
}


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def load_json(path: pathlib.Path) -> Any:
    if path.is_symlink() or path.stat().st_size > 2_000_000:
        raise ValueError(f"invalid evidence file: {path.name}")
    return json.loads(path.read_text())


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
    parent: dict[str, Any], passed: list[str], failed: dict[str, list[str]]
) -> dict[str, Any]:
    """Phase 2: freeze the combination of every candidate that passed phase 1.

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

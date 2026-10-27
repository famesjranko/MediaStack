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


def build_plan(
    baseline: dict[str, drift.ImageDigest],
    current: dict[str, drift.ImageDigest],
    selected: list[str],
    source: str,
    run: str,
    fixtures: dict[str, str],
) -> dict[str, Any]:
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
    preflights = drift.read_preflights(ROOT / "docs/operations/upgrades.md")
    effective = {s: f"{r.image}@{r.digest}" for s, r in baseline.items()}
    groups: dict[str, list[str]] = {}
    for service in sorted(requested):
        required = drift.scenarios_of(preflights.get(service, ""))
        if not required:
            raise ValueError(f"{service} has no scenario oracle")
        effective[service] = f"{current[service].image}@{current[service].digest}"
        for scenario in sorted(set(required + EXTRA.get(service, []))):
            groups.setdefault(scenario, []).append(service)
    return {
        "schema": 1,
        "source": source,
        "run": run,
        "architecture": "x86_64",
        "baseline": fingerprint({s: f"{r.image}@{r.digest}" for s, r in baseline.items()}),
        "selected": sorted(requested),
        "effective": effective,
        "fixtures": fixtures,
        "pending": {s: HELD.get(s, "not selected") for s in sorted(changed - requested)},
        "jobs": [
            {
                "scenario": s,
                "services": v,
                "run_id": "run-20260101T000000Z-" + fingerprint([source, run, s])[:8],
            }
            for s, v in sorted(groups.items())
        ],
    }


def check_plan(plan: dict[str, Any], source: str, run: str, expected_hash: str) -> None:
    if fingerprint(plan) != expected_hash or plan["source"] != source or plan["run"] != run:
        raise ValueError("plan does not match the source, workflow run, and immutable plan hash")
    if source_sha() != source:
        raise ValueError("checkout is not the source that was tested")
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    actual = fingerprint({s: f"{r.image}@{r.digest}" for s, r in baseline.items()})
    if plan["baseline"] != actual or plan["architecture"] != "x86_64":
        raise ValueError("plan baseline or architecture mismatch")
    if set(plan["effective"]) != set(baseline) or set(plan["fixtures"]) != set(FIXTURES):
        raise ValueError("plan has an unexpected image population")
    for ref in [*plan["effective"].values(), *plan["fixtures"].values()]:
        if not isinstance(ref, str) or not re.fullmatch(
            r"[A-Za-z0-9._:/-]+@sha256:[0-9a-f]{64}", ref
        ):
            raise ValueError("plan contains an invalid image reference")

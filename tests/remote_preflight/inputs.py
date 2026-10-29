"""Validate frozen digests before contacting a disposable target."""

from __future__ import annotations

import os
import pathlib
import re
import secrets
import subprocess
from typing import Any

from preflight.model import ROOT, canonical, drift, fingerprint, load_json, rows, source_sha

STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
TARGET_KEYS = ("PROJECT_ID", "ZONE", "INSTANCE", "MACHINE_TYPE", "BOOT_DISK_SIZE")
SECRET_KEYS = ("DOMAIN", "NPM_ADMIN_EMAIL", "DDNS_PASSWORD")


def target_config() -> dict[str, str]:
    values = {key: os.environ.get(key, "") for key in (*TARGET_KEYS, *SECRET_KEYS)}
    if any(not value or "\n" in value or "\r" in value for value in values.values()):
        raise ValueError("missing or multiline GCP input; check tests/.env.gcp")
    for key in TARGET_KEYS:
        if not re.fullmatch(r"[a-zA-Z0-9.-]+", values[key]):
            raise ValueError(f"invalid GCP target field: {key}")
    target = "/".join(values[key] for key in ("PROJECT_ID", "ZONE", "INSTANCE"))
    if os.environ.get("GCP_EXPECT_TARGET") != target:
        raise ValueError("GCP_EXPECT_TARGET must match PROJECT_ID/ZONE/INSTANCE exactly")
    if os.environ.get("NPM_LE_SERVER", STAGING) != STAGING:
        raise ValueError("candidate checks require the Let's Encrypt staging endpoint")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", values["DOMAIN"]):
        raise ValueError("DOMAIN must be a DNS hostname")
    return values


def frozen_inputs(
    snapshot: pathlib.Path | None, plan_path: pathlib.Path | None, expected_hash: str | None
) -> dict[str, Any]:
    accepted = rows(ROOT / "docs/operations/image-digests.lock")
    refs = {s: f"{r.image}@{r.digest}" for s, r in accepted.items()}
    source = source_sha()
    origin_hash = ""
    if plan_path:
        hosted = load_json(plan_path)
        if fingerprint(hosted) != expected_hash or hosted.get("source") != source:
            raise ValueError("weekly plan hash or source differs from this checkout")
        if hosted.get("accepted") != refs or hosted.get("architecture") != "x86_64":
            raise ValueError("weekly plan baseline or architecture differs")
        current = hosted.get("snapshot")
        origin_hash = str(expected_hash)
    else:
        assert snapshot is not None
        current = {s: f"{r.image}@{r.digest}" for s, r in rows(snapshot).items()}
    if not isinstance(current, dict) or current.keys() != refs.keys():
        raise ValueError(
            "snapshot must contain every accepted service; older plans need --snapshot"
        )
    for service, ref in current.items():
        image = accepted[service].image
        if not isinstance(ref, str) or not re.fullmatch(
            re.escape(image) + r"@sha256:[0-9a-f]{64}", ref
        ):
            raise ValueError(f"snapshot changes the tag/repository or has a bad digest: {service}")
    if current["npm"] == refs["npm"]:
        raise ValueError("npm has no candidate digest drift")
    return {
        "schema": 1,
        "source": source,
        "architecture": "x86_64",
        "service": "npm",
        "accepted": refs,
        "candidate": current["npm"],
        "snapshot": current,
        "weekly_plan_hash": origin_hash,
    }


def write_inputs(plan: dict[str, Any], output: pathlib.Path) -> None:
    (output / "plan.json").write_bytes(canonical(plan) + b"\n")
    current = []
    for service, ref in plan["snapshot"].items():
        image, digest = ref.rsplit("@", 1)
        current.append(drift.ImageDigest(service, image, digest))
    drift.write_tsv(output / "current.tsv", current)


def clean_source() -> None:
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True
    )
    if status.strip():
        raise ValueError("commit all source changes before a live run")


def run_identity(plan: dict[str, Any]) -> tuple[str, str]:
    from datetime import datetime, timezone

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"run-{stamp}-{secrets.token_hex(4)}", fingerprint(plan)

"""Execute images on a disposable read-only runner and export only test evidence."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
from typing import Any

from .model import ROOT, canonical, effective, fingerprint


def docker(*args: str) -> str:
    return subprocess.check_output(["docker", *args], text=True, timeout=45)


def sanitize(text: str) -> str:
    text = text.replace('Fr3sh!$tack"with\\special#chars^&*', "[fixture password]")
    text = re.sub(r"(?i)(password|api.?key|token)([=:]\s*)[^\s,;]+", r"\1\2[redacted]", text)
    text = re.sub(r"[A-Za-z0-9_+/=-]{24,}", "[redacted value]", text)
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)


def evidence(name: str, output: pathlib.Path) -> None:
    raw = docker("exec", name, "cat", "/tmp/ms-receipt-events.jsonl")
    events = []
    for line in raw.splitlines():
        event = json.loads(line)
        if event.get("Type") != "container":
            continue
        actor = event["Actor"]
        attrs = actor["Attributes"]
        events.append(
            {
                "action": event["Action"],
                "id": actor["ID"],
                "service": attrs.get("com.docker.compose.service"),
                "image": attrs.get("image"),
            }
        )
    (output / "events.json").write_bytes(canonical(events))
    ids = docker("exec", name, "docker", "image", "ls", "-q").split()
    images = []
    for image_id in sorted(set(ids)):
        fmt = (
            '{"id":{{json .Id}},"digests":{{json .RepoDigests}},'
            '"arch":{{json .Architecture}},"os":{{json .Os}}}'
        )
        images.append(
            json.loads(
                docker("exec", name, "docker", "image", "inspect", "--format", fmt, image_id)
            )
        )
    (output / "images.json").write_bytes(canonical(images))
    logs = docker(
        "exec",
        "-w",
        "/root/MediaStack",
        name,
        "docker",
        "compose",
        "logs",
        "--no-color",
        "--tail",
        "40",
    )
    (output / "services.log").write_text(sanitize(logs))


def run_with_deadline(child_env: dict[str, str], scenario: str, log: Any) -> int:
    process = subprocess.Popen(
        ["bash", "tests/run.sh", "--no-cache", scenario],
        cwd=ROOT,
        env=child_env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=4200)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        return 124


def execute(plan: dict[str, Any], job_id: str, output: pathlib.Path) -> None:
    jobs = [j for j in plan["jobs"] if j["id"] == job_id]
    if len(jobs) != 1:
        raise ValueError("job is absent or ambiguous in the frozen plan")
    job = jobs[0]
    scenario = job["scenario"]
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)
    if dirty:
        raise ValueError("hosted preflight must run from a clean source checkout")
    name = "ms-hosted-" + fingerprint([plan["run"], job_id])[:12]
    output.mkdir(parents=True, exist_ok=False)
    receipts = output / "receipts.tsv"
    overrides = ",".join(f"{s}={ref}" for s, ref in sorted(effective(plan, job).items()))
    child_env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    child_env.update(
        {
            "DIND_NAME": name,
            "DIND_IMAGE": "ms-hosted-dind:debian",
            "KEEP_ALWAYS": "1",
            "MS_TEST_IMAGE_OVERRIDES": overrides,
            "MS_TEST_RUN_ID": job["run_id"],
            "RECEIPTS_FILE": str(receipts),
            "MS_TEST_NO_CACHE": "1",
            "MS_TEST_STRIP_SERVICES": "",
            "MS_TEST_PEBBLE_IMAGE": plan["fixtures"]["pebble"],
            "MS_TEST_CHALLTESTSRV_IMAGE": plan["fixtures"]["challtestsrv"],
            "MS_TEST_TORZNAB_IMAGE": plan["fixtures"]["torznab"],
        }
    )
    start, free = time.monotonic(), shutil.disk_usage(ROOT).free
    result: dict[str, Any] = {
        "schema": 1,
        "plan": fingerprint(plan),
        "source": plan["source"],
        "run": plan["run"],
        "job": job_id,
        "scenario": scenario,
        "run_id": job["run_id"],
        "architecture": os.uname().machine,
        "rc": 1,
        "passes": 0,
        "failures": 0,
        "skips": 0,
        "evidence_error": None,
    }
    with tempfile.TemporaryFile(mode="w+") as log:
        try:
            result["rc"] = run_with_deadline(child_env, scenario, log)
        finally:
            log.seek(0)
            text = sanitize(log.read())
            (output / "scenario.log").write_text(text)
            for key, marker in (("passes", "PASS"), ("failures", "FAIL"), ("skips", "SKIP")):
                result[key] = len(re.findall(r"^  \[" + marker + r"\] ", text, re.M))
            try:
                evidence(name, output)
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                result["evidence_error"] = sanitize(str(exc))
            result["elapsed_seconds"] = round(time.monotonic() - start)
            result["disk_growth_bytes"] = max(0, free - shutil.disk_usage(ROOT).free)
            (output / "result.json").write_bytes(canonical(result))
            subprocess.run(
                ["docker", "rm", "-fv", name], capture_output=True, timeout=60, check=False
            )
    print(json.dumps(result, indent=2))
    if (
        result["rc"]
        or result["failures"]
        or result["skips"]
        or not result["passes"]
        or result["evidence_error"]
    ):
        print(text[-12000:])
        raise ValueError(
            f"{job_id} did not produce complete passing evidence; inspect its artifact"
        )

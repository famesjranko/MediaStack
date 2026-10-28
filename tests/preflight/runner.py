"""Execute images on a disposable read-only runner and export only test evidence."""

from __future__ import annotations

import json
import os
import pathlib
import re
import signal
import subprocess
import tempfile
import threading
import time
from typing import Any, Callable

from .contracts import TRACED_SCENARIOS
from .model import ROOT, canonical, effective, fingerprint, headroom_error

SAMPLE_SECONDS = 2.0


def docker(*args: str) -> str:
    return subprocess.check_output(["docker", *args], text=True, timeout=45)


def sanitize(text: str) -> str:
    text = text.replace('Fr3sh!$tack"with\\special#chars^&*', "[fixture password]")
    text = re.sub(r"(?i)(password|api.?key|token)([=:]\s*)[^\s,;]+", r"\1\2[redacted]", text)
    text = re.sub(r"[A-Za-z0-9_+/=-]{24,}", "[redacted value]", text)
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)


def lifecycle_events(raw: str) -> list[dict[str, Any]]:
    """Container events from docker events JSON lines, reduced to their identity.

    Only the bare action is kept: "exec_create: <argv>" carries the exec command
    line, and beszel passes a password in its argv.
    """
    events = []
    for line in raw.splitlines():
        event = json.loads(line)
        if event.get("Type") != "container":
            continue
        actor = event["Actor"]
        attrs = actor["Attributes"]
        events.append(
            {
                "action": event["Action"].partition(":")[0].strip(),
                "id": actor["ID"],
                "service": attrs.get("com.docker.compose.service"),
                "image": attrs.get("image"),
            }
        )
    return events


def evidence(name: str, output: pathlib.Path) -> None:
    raw = docker("exec", name, "cat", "/tmp/ms-receipt-events.jsonl")
    events = lifecycle_events(raw)
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


def data_root() -> str:
    """The host filesystem that DinD fills: its /var/lib/docker volume lives under this root."""
    return docker("info", "--format", "{{.DockerRootDir}}").strip()


class DiskSampler:
    """Record the least free space on one filesystem while a scenario runs.

    End-of-run growth hides the peak, because scenarios remove images and
    containers before they end. A sampler that cannot measure the whole run
    reports an error and no numbers, so its result never qualifies.
    """

    def __init__(self, locate: Callable[[], str]) -> None:
        self.error: str | None = None
        self.samples = self.start = self.least = self.last = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        try:
            self.path = locate()
            self.start = self._sample()
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            self.error = "disk sampler could not start: " + sanitize(str(exc))
            return
        self._thread.start()

    def _sample(self) -> int:
        stat = os.statvfs(self.path)
        self.last = stat.f_bavail * stat.f_frsize
        self.least = min(self.least, self.last) if self.samples else self.last
        self.samples += 1
        return self.last

    def _loop(self) -> None:
        while not self._stop.wait(SAMPLE_SECONDS):
            try:
                self._sample()
            except OSError as exc:
                self.error = "disk sampler stopped: " + sanitize(str(exc))
                return

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join()

    def finish(self) -> dict[str, Any]:
        """Stop sampling and return the result fields, including end-of-run growth."""
        self.stop()
        if self.error is None:
            try:
                self._sample()
            except OSError as exc:
                self.error = "disk sampler stopped: " + sanitize(str(exc))
        measured = self.error is None
        return {
            "disk_error": self.error,
            "disk_samples": self.samples,
            "disk_free_start_bytes": self.start if measured else None,
            "disk_peak_growth_bytes": max(0, self.start - self.least) if measured else None,
            "disk_growth_bytes": max(0, self.start - self.last) if measured else None,
        }


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
    if scenario in TRACED_SCENARIOS:
        # contracts.json goes straight to the artifact, unsanitized: the
        # reducer writes no values, and sanitize would mangle entry ids. It
        # names only this job's candidates, not the accepted companions.
        child_env["MS_CONTRACTS_FILE"] = str(output / "contracts.json")
        child_env["MS_CONTRACT_CANDIDATES"] = ",".join(
            f"{s}={plan['candidates'][s]}" for s in sorted(job["combination"])
        )
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
    start, sampler = time.monotonic(), DiskSampler(data_root)
    try:
        with tempfile.TemporaryFile(mode="w+") as log:
            try:
                result["rc"] = run_with_deadline(child_env, scenario, log)
            finally:
                text = record(result, name, output, log, sampler, start)
    finally:
        sampler.stop()
    print(json.dumps(result, indent=2))
    if result["runner_error"]:
        print(text[-12000:])
        raise ValueError(f"{job_id}: undecided: {result['runner_error']}")
    if (
        result["rc"]
        or result["failures"]
        or result["skips"]
        or not result["passes"]
        or result["evidence_error"]
        or result["disk_error"]
    ):
        print(text[-12000:])
        raise ValueError(
            f"{job_id} did not produce complete passing evidence; inspect its artifact"
        )


def record(
    result: dict[str, Any],
    name: str,
    output: pathlib.Path,
    log: Any,
    sampler: DiskSampler,
    start: float,
) -> str:
    """Complete the result from the log, the DinD state and the disk samples."""
    log.seek(0)
    text = sanitize(log.read())
    for key, marker in (("passes", "PASS"), ("failures", "FAIL"), ("skips", "SKIP")):
        result[key] = len(re.findall(r"^  \[" + marker + r"\] ", text, re.M))
    try:
        evidence(name, output)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result["evidence_error"] = sanitize(str(exc))
    result["elapsed_seconds"] = round(time.monotonic() - start)
    result.update(sampler.finish())
    result["runner_error"] = headroom_error(result)
    # Remove DinD before writing the log and result: on a full disk those writes
    # would fail, and the job would read as an image failure.
    subprocess.run(["docker", "rm", "-fv", name], capture_output=True, timeout=60, check=False)
    (output / "scenario.log").write_text(text)
    (output / "result.json").write_bytes(canonical(result))
    return text

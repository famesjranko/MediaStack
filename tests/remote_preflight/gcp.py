"""GCP transport and cleanup for one explicitly named disposable VM."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from collections.abc import Callable
from typing import Any

from preflight.model import ROOT


def command(argv: list[str], data: bytes | None = None, timeout: int = 120) -> bytes:
    """Keep candidate output private and terminate the local process tree on interruption."""
    with subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    ) as proc:
        try:
            stdout, _ = proc.communicate(data, timeout=timeout)
            if proc.returncode:
                raise RuntimeError(f"command failed (exit {proc.returncode}); output withheld")
            return stdout
        except BaseException:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise


class Gcp:
    def __init__(self, config: dict[str, str], run_id: str, report: Callable[[str], None]) -> None:
        self.config, self.run_id, self.report = config, run_id, report
        self.attempted = False
        self.creation_acknowledged = False

    def call(self, *args: str, data: bytes | None = None, timeout: int = 120) -> bytes:
        return command(
            ["gcloud", "--quiet", f"--project={self.config['PROJECT_ID']}", *args], data, timeout
        )

    def instances(self) -> list[dict[str, Any]]:
        values: list[dict[str, Any]] = json.loads(
            self.call(
                "compute",
                "instances",
                "list",
                f"--filter=name={self.config['INSTANCE']}",
                "--format=json",
            )
        )
        return [v for v in values if v["zone"].rsplit("/", 1)[-1] == self.config["ZONE"]]

    def create(self) -> None:
        if self.instances():
            raise ValueError("target already exists; select a disposable unused INSTANCE")
        self.attempted = True  # A timed-out create can still have created a billable VM.
        self.call(
            "compute",
            "instances",
            "create",
            self.config["INSTANCE"],
            f"--zone={self.config['ZONE']}",
            f"--machine-type={self.config['MACHINE_TYPE']}",
            "--image-family=debian-12",
            "--image-project=debian-cloud",
            "--boot-disk-type=pd-standard",
            f"--boot-disk-size={self.config['BOOT_DISK_SIZE']}",
            "--tags=mediastack-public",
            "--no-service-account",
            "--no-scopes",
            "--max-run-duration=2h",
            "--instance-termination-action=DELETE",
            "--no-restart-on-failure",
            f"--labels=mediastack-preflight={self.run_id.lower()}",
            f"--metadata-from-file=startup-script={ROOT / 'tests/gcp-vm/startup.sh'}",
            timeout=300,
        )
        self.creation_acknowledged = True

    def ssh(self, script: str, data: bytes | None = None, timeout: int = 120) -> bytes:
        return self.call(
            "compute",
            "ssh",
            self.config["INSTANCE"],
            f"--zone={self.config['ZONE']}",
            f"--command={script}",
            "--",
            "-T",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            data=data,
            timeout=timeout,
        )

    def wait_ready(self) -> None:
        deadline = time.monotonic() + 360
        while time.monotonic() < deadline:
            try:
                self.ssh(
                    "test -d /opt/MediaStack && command -v git && command -v rsync", timeout=30
                )
                return
            except (RuntimeError, subprocess.TimeoutExpired):
                time.sleep(5)
        raise RuntimeError("startup/SSH readiness exceeded 360 seconds")

    def upload(self) -> None:
        archive = command(["git", "-C", str(ROOT), "archive", "HEAD"], timeout=60)
        self.ssh(
            "sudo chown $(id -u):$(id -g) /opt/MediaStack && tar -xf - -C /opt/MediaStack", archive
        )

    def wait_creation(self) -> bool:
        """An interrupted local gcloud does not cancel the server-side insert."""
        deadline = time.monotonic() + 300
        observed = False
        while time.monotonic() < deadline:
            pending = json.loads(
                self.call(
                    "compute",
                    "operations",
                    "list",
                    f"--zones={self.config['ZONE']}",
                    "--filter=operationType=insert AND status!=DONE AND "
                    f"targetLink~'/instances/{self.config['INSTANCE']}$'",
                    "--format=json",
                    timeout=30,
                )
            )
            if not pending:
                return observed
            observed = True
            time.sleep(2)
        raise RuntimeError("cleanup cannot verify deletion: cloud creation is still pending")

    def cleanup(self) -> None:
        if not self.attempted:
            return
        observed = self.wait_creation()
        # Do not delete a foreign VM if another operator raced this run's create.
        values = self.instances()
        if not values and not self.creation_acknowledged and not observed:
            raise RuntimeError("cleanup cannot verify an unacknowledged create; inspect target")
        if (
            values
            and values[0].get("labels", {}).get("mediastack-preflight") != self.run_id.lower()
        ):
            raise RuntimeError("cleanup refused: target does not carry this run's ownership label")
        if values:
            self.call(
                "compute",
                "instances",
                "delete",
                self.config["INSTANCE"],
                f"--zone={self.config['ZONE']}",
                timeout=180,
            )
        if self.instances():
            raise RuntimeError("cleanup failed: target VM still exists; no receipts published")
        self.report("Verified: disposable VM deleted (boot disk auto-delete enabled).")


def remote_step(
    gcp: Gcp, label: str, script: str, data: bytes | None = None, timeout: int = 180
) -> bytes:
    gcp.report(label)
    try:
        return gcp.ssh("cd /opt/MediaStack && " + script, data, timeout)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"{label} failed or exceeded its deadline; no receipt") from exc

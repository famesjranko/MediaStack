#!/usr/bin/env python3
"""Run a frozen NPM candidate on a disposable GCP host, then publish local evidence."""

from __future__ import annotations

import argparse
import ipaddress
import json
import pathlib
import shlex
import signal
import subprocess
import sys
from typing import Any

from preflight.model import canonical, drift, fingerprint
from remote_preflight import wan
from remote_preflight.gcp import Gcp, remote_step
from remote_preflight.inputs import (
    SECRET_KEYS,
    TARGET_KEYS,
    clean_source,
    frozen_inputs,
    run_identity,
    target_config,
    write_inputs,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "service", choices=["npm"], help="WireGuard and lab targets follow separately"
    )
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--snapshot", type=pathlib.Path, help="explicit frozen digest TSV")
    inputs.add_argument("--plan", type=pathlib.Path, help="weekly preflight-plan/plan.json")
    parser.add_argument("--plan-hash", help="weekly plan hash from the planner job output")
    parser.add_argument("--output", type=pathlib.Path, help="new local evidence directory")
    parser.add_argument("--preflight", action="store_true", help="validate offline; no cloud calls")
    args = parser.parse_args()
    if bool(args.plan) != bool(args.plan_hash):
        parser.error("--plan and --plan-hash must be used together")
    if not args.preflight and args.output is None:
        parser.error("live runs require --output <new-directory>")
    return args


def install(gcp: Gcp, config: dict[str, str]) -> None:
    inputs = canonical({key: config[key] for key in SECRET_KEYS})
    prepare = "python3 tests/fixtures/npm_state.py prepare"
    remote_step(gcp, "Prepare staging-only remote inputs", prepare, inputs)
    remote_step(
        gcp,
        "Install accepted lock with real setup --full",
        "timeout 2400 env DEMO=1 ./setup.sh --full",
        timeout=2460,
    )
    remote_step(gcp, "Restore remote inputs after Stage 1", prepare, inputs)
    answers = f"\n\n{config['DOMAIN']}\n1\n2\n{config['DDNS_PASSWORD']}\n\n\n\n100\n\n\n\n\n\n"
    remote_step(
        gcp,
        "Configure accepted WAN stack with real setup --remote",
        "timeout 1800 ./setup.sh --remote",
        answers.encode(),
        timeout=1860,
    )
    remote_step(
        gcp,
        "Seed and save representative accepted user state",
        "python3 tests/fixtures/upgrade_state.py seed && "
        "python3 tests/fixtures/upgrade_state.py save && "
        "python3 tests/fixtures/npm_state.py seed",
        timeout=300,
    )


def candidate(gcp: Gcp, plan: dict[str, Any], plan_hash: str) -> bytes:
    argv = [plan["candidate"], plan["source"], plan["run_id"], plan_hash]
    remote_step(
        gcp,
        "Upgrade candidate; compare before repair; reconfigure; renew staging certs",
        "timeout 1800 bash tests/gcp-vm/candidate-host.sh " + shlex.join(argv),
        timeout=1860,
    )
    state = json.loads(remote_step(gcp, "Read reduced NPM state", "cat /tmp/ms-npm-after.json"))
    instances = gcp.instances()
    ip = str(
        ipaddress.IPv4Address(instances[0]["networkInterfaces"][0]["accessConfigs"][0]["natIP"])
    )
    gcp.report("Prove public DNS, candidate HTTPS, renewed certificates and blocked admin ports")
    wan.check(gcp.config["DOMAIN"], ip, state)
    return remote_step(gcp, "Collect pending receipts", "cat /tmp/ms-remote-receipts.tsv")


def verify_receipt(raw: bytes, plan: dict[str, Any], plan_hash: str, output: pathlib.Path) -> None:
    path = output / "pending-receipts.tsv"
    path.write_bytes(raw)
    parsed = drift.read_pass_receipts(path)
    image, digest = plan["candidate"].rsplit("@", 1)
    policy = drift.ReceiptPolicy(
        plan["source"], frozenset([plan["run_id"]]), plan["architecture"], plan_hash
    )
    row = drift.ImageDigest("npm", image, digest)
    if sum(len(rows) for rows in parsed.values()) != 1 or drift._receipt_failure(
        parsed.get("npm", []), row, "remote-gcp", policy
    ):
        raise ValueError(
            "remote receipt does not match the exact source, digest, run, arch and plan"
        )


def execute(plan: dict[str, Any], config: dict[str, str], output: pathlib.Path) -> None:
    clean_source()
    if any(
        config[key] in ("your-gcp-project-id", "mediastack.example.org", "your-dynu-password")
        for key in ("PROJECT_ID", "DOMAIN", "DDNS_PASSWORD")
    ):
        raise ValueError("replace GCP credential placeholders before a live run")
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    plan["target"] = {key: config[key] for key in TARGET_KEYS}
    plan["run_id"], _ = run_identity(plan)
    plan_hash = fingerprint(plan)
    write_inputs(plan, output)

    def report(message: str) -> None:
        print(message, flush=True)
        with (output / "run.log").open("a") as log:
            log.write(message + "\n")

    gcp = Gcp(config, plan["run_id"], report)
    success = False
    try:
        report(
            "Create disposable VM: "
            + "/".join(config[k] for k in ("PROJECT_ID", "ZONE", "INSTANCE"))
        )
        gcp.create()
        report("Wait for guest startup and SSH")
        gcp.wait_ready()
        gcp.upload()
        remote_step(gcp, "Verify target architecture", 'test "$(uname -m)" = x86_64')
        install(gcp, config)
        verify_receipt(candidate(gcp, plan, plan_hash), plan, plan_hash, output)
        success = True
    finally:
        # A second interrupt must not skip cleanup. SIGKILL and a lost operator
        # host need the VM's two-hour DELETE deadline as a backstop.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            gcp.cleanup()
        except BaseException:
            (output / "pending-receipts.tsv").unlink(missing_ok=True)
            report("Cleanup NOT verified. Inspect the target immediately. No receipts published.")
            raise
        if not success:
            (output / "pending-receipts.tsv").unlink(missing_ok=True)
    (output / "pending-receipts.tsv").rename(output / "receipts.tsv")
    report(f"PASS npm remote-gcp; plan hash {plan_hash}; run {plan['run_id']}")
    (output / "summary.md").write_text(
        f"NPM remote-gcp passed. Target deletion verified.\n\n"
        f"Source: `{plan['source']}`\n\nPlan hash: `{plan_hash}`\n\nRun: `{plan['run_id']}`\n\n"
        "Proof: accepted installation; persistent user and NPM state before reconfiguration; "
        "staging renewal; public DNS and application HTTPS; blocked WAN admin ports.\n"
    )


def interrupted(signum: int, frame: Any) -> None:
    raise KeyboardInterrupt(f"signal {signum}")


def main() -> int:
    args = arguments()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        config = target_config()
        plan = frozen_inputs(args.snapshot, args.plan, args.plan_hash)
        if args.preflight:
            print("Offline preflight passed: frozen npm drift, target guard and staging are valid.")
            print("No cloud, SSH or live endpoint was contacted.")
        else:
            execute(plan, config, args.output)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        # These errors contain only trusted labels. Never emit subprocess output.
        print(f"Remote preflight failed: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Remote preflight interrupted; no receipts published.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

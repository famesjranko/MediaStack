#!/usr/bin/env python3
"""Manual hosted preflight: freeze inputs, run one job, select, verify, publish, report."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import pathlib
import sys
from typing import Any

from preflight.model import (
    FIXTURES,
    ROOT,
    build_plan,
    check_plan,
    drift,
    fingerprint,
    load_json,
    resolve,
    rows,
    source_sha,
)


def job_outputs(plan: dict[str, Any]) -> None:
    """Print GitHub job outputs; the hash travels independently of artifacts."""
    matrix = {"include": [{"job": j["id"], "scenario": j["scenario"]} for j in plan["jobs"]]}
    print(f"plan_hash={fingerprint(plan)}")
    print("matrix=" + json.dumps(matrix, separators=(",", ":")))
    print("has_work=" + str(bool(plan["jobs"])).lower())


def checked(path: pathlib.Path, args: argparse.Namespace, expected: str) -> dict[str, Any]:
    plan = load_json(path)
    check_plan(plan, args.source, args.run, expected)
    return plan  # type: ignore[no-any-return]


def prepare(args: argparse.Namespace) -> None:
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    images = drift.load_compose_images(ROOT / "docker-compose.yml")
    if {s for s, _ in images} != set(baseline):
        raise ValueError("compose services and accepted lock differ")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        values = list(pool.map(resolve, [image for _, image in images]))
        fixtures = dict(zip(FIXTURES, pool.map(resolve, FIXTURES.values())))
    current = {s: drift.ImageDigest(s, image, digest) for (s, image), digest in zip(images, values)}
    fixtures = {key: f"{FIXTURES[key]}@{value}" for key, value in fixtures.items()}
    selected = [s.strip() for s in args.services.split(",") if s.strip()]
    plan = build_plan(baseline, current, selected, source_sha(), args.run, fixtures)
    args.output.mkdir(parents=True, exist_ok=True)
    drift.write_tsv(args.output / "current.tsv", list(current.values()))
    (args.output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    summary = [
        "## Image compatibility plan: phase 1",
        "",
        "Source: `" + plan["source"] + "`",
        "",
        "Selected (each tested alone): " + (", ".join(plan["selected"]) or "none"),
        "",
        "Jobs: " + (", ".join(j["id"] for j in plan["jobs"]) or "none"),
        "",
        "Pending:",
    ]
    summary.extend(f"- {s}: {reason}" for s, reason in plan["pending"].items())
    (args.output / "summary.md").write_text("\n".join(summary) + "\n")
    job_outputs(plan)


def run(args: argparse.Namespace) -> None:
    from preflight.runner import execute

    execute(checked(args.plan, args, args.hash), args.job, args.output)


def select(args: argparse.Namespace) -> None:
    from preflight.verify import select_combination

    selection = select_combination(checked(args.plan, args, args.hash), args.results)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "plan.json").write_text(json.dumps(selection, indent=2) + "\n")
    summary = [
        "## Image compatibility plan: phase 2",
        "",
        "Passed phase 1: " + (", ".join(selection["selected"]) or "none"),
        "",
        "Failed phase 1: " + (", ".join(selection["failed"]) or "none"),
        "",
        "Authorizing evidence: " + selection["authority"],
        "",
        "Jobs: " + (", ".join(j["id"] for j in selection["jobs"]) or "none"),
    ]
    (args.output / "summary.md").write_text("\n".join(summary) + "\n")
    job_outputs(selection)
    print("authority=" + selection["authority"])


def verify(args: argparse.Namespace) -> None:
    from preflight.verify import accept

    phase1 = checked(args.plan, args, args.hash)
    phase2 = checked(args.selection, args, args.selection_hash)
    accept(phase1, phase2, args.plan.parent / "current.tsv", args.results, args.output)


def decide(args: argparse.Namespace) -> None:
    from preflight.publish import decide_from_files

    decision = decide_from_files(args.facts, args.proposed)
    print("action=" + decision.action)
    print("pr=" + (str(decision.pr) if decision.pr else ""))
    print("lease=" + decision.lease)
    print("reason=" + decision.reason)


def report(args: argparse.Namespace) -> None:
    from preflight.status import render

    plan = checked(args.plan, args, args.hash)
    selection = checked(args.selection, args, args.selection_hash) if args.selection_hash else None
    publication = {
        "result": args.publish_result,
        "outcome": args.outcome,
        "pr": args.pr,
        "reason": args.reason,
    }
    print(render(plan, selection, args.verified, publication, args.run_url), end="")


def parse() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    def command(name: str, *flags: str, planned: bool = True) -> argparse.ArgumentParser:
        sub = commands.add_parser(name)
        sub.set_defaults(func=globals()[name])
        if planned:
            for flag in ("--run", "--source", "--hash"):
                sub.add_argument(flag, required=True)
        for flag in (*flags, "--plan") if planned else flags:
            sub.add_argument(flag, type=pathlib.Path, required=True)
        return sub

    first = command("prepare", "--output", planned=False)
    first.add_argument("--run", required=True)
    first.add_argument("--services", default="")
    command("run", "--output").add_argument("--job", required=True)
    command("select", "--results", "--output")
    command("verify", "--selection", "--results", "--output").add_argument(
        "--selection-hash", required=True
    )
    command("decide", "--facts", planned=False).add_argument("--proposed", type=pathlib.Path)
    status = command("report")
    status.add_argument("--selection", type=pathlib.Path)
    status.add_argument("--run-url", required=True)
    for flag in (
        "--selection-hash",
        "--verified",
        "--publish-result",
        "--outcome",
        "--pr",
        "--reason",
    ):
        status.add_argument(flag, default="")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        arguments = parse()
        arguments.func(arguments)
    except (ValueError, OSError, KeyError) as exc:
        print(f"preflight refused: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

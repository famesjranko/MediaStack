#!/usr/bin/env python3
"""Hosted preflight: freeze inputs, run one job, select, verify, publish, report, notify."""

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
    one_line,
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
    from preflight.status import contract_lines
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
        "Undecided, disk headroom exhausted (cause not determined): "
        + (", ".join(selection["runner_failed"]) or "none"),
        "",
        "Contract failures: " + ("; ".join(contract_lines(selection["contracts"])) or "none"),
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


def undecided(
    selection: dict[str, Any] | None, args: argparse.Namespace
) -> dict[str, dict[str, str]]:
    """Candidates of a failed phase 2 whose failed jobs only ran out of disk headroom.

    Phase-2 results are read as data only, and they never change the lock.
    """
    from preflight.verify import phase_two_undecided

    if selection and args.combined == "failure" and args.results:
        return phase_two_undecided(selection, args.results)
    return {}


def contract_failures(
    selection: dict[str, Any] | None, args: argparse.Namespace
) -> dict[str, list[str]]:
    """Contract failures of a passing phase 2 that final verification refused.

    Phase-2 results are read as data only, and they never change the lock.
    """
    from preflight.verify import phase_two_contract_failures

    if selection and args.combined == "success" and args.verified == "failure" and args.results:
        return phase_two_contract_failures(selection, args.results)
    return {}


def decide(args: argparse.Namespace) -> None:
    from preflight.publish import decide, read_facts, rejected

    plan = checked(args.plan, args, args.hash)
    selection = checked(args.selection, args, args.selection_hash)
    proposed = args.proposed.read_text() if args.proposed and args.proposed.is_file() else None
    refused = rejected(plan, selection, args.verified, frozenset(undecided(selection, args)))
    decision = decide(proposed, refused, read_facts(args.facts))
    print("action=" + decision.action)
    print("pr=" + (str(decision.pr) if decision.pr else ""))
    print("lease=" + decision.lease)
    print("reason=" + decision.reason)


def run_context(args: argparse.Namespace) -> dict[str, str]:
    return {"url": args.run_url, "ref": args.ref, "default_branch": args.default_branch}


def report(args: argparse.Namespace) -> None:
    from preflight.status import render

    plan = checked(args.plan, args, args.hash)
    selection = checked(args.selection, args, args.selection_hash) if args.selection_hash else None
    jobs = {"combine": args.combined, "verify": args.verified, "publish": args.publish_result}
    publication = {"outcome": args.outcome, "pr": args.pr, "reason": args.reason}
    runner = undecided(selection, args)
    contract = contract_failures(selection, args)
    print(render(plan, selection, jobs, publication, run_context(args), runner, contract), end="")


def abort(args: argparse.Namespace) -> None:
    from preflight.status import abort as render_abort

    print(render_abort(args.plan_result, run_context(args)), end="")


def drift_changed(args: argparse.Namespace) -> None:
    from preflight.notify import drift_changed as changed

    print(str(changed(args.previous.read_text(), args.report.read_text())).lower())


def report_changed(args: argparse.Namespace) -> None:
    from preflight.notify import report_changed as changed

    comments = json.loads(args.comments.read_text())
    if not isinstance(comments, list):
        raise ValueError("issue comments are not a list of pages")
    print(str(changed(comments, args.report.read_text())).lower())


def parse() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    def command(name: str, *flags: str, planned: bool = True) -> argparse.ArgumentParser:
        sub = commands.add_parser(name)
        sub.set_defaults(func=globals()[name.replace("-", "_")])
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
    decision = command("decide", "--facts", "--selection")
    decision.add_argument("--selection-hash", required=True)
    decision.add_argument("--verified", required=True)
    decision.add_argument("--proposed", type=pathlib.Path)
    decision.add_argument("--combined", default="")
    decision.add_argument("--results", type=pathlib.Path)
    status = command("report")
    status.add_argument("--selection", type=pathlib.Path)
    status.add_argument("--results", type=pathlib.Path)
    for flag in (
        "--selection-hash",
        "--combined",
        "--verified",
        "--publish-result",
        "--outcome",
        "--pr",
        "--reason",
    ):
        status.add_argument(flag, default="")
    failed = command("abort", planned=False)
    failed.add_argument("--plan-result", required=True)
    command("drift-changed", "--previous", "--report", planned=False)
    command("report-changed", "--comments", "--report", planned=False)
    for sub in (status, failed):
        for flag in ("--run-url", "--ref", "--default-branch"):
            sub.add_argument(flag, required=True)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        arguments = parse()
        arguments.func(arguments)
    except (ValueError, OSError, KeyError) as exc:
        # The text may quote artifact data; the fixed prefix comes first.
        print(f"preflight refused: {one_line(exc)}", file=sys.stderr)
        raise SystemExit(1) from exc

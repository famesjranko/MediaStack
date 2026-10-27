#!/usr/bin/env python3
"""Manual hosted preflight: freeze inputs, execute one scenario, validate results."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import pathlib
import sys

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
        "## Image compatibility plan",
        "",
        "Source: `" + plan["source"] + "`",
        "",
        "Selected: " + (", ".join(plan["selected"]) or "none"),
        "",
        "Required scenarios: " + ", ".join(j["scenario"] for j in plan["jobs"]),
        "",
        "Pending:",
    ]
    summary.extend(f"- {s}: {reason}" for s, reason in plan["pending"].items())
    (args.output / "summary.md").write_text("\n".join(summary) + "\n")
    matrix = {"include": [{"scenario": job["scenario"]} for job in plan["jobs"]]}
    print(f"plan_hash={fingerprint(plan)}")
    print("matrix=" + json.dumps(matrix, separators=(",", ":")))
    print("has_work=" + str(bool(plan["jobs"])).lower())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "run", "verify"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--source")
    parser.add_argument("--hash")
    parser.add_argument("--services", default="")
    parser.add_argument("--scenario")
    parser.add_argument("--plan", type=pathlib.Path)
    parser.add_argument("--results", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
        return
    if not args.plan or not args.source or not args.hash:
        parser.error("run and verify require --plan, --source, and --hash")
    plan = load_json(args.plan)
    check_plan(plan, args.source, args.run, args.hash)
    if args.command == "run":
        from preflight.runner import execute

        execute(plan, args.scenario, args.output)
    else:
        from preflight.verify import accept

        if not args.results:
            parser.error("verify requires --results")
        accept(plan, args.plan.parent / "current.tsv", args.results, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as exc:
        print(f"preflight refused: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

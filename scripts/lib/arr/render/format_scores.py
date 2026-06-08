#!/usr/bin/env python3
"""Determine whether a quality profile's formatItems need updating.

Stdin: JSON of the specific quality profile (not the array).
Env:
    SCORES     — JSON object of name→score from config.yml.
    FORMAT_MAP — JSON object of name→id from existing custom formats.

Only the formats config.yml manages are compared; an absent or 0-scored live
item satisfies a desired score of 0.

Stdout: one status line:
    match                — live scores for the managed formats match config.yml.
    empty\t<put-body>    — no non-zero live scores yet; put-body has them populated.
    drift\t<details>     — a managed format's live score differs; no reconcile.
"""
import json
import os
import sys


def main() -> int:
    scores = json.loads(os.environ.get("SCORES", "{}"))
    format_map = json.loads(os.environ.get("FORMAT_MAP", "{}"))

    profile = json.load(sys.stdin)
    current_items = profile.get("formatItems", [])

    desired = []
    for name, score in scores.items():
        fmt_id = format_map.get(name)
        if fmt_id is None:
            continue
        desired.append({"format": fmt_id, "name": name, "score": score})

    if not desired:
        print("match")
        return 0

    desired_map = {d["format"]: d["score"] for d in desired}

    # All live scores, including the custom formats the app auto-adds to every
    # profile at score 0.
    current_all = {item["format"]: item.get("score", 0) for item in current_items}
    # A non-zero live score means the profile has been scored before — this
    # tells a fresh CREATE (empty -> PUT) apart from genuine drift. Keep the
    # 0-filter here: a brand-new profile already carries every custom format at
    # score 0, so without it the empty branch would never fire on first run.
    current_scored = {fmt: s for fmt, s in current_all.items() if s != 0}

    if not current_scored:
        profile["formatItems"] = desired
        print(f"empty\t{json.dumps(profile)}")
        return 0

    # Compare only the formats config.yml manages; a live item that is absent or
    # scored 0 satisfies a desired score of 0 (e.g. compact's x264/x265 = 0), so
    # a correctly-applied 0 no longer reads as drift. Because both sides share
    # exactly desired_map's keys, any inequality yields at least one real diff —
    # drift can never be reported with an empty detail list.
    current_for_desired = {fmt: current_all.get(fmt, 0) for fmt in desired_map}

    if current_for_desired == desired_map:
        print("match")
        return 0

    diffs = []
    for k in sorted(desired_map):
        cur = current_all.get(k, 0)
        want = desired_map[k]
        if cur != want:
            diffs.append(f"id={k} live={cur} config={want}")
    print(f"drift\t{'; '.join(diffs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

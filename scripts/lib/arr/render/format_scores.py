#!/usr/bin/env python3
"""Determine whether a quality profile's formatItems need updating.

Stdin: JSON of the specific quality profile (not the array).
Env:
    SCORES     — JSON object of name→score from config.yml.
    FORMAT_MAP — JSON object of name→id from existing custom formats.

Stdout: one status line:
    match                — current formatItems already match desired scores.
    empty\t<put-body>    — formatItems was empty; put-body has them populated.
    drift\t<details>     — formatItems non-empty and differs; no reconcile.
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

    current_scored = {
        item["format"]: item.get("score", 0)
        for item in current_items
        if item.get("score", 0) != 0
    }

    if not current_scored:
        profile["formatItems"] = desired
        print(f"empty\t{json.dumps(profile)}")
        return 0

    if current_scored == desired_map:
        print("match")
        return 0

    diffs = []
    all_keys = set(current_scored) | set(desired_map)
    for k in sorted(all_keys):
        cur = current_scored.get(k, 0)
        want = desired_map.get(k, 0)
        if cur != want:
            diffs.append(f"id={k} live={cur} config={want}")
    print(f"drift\t{'; '.join(diffs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

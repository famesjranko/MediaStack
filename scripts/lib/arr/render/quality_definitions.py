#!/usr/bin/env python3
# Compare desired quality definitions (from config.yml) against the live set
# Sonarr/Radarr returned from /api/v3/qualitydefinition, and emit PUT plans
# for the ones that differ.
#
# Stdin: JSON list of current definitions.
# Env DESIRED: JSON object mapping quality name -> {"min": ..., "preferred":
# ..., "max": ...}.
#
# Stdout: one line per definition that needs update, format:
#     <id>\t<put-body-json>
# (a tab-separated pair; body is a full PUT body built by cloning the current
# definition and overriding the three size fields).
#
# Stderr: one line per desired key that has no matching current quality, in
# the form "WARN\t<name>" — the caller decides how loudly to log that.
#
# Exit codes: always 0 on success; non-zero only on malformed input.
import json
import os
import sys


def _close(a: float, b: float, tol: float = 0.05) -> bool:
    # Sonarr/Radarr occasionally round stored values slightly (e.g. 67.5 → 67.5
    # but 17.1 → 17.1 on Sonarr, 17.0999... on some older builds). A small
    # tolerance avoids spurious rewrites that would no-op but still log noise.
    return abs(a - b) <= tol


def main() -> int:
    current = json.load(sys.stdin)
    desired_raw = os.environ.get("DESIRED", "{}")
    desired = json.loads(desired_raw) if desired_raw else {}

    by_name = {c["quality"]["name"]: c for c in current if "quality" in c}

    for name, vals in desired.items():
        match = by_name.get(name)
        if match is None:
            sys.stderr.write(f"WARN\t{name}\n")
            continue

        min_s = float(vals["min"])
        pref_s = float(vals["preferred"])
        max_s = float(vals["max"])

        if (
            _close(match.get("minSize", 0), min_s)
            and _close(match.get("preferredSize", 0), pref_s)
            and _close(match.get("maxSize", 0), max_s)
        ):
            continue

        body = dict(match)
        body["minSize"] = min_s
        body["preferredSize"] = pref_s
        body["maxSize"] = max_s
        sys.stdout.write(f"{match['id']}\t{json.dumps(body)}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Render a Sonarr/Radarr quality profile JSON payload.

Reads the default profile (JSON) on stdin and emits a transformed profile
on stdout with `allowed` flipped based on the enabled-quality-ID set.

Inputs (env vars):
    PROFILE_NAME     — display name for the new profile
    ENABLED_IDS      — JSON array of enabled quality IDs, e.g. "[4,5,6]"
    CUTOFF_ID        — integer cutoff quality ID
    UPGRADE_ALLOWED  — "true"/"false" (case-insensitive)

Output: profile JSON on stdout.
"""
import json
import os
import sys


def main() -> int:
    profile_name = os.environ["PROFILE_NAME"]
    enabled_ids = set(json.loads(os.environ["ENABLED_IDS"]))
    cutoff_id = int(os.environ["CUTOFF_ID"])
    upgrade_allowed = os.environ["UPGRADE_ALLOWED"].strip().lower() == "true"

    profile = json.loads(sys.stdin.read())
    items = profile.get("items", [])
    new_items = []
    for item in items:
        new_item = dict(item)
        if "quality" in new_item:
            new_item["allowed"] = new_item["quality"]["id"] in enabled_ids
        elif "items" in new_item:
            sub_items = []
            any_allowed = False
            for sub in new_item["items"]:
                new_sub = dict(sub)
                if "quality" in new_sub:
                    new_sub["allowed"] = new_sub["quality"]["id"] in enabled_ids
                    if new_sub["allowed"]:
                        any_allowed = True
                sub_items.append(new_sub)
            new_item["items"] = sub_items
            new_item["allowed"] = any_allowed
        new_items.append(new_item)

    new_profile = {
        "name": profile_name,
        "upgradeAllowed": upgrade_allowed,
        "cutoff": cutoff_id,
        "items": new_items,
        # Carry the template profile's language through. Dropping it makes
        # Radarr/Sonarr store the profile with a null language, which Radarr
        # renders as a blank " is wanted, but found <lang>" rejection on every
        # release, and Sonarr treats as "no filter" (grabs any language). Fall
        # back to Original (id -2, each title's native TMDB language) when the
        # template itself has none — Sonarr's stock profiles ship null.
        "language": profile.get("language") or {"id": -2, "name": "Original"},
        # Reject floor. Custom-format scores STEER selection; they must not act as
        # hidden hard-blocks (file size is gated by the quality_definitions bounds,
        # not here). -1000 sits below any realistic penalty stack (the default
        # scores bottom out around -120) so nothing is score-blocked by default,
        # while staying above -10000 for anyone who deliberately sets a format to
        # that hard-block value. Do NOT raise to 0 — that would turn every negative
        # score into a hard reject. See docs/reference/quality-bounds.md.
        "minFormatScore": -1000,
        "cutoffFormatScore": 0,
        "minUpgradeFormatScore": 1,
        "formatItems": profile.get("formatItems", []),
    }
    print(json.dumps(new_profile))
    return 0


if __name__ == "__main__":
    sys.exit(main())

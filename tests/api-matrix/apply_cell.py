#!/usr/bin/env python3
"""Apply one (resolution x size) quality cell to a LIVE Sonarr/Radarr via the
API, in place, for the api-matrix test harness.

This reuses the PRODUCT's composition (wizard_apply.compose_cell) and the
PRODUCT's renderers (render/quality_profile.py, render/quality_definitions.py) —
only the API transport here is test-owned. It is the render->API contract that
the day-2 "change quality profile" action wraps in UX; proving it here
in place (PUT same profile id, renaming across cells) de-risks that work.

Usage:
    apply_cell.py <app> <base_url> <api_key> <resolution> <size> [profile_id]

  app          sonarr | radarr (selects the *_qualities + bounds to use)
  base_url     e.g. http://localhost:8989/api/v3
  profile_id   id of the profile to PUT in place; if omitted, POST a new one

Prints the profile id used, so the caller can GET + assert it.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Optional

REPO: str = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "scripts", "setup"))
import wizard_apply  # noqa: E402  (product composition — reused, not duplicated)

RENDER: str = os.path.join(REPO, "scripts", "lib", "arr", "render")


def load_cell(resolution: str, size: str) -> dict[str, Any]:
    """Load and compose one product quality cell."""
    model = wizard_apply.load_quality_model(os.path.join(REPO, "scripts", "setup", "presets.yml"))
    return wizard_apply.compose_cell(model, resolution, size)


def select_template(profiles: list[dict[str, Any]], profile_id: Optional[str]) -> dict[str, Any]:
    """Select the requested live profile, retaining the adapter's fallback."""
    fallback = profiles[0]
    if profile_id:
        return next((p for p in profiles if str(p.get("id")) == str(profile_id)), fallback)
    return fallback


def api(method: str, url: str, key: str, body: Optional[dict[str, Any]] = None) -> Any:
    # Sonarr/Radarr can transiently 409 a profile/definition PUT fired right
    # after a prior mutation to the same resource (still settling internally).
    # An unretried 409 here used to drop the PUT silently: the live profile
    # stayed on the PREVIOUS cell's state and every later assertion compared
    # against stale data. Retry the same idempotent PUT/POST before
    # giving up so a transient conflict can't masquerade as a landed change.
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
    )
    attempts = 3
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            if exc.code != 409 or attempt == attempts:
                raise
            time.sleep(0.5 * attempt)
    return None


def render_profile(
    template: dict[str, Any], name: str, enabled_ids: list[Any], cutoff: Any
) -> dict[str, Any]:
    """Reuse render/quality_profile.py: flip `allowed` on the template profile."""
    env = dict(
        os.environ,
        PROFILE_NAME=name,
        ENABLED_IDS=json.dumps(enabled_ids),
        CUTOFF_ID=str(cutoff),
        UPGRADE_ALLOWED="true",
    )
    out = subprocess.run(
        [sys.executable, os.path.join(RENDER, "quality_profile.py")],
        input=json.dumps(template).encode(),
        env=env,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    return json.loads(out)


def push_definitions(base: str, key: str, desired: dict[str, Any]) -> None:
    """Reuse render/quality_definitions.py: PUT the global tiers that differ."""
    current = api("GET", base + "/qualitydefinition", key)
    env = dict(os.environ, DESIRED=json.dumps(desired))
    out = subprocess.run(
        [sys.executable, os.path.join(RENDER, "quality_definitions.py")],
        input=json.dumps(current).encode(),
        env=env,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout.decode()
    for line in out.splitlines():
        if not line.strip():
            continue
        def_id, put_body = line.split("\t", 1)
        api("PUT", f"{base}/qualitydefinition/{def_id}", key, json.loads(put_body))


def apply_profile(
    base: str,
    key: str,
    template: dict[str, Any],
    rendered: dict[str, Any],
    profile_id: Optional[str],
) -> Any:
    """Push one rendered quality profile, creating or updating in place."""
    if profile_id:
        # In-place rename + repush: merge the rendered fields onto the full live
        # profile so id/language/etc. survive the PUT.
        merged = dict(template)
        merged.update(
            {
                "name": rendered["name"],
                "cutoff": rendered["cutoff"],
                "upgradeAllowed": rendered["upgradeAllowed"],
                "items": rendered["items"],
            }
        )
        merged["id"] = int(profile_id)
        api("PUT", f"{base}/qualityprofile/{profile_id}", key, merged)
        return profile_id

    created = api("POST", base + "/qualityprofile", key, rendered)
    return created["id"]


def main() -> None:
    app, base, key, res, size = sys.argv[1:6]
    profile_id = sys.argv[6] if len(sys.argv) > 6 else None

    cell = load_cell(res, size)
    enabled = cell[f"{app}_qualities"]

    profiles = api("GET", base + "/qualityprofile", key) or []
    template = select_template(profiles, profile_id)
    rendered = render_profile(template, cell["profile_name"], enabled, cell["cutoff_id"])
    used = apply_profile(base, key, template, rendered, profile_id)

    push_definitions(base, key, cell["quality_definitions"][app])
    print(used)


if __name__ == "__main__":
    main()

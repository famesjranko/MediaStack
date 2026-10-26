#!/usr/bin/env python3
"""Select the Homepage Jellyfin widget API from a bounded public response."""

from __future__ import annotations

import json
import re
import sys
from typing import Any

MAX_RESPONSE_BYTES = 65_536
VERSION_RE = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)(?:\.([0-9]+))?\Z")


def jellyfin_widget_version(value: Any) -> str | None:
    """Return Homepage's compatible widget mode for a final Jellyfin version."""
    if not isinstance(value, str):
        return None
    match = VERSION_RE.fullmatch(value)
    if match is None:
        return None
    version = tuple(int(part or 0) for part in match.groups())
    return "1" if version < (10, 12, 0, 0) else "2"


def main() -> int:
    """Read one extra byte so oversized responses are never accepted."""
    response = sys.stdin.buffer.read(MAX_RESPONSE_BYTES + 5)
    if len(response) > MAX_RESPONSE_BYTES + 4 or not response.endswith(b"\n200"):
        return 1
    body = response[:-4]
    try:
        payload = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return 1
    if not isinstance(payload, dict):
        return 1
    version = jellyfin_widget_version(payload.get("Version"))
    if version is None:
        return 1
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

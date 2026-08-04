#!/usr/bin/env python3
"""Filter Torznab caps XML into a per-app category ID list.

Reads Torznab caps XML on stdin. Emits a sorted JSON array of category IDs
appropriate for the target app (sonarr or radarr) on stdout.

Usage:
    torznab_caps.py <sonarr|radarr>

Category classification:
- Standard Torznab ranges — split by app:
    2xxx (Movies)       -> radarr
    5xxx (TV)           -> sonarr
    8xxx (Other)        -> both apps
- Native 100xxx categories: classified by category name (anime, documentary,
  etc.), then filtered by app. Without these, Radarr's add-time test fails
  for indexers like thepiratebay and limetorrents whose browse results use
  native IDs.
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET


def _read_categories(tree: ET.ElementTree[ET.Element[str]]) -> dict[int, str]:
    all_cats = {}
    for cat in tree.iter("category"):
        cid = cat.get("id", "")
        if cid.isdigit():
            all_cats[int(cid)] = cat.get("name", "")
        for sub in cat.findall("subcat"):
            sid = sub.get("id", "")
            if sid.isdigit():
                all_cats[int(sid)] = sub.get("name", "")
    return all_cats


def _native_category_matches(code: int, name: str, app: str) -> bool:
    if code < 100000:
        return False
    nl = name.lower()
    primary = re.split(r"[\s/\-]", nl)[0]
    is_movie = primary in ("movies", "movie", "film") or ("movie" in nl and "tv" not in nl)
    is_tv = primary == "tv" or "tv show" in nl
    is_doc = primary in ("documentary", "documentaries")
    is_anime = False
    if primary == "anime":
        skip = any(x in nl for x in ("manga", "picture", "image", "music"))
        if not skip and "audio" in nl and "dual audio" not in nl:
            skip = True
        is_anime = not skip
    is_video = primary == "video"
    return (app == "radarr" and (is_movie or is_doc or is_anime or is_video)) or (
        app == "sonarr" and (is_tv or is_doc or is_anime)
    )


def _category_matches(code: int, name: str, app: str) -> bool:
    if 2000 <= code < 3000:
        return app == "radarr"
    if 5000 <= code < 6000:
        return app == "sonarr"
    if 8000 <= code < 9000:
        return True
    return _native_category_matches(code, name, app)


def _filter_categories(all_cats: dict[int, str], app: str) -> set[int]:
    filtered = set()
    for code, name in all_cats.items():
        if _category_matches(code, name, app):
            filtered.add(code)
    return filtered


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("sonarr", "radarr"):
        print("usage: torznab_caps.py <sonarr|radarr>", file=sys.stderr)
        return 2
    app = sys.argv[1]

    all_cats = _read_categories(ET.parse(sys.stdin))
    filtered = _filter_categories(all_cats, app)
    print(json.dumps(sorted(filtered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

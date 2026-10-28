#!/usr/bin/env python3
"""tests/contracts/replay.py — upstream-spec check for tests/contracts/*.yml.

For each contract carrying an `openapi:` URL, fetch (or reuse a local cache
of) the upstream spec and check that every declared endpoint's method+path
still exists there. Network failure or a spec that is not machine-readable
JSON is reported as a clearly labelled SKIP, not an error, so the check
degrades gracefully offline. It diffs only the routes each contract declares,
never the whole spec.

Whether each endpoint still answers and still returns its declared `reads`
is proved against real traffic instead: the traced DinD scenarios record
every product request (tests/lib/contract-trace.sh, tests/contracts/observe.py)
and the hosted preflight's contract gate judges it.

Usage: replay.py spec [--service NAME]... [--cache-dir DIR]
Contract file format: tests/contracts/README.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import yaml

CONTRACT_DIR = Path(__file__).resolve().parent
DEFAULT_CACHE_DIR = CONTRACT_DIR / ".spec-cache"
FETCH_TIMEOUT = 10


def _load_contracts(only: list[str] | None) -> dict[str, dict[str, Any]]:
    contracts: dict[str, dict[str, Any]] = {}
    for path in sorted(CONTRACT_DIR.glob("*.yml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            continue
        service = str(data.get("service", ""))
        if not service:
            continue
        if only and service not in only:
            continue
        contracts[service] = data
    return contracts


def _join_path(base_path: str, path: str) -> str:
    joined = f"{base_path.rstrip('/')}/{path.lstrip('/')}"
    return re.sub(r"/{2,}", "/", joined)


def _normalize_template(path: str) -> str:
    """Collapse any `{param}` segment to `{id}` so a spec's own parameter
    name (`{seriesId}`, `{profileId}`, ...) doesn't block the comparison —
    only path *shape* is being checked here."""
    return re.sub(r"\{[^}/]+\}", "{id}", path)


def _fetch_spec(url: str, cache_dir: Path) -> tuple[dict[str, Any] | None, str]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / (re.sub(r"[^A-Za-z0-9_.-]", "_", url) + ".json")
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT) as response:
            raw = response.read()
        cache_path.write_bytes(raw)
        source = "network"
    except (urllib.error.URLError, TimeoutError, OSError):
        if not cache_path.exists():
            return None, "offline and no local cache — skipping"
        raw = cache_path.read_bytes()
        source = "cache"
    try:
        spec = json.loads(raw)
    except json.JSONDecodeError:
        return None, "spec is not machine-readable JSON — skipping"
    if not isinstance(spec, dict) or "paths" not in spec:
        return None, "spec has no 'paths' — skipping"
    return spec, source


def _spec_routes(spec: dict[str, Any]) -> set[tuple[str, str]]:
    routes: set[tuple[str, str]] = set()
    for raw_path, methods in (spec.get("paths") or {}).items():
        if not isinstance(methods, dict):
            continue
        template = _normalize_template(str(raw_path))
        for method in methods:
            if method.upper() in {"GET", "POST", "PUT", "PATCH", "DELETE"}:
                routes.add((method.upper(), template))
    return routes


def run_spec_mode(services: list[str] | None, cache_dir: Path) -> int:
    contracts = _load_contracts(services)
    errors: list[str] = []
    skips: list[str] = []
    checked = 0
    for service, contract in contracts.items():
        openapi_url = contract.get("openapi")
        if not openapi_url:
            skips.append(f"{service}: no openapi: URL")
            continue
        spec, note = _fetch_spec(str(openapi_url), cache_dir)
        if spec is None:
            skips.append(f"{service}: {note}")
            continue
        routes = _spec_routes(spec)
        base_path = str(contract.get("base_path", ""))
        for endpoint in contract.get("endpoints", []):
            # An entry with its own base_path, such as the readiness probe at
            # the service root, is outside the API the spec documents.
            if "base_path" in endpoint:
                continue
            checked += 1
            method = str(endpoint.get("method", "")).upper()
            full_path = _normalize_template(_join_path(base_path, str(endpoint.get("path", ""))))
            # Some upstreams document a singleton config resource's mutating
            # method only on a RestController-style `.../{id}` route even
            # though callers never send an id (Sonarr/Radarr config/naming,
            # config/mediamanagement, config/host all do this) — accept that
            # shape too rather than flagging a false positive every time.
            id_variant = f"{full_path}/{{id}}"
            if (method, full_path) not in routes and (method, id_variant) not in routes:
                errors.append(
                    f"{service} {endpoint.get('id')}: {method} {full_path} "
                    f"not found in {openapi_url} ({note})"
                )
    for skip in skips:
        print(f"replay: spec: SKIP {skip}", file=sys.stderr)
    for error in errors:
        print(f"replay: spec: error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"replay: spec: {checked} endpoint(s) checked, {len(skips)} service(s) skipped")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="mode", required=True)
    spec_parser = sub.add_parser(
        "spec", help="validate contracts against cached/fetched OpenAPI specs"
    )
    spec_parser.add_argument("--service", dest="services", action="append", default=None)
    spec_parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR)
    args = parser.parse_args(argv)
    return run_spec_mode(args.services, args.cache_dir)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""tests/contracts/replay.py — drift replayer for tests/contracts/*.yml.

Two modes; both diff only the fields each contract declares — never
whole-spec or whole-response validation:

  spec   For each contract carrying an `openapi:` URL, fetch (or reuse a
         local cache of) the upstream spec and check that every declared
         endpoint's method+path still exists there. Network failure or a
         spec that is not machine-readable JSON is reported as a clearly
         labelled SKIP, not an error — this mode must degrade gracefully
         offline (see the ticket's "graceful, clearly-reported skip").

  live   Against a real running container (base URL + credential supplied by
         the caller — the image-bump preflight's bring-up, never the mock),
         replay each contract's safe, idempotent GET endpoints (no `{id}`
         path substitution, so nothing caller-specific is guessed) and diff
         only the declared `reads` fields against the live response. Mutating
         endpoints (POST/PUT/DELETE) are not replayed live — doing so would
         mutate a real preflight container. Their shape is covered by spec
         mode's method+path check instead; this is a deliberate scope line,
         not an oversight (see tests/contracts/README.md).

         Request auth is entirely shape-driven from each contract's own
         `auth:` block (`header`, `bearer`, `cookie`, `query`, optionally a
         `format` template for a structured header value) — see
         `_apply_auth`. A service needing a supplementary session cookie
         alongside its primary credential (Jackett: `apikey` query param
         *and* a UI session) takes one via `--cookie NAME:RAW_COOKIE_HEADER`.
         Only GET endpoints with a declared `reads` field are eligible
         (nothing else to diff, and forcing a request anyway would false-fail
         on routes that don't answer generically outside their own flow).

Contract file format: tests/contracts/README.md. This file never runs the
mock (tests/mock/serve.py) — that is the mock-mode scenario's job, not
drift's (division of labor, tests/README.md).
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


# --- spec mode -------------------------------------------------------------


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
            skips.append(f"{service}: no openapi: URL — live-replay-only service")
            continue
        spec, note = _fetch_spec(str(openapi_url), cache_dir)
        if spec is None:
            skips.append(f"{service}: {note}")
            continue
        routes = _spec_routes(spec)
        base_path = str(contract.get("base_path", ""))
        for endpoint in contract.get("endpoints", []):
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


# --- live mode ---------------------------------------------------------


def _get_dotted(value: Any, parts: list[str]) -> tuple[bool, Any]:
    head, *rest = parts
    if head.endswith("[]"):
        key = head[:-2]
        if not isinstance(value, dict) or key not in value:
            return False, None
        items = value[key]
        if not isinstance(items, list) or not items:
            return True, None  # empty array: nothing to check further, not a drift
        return _get_dotted(items[0], rest) if rest else (True, items)
    if not isinstance(value, dict) or head not in value:
        return False, None
    return _get_dotted(value[head], rest) if rest else (True, value[head])


def _apply_auth(auth: dict[str, Any], credential: str, url: str) -> tuple[str, dict[str, str]]:
    """Shape-driven request auth: returns the (possibly query-amended) URL and
    the headers to send, from the contract's own `auth:` block — never a
    per-service branch here. Recognised `type` values:

      header  Sets header `name` to `credential`, or to `format` with the
              literal substring `{key}` replaced by `credential` when the
              upstream needs a structured header value (e.g. Jellyfin's
              `MediaBrowser Client="...", Token="{key}"` scheme).
      bearer  Sets header `name` to `Bearer <credential>`.
      cookie  Sets the `Cookie` header to `<name>=<credential>`.
      query   Appends `<name>=<credential>` to the URL's query string.

    Unrecognised/absent `type` sends no auth at all (`type: none`, matching
    spec mode's already-established convention)."""
    kind = auth.get("type", "none")
    name = str(auth.get("name", ""))
    if kind == "header":
        fmt = auth.get("format")
        value = str(fmt).replace("{key}", credential) if fmt else credential
        return url, {name: value}
    if kind == "bearer":
        return url, {name: f"Bearer {credential}"}
    if kind == "cookie":
        return url, {"Cookie": f"{name}={credential}"}
    if kind == "query":
        separator = "&" if "?" in url else "?"
        return f"{url}{separator}{name}={credential}", {}
    return url, {}


def _parse_service_arg(value: str) -> tuple[str, str, str]:
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("expected NAME:BASE_URL:CREDENTIAL")
    name, scheme_rest = parts[0], f"{parts[1]}:{parts[2]}"
    base_url, _, credential = scheme_rest.rpartition(":")
    if not base_url or not credential:
        raise argparse.ArgumentTypeError("expected NAME:BASE_URL:CREDENTIAL")
    return name, base_url, credential


def _parse_cookie_arg(value: str) -> tuple[str, str]:
    """`--cookie NAME:RAW_COOKIE_HEADER` — a supplementary `Cookie` header
    sent alongside a service's primary auth (e.g. Jackett, which needs both
    its `apikey` query credential AND a UI session cookie the API alone
    doesn't carry). Split on the first `:` only: the header value itself may
    legitimately contain further `:` or `;`-separated cookie pairs."""
    name, sep, header = value.partition(":")
    if not sep or not name or not header:
        raise argparse.ArgumentTypeError("expected NAME:RAW_COOKIE_HEADER")
    return name, header


def _missing_reads(endpoint: dict[str, Any], body: Any) -> list[str]:
    if isinstance(body, list):
        if not body:
            return []  # empty list: nothing to diff, not a drift
        body = body[0]
    elif isinstance(body, dict) and body and all(isinstance(v, dict) for v in body.values()):
        # A collection keyed by id/name rather than indexed by position (e.g.
        # qBittorrent's GET /torrents/categories, keyed by category name) —
        # the same "diff the first member" rule as a list, generalized to a
        # mapping shape. Only fires when EVERY top-level value is itself a
        # mapping — a plain object with one nested field among scalar
        # siblings (e.g. Seerr's settings/main) never matches this.
        body = next(iter(body.values()))
    missing = []
    for field in endpoint.get("reads", []):
        present, _ = _get_dotted(body, str(field).split("."))
        if not present:
            missing.append(str(field))
    return missing


def _eligible_endpoints(contract: dict[str, Any]) -> list[dict[str, Any]]:
    """Safe, idempotent, diffable: GET, no `{id}` (caller-scoped/mutating —
    spec mode's job), and at least one declared `reads` field (nothing else
    to diff, and forcing a request anyway risks a false failure on an
    endpoint that isn't meant to answer generically outside its own flow —
    e.g. Jackett's HTML dashboard page, or Jellyfin's Startup/* routes once
    the setup wizard has locked them)."""
    return [
        e
        for e in contract.get("endpoints", [])
        if str(e.get("method", "")).upper() == "GET"
        and "{id}" not in str(e.get("path", ""))
        and e.get("reads")
    ]


def _replay_endpoint(
    service: str,
    base_url: str,
    base_path: str,
    auth: dict[str, Any],
    credential: str,
    extra_cookie: str | None,
    endpoint: dict[str, Any],
) -> str | None:
    """Replay one endpoint. Returns an error string, or None on success."""
    path = str(endpoint.get("path", ""))
    full_url = base_url.rstrip("/") + _join_path(base_path, path)
    url, headers = _apply_auth(auth, credential, full_url)
    if extra_cookie:
        existing = headers.get("Cookie")
        headers["Cookie"] = f"{existing}; {extra_cookie}" if existing else extra_cookie
    try:
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
            body = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError, ValueError) as exc:
        return f"{service} {endpoint.get('id')}: GET {url} failed: {exc}"
    missing = _missing_reads(endpoint, body)
    if missing:
        fields = ", ".join(missing)
        return f"{service} {endpoint.get('id')}: reads field(s) '{fields}' missing live"
    return None


def run_live_mode(targets: list[tuple[str, str, str]], cookies: dict[str, str]) -> int:
    contracts = _load_contracts([name for name, _, _ in targets])
    errors: list[str] = []
    skips: list[str] = []
    checked = 0
    for service, base_url, credential in targets:
        contract = contracts.get(service)
        if contract is None:
            skips.append(f"{service}: no contract file")
            continue
        base_path = str(contract.get("base_path", ""))
        auth = contract.get("auth") or {}
        extra_cookie = cookies.get(service)
        endpoints = _eligible_endpoints(contract)
        if not endpoints:
            skips.append(f"{service}: no eligible GET endpoints (GET, no {{id}}, declared reads)")
            continue
        for endpoint in endpoints:
            checked += 1
            error = _replay_endpoint(
                service, base_url, base_path, auth, credential, extra_cookie, endpoint
            )
            if error:
                errors.append(error)
    for skip in skips:
        print(f"replay: live: SKIP {skip}", file=sys.stderr)
    for error in errors:
        print(f"replay: live: error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"replay: live: {checked} GET endpoint(s) diffed")
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

    live_parser = sub.add_parser("live", help="replay safe GET requests against real containers")
    live_parser.add_argument(
        "--service",
        dest="targets",
        action="append",
        required=True,
        type=_parse_service_arg,
        metavar="NAME:BASE_URL:CREDENTIAL",
    )
    live_parser.add_argument(
        "--cookie",
        dest="cookies",
        action="append",
        default=[],
        type=_parse_cookie_arg,
        metavar="NAME:RAW_COOKIE_HEADER",
    )

    args = parser.parse_args(argv)
    if args.mode == "spec":
        return run_spec_mode(args.services, args.cache_dir)
    return run_live_mode(args.targets, dict(args.cookies))


if __name__ == "__main__":
    raise SystemExit(main())

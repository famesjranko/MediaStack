#!/usr/bin/env python3
"""tests/mock/serve.py — one generic, contract-driven mock HTTP server.

Owns: mapping an incoming HTTP request to the contract endpoint it matches,
shape-checking auth, and returning a canned fixture response. Zero
per-service branches: every per-service detail (routes, auth shape, canned
bodies) lives in tests/contracts/*.yml and tests/mock/fixtures/, never here.

Stateless by design (see tests/contracts/README.md "Target shape" and
TARGET.md "Prescribed decisions"): every request is answered purely from the
matched contract endpoint's fixture file, and every request is appended to a
JSONL journal so scenarios can assert on the sequence and fields sent. The
one bounded exception is the ordered-`responses:` cursor below, which exists
solely to consume a fixture's declared retry/failure sequence in order — it
is not read-your-writes service state. If a flow needs more than that, it
belongs in tests/api-matrix/, not here.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTRACTS_DIR = REPO_ROOT / "tests" / "contracts"
DEFAULT_FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


class Endpoint:
    """One contract endpoint: a method + compiled path-match regex."""

    def __init__(self, base_path: str, data: dict[str, Any]) -> None:
        self.id = str(data["id"])
        self.method = str(data["method"]).upper()
        self.path = str(data["path"])
        self.reads = [str(field) for field in data.get("reads", [])]
        full = f"{base_path.rstrip('/')}/{self.path.lstrip('/')}"
        full = re.sub(r"/{2,}", "/", full)
        pattern = re.escape(full.rstrip("/")).replace(r"\{id\}", r"[^/]+")
        self._regex = re.compile(f"^{pattern}/?$")

    def matches(self, method: str, path: str) -> bool:
        return method == self.method and bool(self._regex.match(path))


class Contract:
    """One service's endpoint table, loaded from tests/contracts/<service>.yml."""

    def __init__(self, path: Path) -> None:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError(f"{path}: contract must be a mapping")
        self.service = str(data["service"])
        self.base_path = str(data.get("base_path", ""))
        self.auth: dict[str, Any] = data.get("auth") or {"type": "none"}
        self.endpoints = [Endpoint(self.base_path, e) for e in data.get("endpoints", [])]

    def find(self, method: str, path: str) -> Endpoint | None:
        for endpoint in self.endpoints:
            if endpoint.matches(method, path):
                return endpoint
        return None


def load_contract(contracts_dir: Path, service: str) -> Contract:
    path = contracts_dir / f"{service}.yml"
    if not path.exists():
        raise FileNotFoundError(f"no contract file for service '{service}': {path}")
    return Contract(path)


def _parse_body(raw: bytes, content_type: str) -> Any:
    if not raw:
        return {}
    if "application/x-www-form-urlencoded" in content_type:
        parsed = parse_qs(raw.decode("utf-8", "replace"))
        return {k: v[0] if len(v) == 1 else v for k, v in parsed.items()}
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return raw.decode("utf-8", "replace")


def check_auth(auth: dict[str, Any], headers: Any, path: str, body: Any) -> bool:
    """Shape-check only: does the request carry the declared credential?

    Never simulates a token dance or session lifecycle — that stays the
    api-matrix layer's job (TARGET.md "Auth is shape-checked, never
    simulated").
    """
    kind = auth.get("type", "none")
    name = str(auth.get("name", ""))
    if kind == "none":
        return True
    if kind == "header":
        return bool(headers.get(name))
    if kind == "bearer":
        value = headers.get(name, "")
        return value.lower().startswith("bearer ") and len(value) > len("bearer ")
    if kind == "basic":
        value = headers.get("Authorization", "")
        return value.lower().startswith("basic ") and len(value) > len("basic ")
    if kind == "cookie":
        cookie_header = headers.get("Cookie", "")
        return f"{name}=" in cookie_header
    if kind == "query":
        query = path.split("?", 1)[1] if "?" in path else ""
        return f"{name}=" in parse_qs(query) or name in parse_qs(query)
    if kind == "form":
        fields = auth.get("fields") or ([name] if name else [])
        return all(field in (body or {}) for field in fields)
    return True


class Journal:
    """Append-only JSONL sink; every mock request lands here exactly once."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._lock = threading.Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)

    def append(self, record: dict[str, Any]) -> None:
        line = json.dumps(record, sort_keys=True)
        with self._lock, self._path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")


class ResponseCursor:
    """Per-(service, endpoint) counter for consuming an ordered `responses:`
    list in sequence — the whole failure-injection mechanism (see module
    docstring); never a general request/response state store."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counts: dict[tuple[str, str], int] = {}

    def next_index(self, service: str, endpoint_id: str) -> int:
        key = (service, endpoint_id)
        with self._lock:
            index = self._counts.get(key, 0)
            self._counts[key] = index + 1
            return index


def _set_dotted(container: dict[str, Any], parts: list[str]) -> None:
    head, *rest = parts
    if head.endswith("[]"):
        key = head[:-2]
        items = container.setdefault(key, [])
        if not items:
            items.append({})
        if rest:
            _set_dotted(items[0], rest)
        else:
            items[0] = 0
    elif rest:
        nested = container.setdefault(head, {})
        _set_dotted(nested, rest)
    else:
        container[head] = 0


def auto_response(endpoint: Endpoint) -> dict[str, Any]:
    """Minimal placeholder body built from a contract's `reads` fields when
    no fixture file exists. Documented behavior (tests/mock/README.md), not
    a service reimplementation — every leaf is a zero-ish placeholder."""
    body: dict[str, Any] = {}
    for field in endpoint.reads:
        _set_dotted(body, field.split("."))
    return body


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        contract: Contract,
        fixtures_dir: Path,
        journal: Journal,
        cursor: ResponseCursor,
    ) -> None:
        super().__init__(address, MockHandler)
        self.contract = contract
        self.fixtures_dir = fixtures_dir
        self.journal = journal
        self.cursor = cursor


class MockHandler(BaseHTTPRequestHandler):
    server: MockServer

    def _handle(self, method: str) -> None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw_body = self.rfile.read(length) if length else b""
        path = self.path.split("?", 1)[0]

        # Generic liveness fallback (not a per-service branch): any service's
        # bare root path answers 200 so curl -sf readiness probes succeed,
        # without being recorded as a contract call.
        if path == "/" and method == "GET":
            self._send(200, {})
            return

        contract = self.server.contract
        endpoint = contract.find(method, path)
        record: dict[str, Any] = {
            "service": contract.service,
            "method": method,
            "path": path,
            "endpoint": endpoint.id if endpoint else None,
        }
        body = _parse_body(raw_body, self.headers.get("Content-Type", ""))
        if endpoint is None:
            record["status"] = 404
            self.server.journal.append(record)
            self._send(404, {"error": "no contract endpoint for this route"})
            return

        if not check_auth(contract.auth, self.headers, self.path, body):
            record["status"] = 401
            self.server.journal.append(record)
            self._send(401, {"error": "unauthorized"})
            return

        status, response_body = self._response_for(contract, endpoint)
        record["status"] = status
        record["sent"] = body
        self.server.journal.append(record)
        self._send(status, response_body)

    def _response_for(self, contract: Contract, endpoint: Endpoint) -> tuple[int, Any]:
        fixture_path = self.server.fixtures_dir / contract.service / f"{endpoint.id}.json"
        if not fixture_path.exists():
            return 200, auto_response(endpoint)
        data = json.loads(fixture_path.read_text(encoding="utf-8"))
        if "responses" in data:
            responses = data["responses"]
            index = self.server.cursor.next_index(contract.service, endpoint.id)
            entry = responses[min(index, len(responses) - 1)]
        else:
            entry = data
        return int(entry.get("status", 200)), entry.get("body", {})

    def _send(self, status: int, body: Any) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def do_PUT(self) -> None:
        self._handle("PUT")

    def do_PATCH(self) -> None:
        self._handle("PATCH")

    def do_DELETE(self) -> None:
        self._handle("DELETE")

    def log_message(self, format: str, *args: Any) -> None:
        return  # the journal is the record; stay quiet on stderr


def _parse_service_port(value: str) -> tuple[str, int]:
    if ":" not in value:
        raise argparse.ArgumentTypeError(f"expected NAME:PORT, got '{value}'")
    name, _, port_str = value.rpartition(":")
    try:
        port = int(port_str)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid port in '{value}'") from exc
    return name, port


def main(argv: list[str] | None = None) -> int:
    """Start one mock HTTP server per --service NAME:PORT pair, block until
    interrupted. All servers share one contracts dir, one fixtures dir, one
    journal file, and one response cursor."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--service",
        dest="services",
        action="append",
        required=True,
        metavar="NAME:PORT",
        type=_parse_service_port,
        help="service name and port to bind, repeatable",
    )
    parser.add_argument("--bind", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    parser.add_argument("--contracts-dir", type=Path, default=DEFAULT_CONTRACTS_DIR)
    parser.add_argument("--fixtures-dir", type=Path, default=DEFAULT_FIXTURES_DIR)
    parser.add_argument(
        "--journal",
        type=Path,
        default=Path("/tmp/mediastack-mock-journal.jsonl"),
        help="JSONL journal path (truncated at startup)",
    )
    parser.add_argument(
        "--ready-file",
        type=Path,
        default=None,
        help="written once every server is listening, so a caller can poll for readiness",
    )
    args = parser.parse_args(argv)

    args.journal.parent.mkdir(parents=True, exist_ok=True)
    args.journal.write_text("", encoding="utf-8")
    journal = Journal(args.journal)
    cursor = ResponseCursor()

    servers: list[MockServer] = []
    threads: list[threading.Thread] = []
    for service, port in args.services:
        contract = load_contract(args.contracts_dir, service)
        server = MockServer((args.bind, port), contract, args.fixtures_dir, journal, cursor)
        servers.append(server)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        threads.append(thread)
        thread.start()
        print(f"mock: {service} listening on {args.bind}:{port}", file=sys.stderr)

    if args.ready_file is not None:
        args.ready_file.write_text("ready\n", encoding="utf-8")

    try:
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

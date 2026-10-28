#!/usr/bin/env python3
"""Reduce product curl traces to contracts.json, the contract-coverage evidence.

tests/lib/contract-trace-curl.sh records each product curl as a hex --trace
file named <epoch-ns>-<pid>.trace. This reducer reads those files, maps each
request to a service by its local port, matches it to an inventory entry, and
binds it to the candidate image or to another image by the service's latest
container start event at or before the curl started. It writes counts and the
names of the declared reads it saw. It never writes values, headers or bodies,
and it redacts long segments of unmatched paths.

Usage:
  observe.py --traces DIR --events FILE --ports JSON --candidates SPEC \\
             --scenario NAME --run-id ID [--output FILE]

--events is the receipts' docker events log (JSON lines). --ports is the JSON
object from service_http_ports_json. --candidates uses the
MS_TEST_IMAGE_OVERRIDES form: svc=ref pairs separated by commas or spaces.

contracts.json, schema 1. Only entries that were called appear; status keys
are three digits, and "000" is a request with no response:
  {"schema": 1, "inventory": "<sha256>", "scenario": "...", "run_id": "...",
   "entries": {"<service>": {"<entry id>": {"candidate": {"200": 2},
                                            "other": {"404": 1},
                                            "reads": ["<declared read seen>"]}}},
   "unmatched": {"<service> <METHOD> <path>": {"candidate": 1, "other": 0}}}
"reads" holds the declared reads seen in accepted responses on the candidate.
"""

from __future__ import annotations

import argparse
import bisect
import ipaddress
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import inventory

SCHEMA = 1
TRACE_NAME_RE = re.compile(r"(?P<ns>\d+)-\d+\.trace")
CONNECTED_RE = re.compile(r"Connected to \S+ \((?P<ip>[^)]*)\) port (?P<port>\d+)")
REQUEST_LINE_RE = re.compile(rb"(?P<method>[A-Z]+) (?P<target>\S+) HTTP/")
STATUS_LINE_RE = re.compile(rb"^HTTP/\S+ (?P<status>\d{3})", re.MULTILINE)
CHUNKED_RE = re.compile(rb"^transfer-encoding:[^\r\n]*\bchunked\b", re.IGNORECASE | re.MULTILINE)
# A segment this long is more likely a key or token than a route name.
REDACT_LENGTH = 24


@dataclass
class Request:
    """One HTTP exchange from a trace, as raw bytes."""

    started_ns: int
    ip: str
    port: int
    head: bytearray = field(default_factory=bytearray)
    response_head: bytearray = field(default_factory=bytearray)
    body: bytearray = field(default_factory=bytearray)

    def method_and_path(self) -> tuple[str, str] | None:
        line = REQUEST_LINE_RE.match(bytes(self.head))
        if not line:
            return None
        target = line.group("target").decode("latin-1").split("?", 1)[0]
        target = re.sub(r"^[a-z][a-z0-9+.-]*://[^/]+", "", target, flags=re.IGNORECASE)
        return line.group("method").decode(), target or "/"

    def final_head(self) -> bytes:
        """The headers of the last response that is not 1xx (100 Continue, ...)."""
        head = bytes(self.response_head)
        finals = [
            m for m in STATUS_LINE_RE.finditer(head) if not m.group("status").startswith(b"1")
        ]
        return head[finals[-1].start() :] if finals else b""

    def status(self) -> int:
        line = STATUS_LINE_RE.match(self.final_head())
        return int(line.group("status")) if line else 0

    def payload(self) -> bytes:
        body = bytes(self.body)
        return dechunk(body) if CHUNKED_RE.search(self.final_head()) else body


def dechunk(data: bytes) -> bytes:
    """Undo chunked transfer encoding; a malformed stream yields what parsed."""
    out = bytearray()
    position = 0
    while (end := data.find(b"\r\n", position)) >= 0:
        try:
            size = int(data[position:end].split(b";", 1)[0], 16)
        except ValueError:
            break
        if size == 0:
            break
        out += data[end + 2 : end + 2 + size]
        position = end + 2 + size + 2
    return bytes(out)


def _hex_bytes(line: str) -> bytes:
    # "0000: 47 45 54 ... GET": 16 hex pairs in a fixed 48-column field.
    _, _, rest = line.partition(": ")
    try:
        return bytes.fromhex(rest[:48])
    except ValueError:
        return b""


def _sink(
    line: str, requests: list[Request], connection: tuple[str, int], started_ns: int
) -> bytearray | None:
    """The buffer a trace block's hex lines belong to; None for blocks not kept."""
    if line.startswith("=> Send header"):
        requests.append(Request(started_ns, *connection))
        return requests[-1].head
    if not requests:
        return None
    if line.startswith("<= Recv header"):
        return requests[-1].response_head
    if line.startswith("<= Recv data"):
        return requests[-1].body
    return None


def parse_trace(text: str, started_ns: int) -> list[Request]:
    """Split one curl --trace into requests, in order."""
    requests: list[Request] = []
    connection = ("", 0)
    sink: bytearray | None = None
    for line in text.splitlines():
        if line.startswith("== Info: "):
            sink = None
            connected = CONNECTED_RE.search(line)
            if connected:
                connection = (connected.group("ip"), int(connected.group("port")))
        elif line.startswith(("=> ", "<= ")):
            sink = _sink(line, requests, connection, started_ns)
        elif sink is not None:
            sink.extend(_hex_bytes(line))
    return requests


def read_traces(directory: Path) -> list[Request]:
    requests = []
    for path in sorted(directory.glob("*.trace")):
        name = TRACE_NAME_RE.fullmatch(path.name)
        if not name:
            raise ValueError(f"unexpected trace file name: {path.name}")
        text = path.read_text(encoding="utf-8", errors="replace")
        requests += parse_trace(text, int(name.group("ns")))
    return requests


def parse_candidates(spec: str) -> dict[str, str]:
    candidates = {}
    for pair in spec.replace(",", " ").split():
        service, sep, ref = pair.partition("=")
        if not sep or not service or not ref:
            raise ValueError(f"candidate is not svc=ref: {pair!r}")
        candidates[service] = ref
    return candidates


def parse_ports(raw: str) -> dict[int, str]:
    ports: dict[int, str] = {}
    for service, port in json.loads(raw).items():
        if type(port) is not int or port in ports:
            raise ValueError(f"invalid or duplicate port for {service}: {port!r}")
        ports[port] = service
    return ports


def parse_starts(text: str) -> dict[str, list[tuple[int, str]]]:
    """Container start events by compose service: sorted (timeNano, image) pairs."""
    starts: dict[str, list[tuple[int, str]]] = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("Type") != "container" or event.get("Action") != "start":
            continue
        attributes = event["Actor"]["Attributes"]
        service = attributes.get("com.docker.compose.service")
        if service:
            starts.setdefault(service, []).append((int(event["timeNano"]), attributes["image"]))
    return {service: sorted(items) for service, items in starts.items()}


def is_local(ip: str) -> bool:
    """Loopback or a private (Docker network) address; anything else is external."""
    try:
        address = ipaddress.ip_address(ip.strip("[]"))
    except ValueError:
        return False
    return address.is_loopback or address.is_private


@dataclass
class Binder:
    """Decides whether a request reached the candidate image."""

    starts: dict[str, list[tuple[int, str]]]
    candidates: dict[str, str]

    def side(self, service: str, started_ns: int) -> str:
        events = self.starts.get(service, [])
        index = bisect.bisect_right([time for time, _ in events], started_ns)
        image = events[index - 1][1] if index else None
        candidate = self.candidates.get(service)
        return "candidate" if candidate is not None and image == candidate else "other"


def redact(path: str) -> str:
    return "/".join(
        "{redacted}" if len(part) >= REDACT_LENGTH else part for part in path.split("/")
    )


@dataclass
class Tally:
    """Counts per entry and per unmatched call, plus the reads seen on candidates."""

    entries: dict[tuple[str, str], dict[str, Counter[str]]] = field(default_factory=dict)
    reads: dict[tuple[str, str], set[str]] = field(default_factory=dict)
    unmatched: dict[str, Counter[str]] = field(default_factory=dict)

    def add(self, entry: inventory.Endpoint, side: str, request: Request) -> None:
        counts = self.entries.setdefault((entry.service, entry.id), {})
        status = request.status()
        counts.setdefault(side, Counter())[f"{status:03d}"] += 1
        if side == "candidate" and entry.accepts(status):
            self._see_reads(entry, request)

    def _see_reads(self, entry: inventory.Endpoint, request: Request) -> None:
        seen = self.reads.setdefault((entry.service, entry.id), set())
        wanted = [read for read in entry.reads if read not in seen]
        if not wanted:
            return
        try:
            body = json.loads(request.payload())
        except ValueError:
            return
        seen.update(read for read in wanted if inventory.read_present(body, read))

    def add_unmatched(self, call: str, side: str) -> None:
        self.unmatched.setdefault(call, Counter())[side] += 1


def tally(
    requests: list[Request],
    found: list[inventory.Endpoint],
    ports: dict[int, str],
    binder: Binder,
) -> Tally:
    result = Tally()
    for request in requests:
        service = ports.get(request.port)
        route = request.method_and_path()
        if service is None or route is None or not is_local(request.ip):
            continue
        side = binder.side(service, request.started_ns)
        entry = inventory.match(found, service, *route)
        if entry is None:
            result.add_unmatched(f"{service} {route[0]} {redact(route[1])}", side)
        else:
            result.add(entry, side, request)
    return result


def report(result: Tally, fingerprint: str, scenario: str, run_id: str) -> dict[str, Any]:
    """contracts.json schema 1."""
    entries: dict[str, dict[str, Any]] = {}
    for (service, entry_id), counts in sorted(result.entries.items()):
        entries.setdefault(service, {})[entry_id] = {
            "candidate": dict(sorted(counts.get("candidate", Counter()).items())),
            "other": dict(sorted(counts.get("other", Counter()).items())),
            "reads": sorted(result.reads.get((service, entry_id), set())),
        }
    unmatched = {
        call: {"candidate": counts["candidate"], "other": counts["other"]}
        for call, counts in sorted(result.unmatched.items())
    }
    return {
        "schema": SCHEMA,
        "inventory": fingerprint,
        "scenario": scenario,
        "run_id": run_id,
        "entries": entries,
        "unmatched": unmatched,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reduce curl traces to contracts.json.")
    for name in ("traces", "events", "ports", "candidates", "scenario", "run-id"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    binder = Binder(
        parse_starts(Path(args.events).read_text(encoding="utf-8")),
        parse_candidates(args.candidates),
    )
    result = tally(
        read_traces(Path(args.traces)),
        inventory.load_endpoints(),
        parse_ports(args.ports),
        binder,
    )
    text = json.dumps(report(result, inventory.fingerprint(), args.scenario, args.run_id))
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

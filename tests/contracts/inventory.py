"""Load, validate and match the API contract inventory in tests/contracts/*.yml.

check.py (static coverage), observe.py (trace reducer) and the preflight
verdict (tests/preflight/contracts.py) share this one reading of the format, so
a route or a read path cannot mean one thing to the scanner and another to the
acceptance gate. The format itself is documented in tests/contracts/README.md.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

CONTRACT_DIR = Path(__file__).resolve().parent
METHODS = frozenset({"GET", "POST", "PUT", "PATCH", "DELETE"})
# The closed set of reasons an entry may stay unexercised by the image jobs.
# accepted-image-only: the required scenarios do make the call, but only while
# the service runs its accepted image, never the candidate.
EXEMPT_REASONS = frozenset(
    {"gpu", "remote-profile", "launcher-menu", "nas", "held-profile", "accepted-image-only"}
)
ENDPOINT_KEYS = frozenset(
    {"id", "method", "path", "base_path", "expect", "unexercised", "sends", "reads", "callers"}
)
_ID_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


@dataclass(frozen=True)
class Endpoint:
    """One inventoried call, with its route already joined to its base path."""

    service: str
    id: str
    method: str
    path: str
    route: str
    expect: tuple[int, ...]
    reads: tuple[str, ...]
    unexercised: str | None

    @property
    def key(self) -> str:
        return f"{self.service} {self.id}"

    def accepts(self, status: int) -> bool:
        """Accepted statuses are ``expect`` when given, otherwise any 2xx."""
        return status in self.expect if self.expect else 200 <= status < 300


def join_path(base_path: str, path: str) -> str:
    return "/" + "/".join(part for part in f"{base_path}/{path}".split("/") if part)


# ``{id}`` stands for a generated identifier: digits, a UUID, or 16 or more hex
# digits. A word such as ``about`` or ``schema`` is a sibling route, not an id.
# ``{key}`` stands for any one segment, for an API keyed by name or by an
# opaque key (Jackett indexer names, PocketBase record ids).
PLACEHOLDERS = frozenset({"{id}", "{key}"})
_ID_SEGMENT_RE = re.compile(
    r"\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,}",
    re.IGNORECASE,
)


def _segment_matches(pattern: str, segment: str) -> bool:
    if pattern == "{key}":
        return bool(segment)
    if pattern == "{id}":
        # check.py writes each shell variable in a scanned path as ``{id}``.
        return segment == "{id}" or _ID_SEGMENT_RE.fullmatch(segment) is not None
    return pattern.lower() == segment.lower()


def route_matches(pattern: str, path: str) -> bool:
    """Each placeholder matches exactly one segment; a trailing slash is not significant."""
    wanted, got = pattern.rstrip("/").split("/"), path.rstrip("/").split("/")
    return len(wanted) == len(got) and all(map(_segment_matches, wanted, got))


def placeholder_count(route: str) -> int:
    return sum(segment in PLACEHOLDERS for segment in route.split("/"))


def load(directory: Path = CONTRACT_DIR) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Read every contract file. Returns the raw contracts by service, and errors."""
    contracts: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    for path in sorted(directory.glob("*.yml")):
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        service = data.get("service") if isinstance(data, dict) else None
        if not isinstance(service, str) or not service:
            errors.append(f"{path.name}: service must be a non-empty string")
            continue
        if service in contracts:
            errors.append(f"duplicate contract service: {service}")
        contracts[service] = data
    return contracts, errors


def _string_list_error(value: Any) -> bool:
    return not isinstance(value, list) or not all(isinstance(item, str) for item in value)


def _expect_error(value: Any) -> str | None:
    if not isinstance(value, list) or not value:
        return "expect must be a non-empty list of HTTP statuses"
    if not all(type(item) is int and 100 <= item <= 599 for item in value):
        return f"expect values must be integers from 100 to 599, got {value!r}"
    return None


def _endpoint_errors(item: dict[str, Any]) -> list[str]:
    errors = [f"unknown key {key!r}" for key in sorted(set(item) - ENDPOINT_KEYS)]
    if not isinstance(item.get("id"), str) or not _ID_RE.fullmatch(item["id"]):
        errors.append("id must be kebab-case")
    if item.get("method") not in METHODS:
        errors.append(f"method must be one of {sorted(METHODS)}")
    for key in ("path", "base_path"):
        if key in item and not (isinstance(item[key], str) and item[key].startswith("/")):
            errors.append(f"{key} must be a string starting with /")
        elif key in item and any(
            ("{" in part or "}" in part) and part not in PLACEHOLDERS
            for part in item[key].split("/")
        ):
            errors.append(f"{key} may hold only whole {{id}} or {{key}} segments")
    if "expect" in item:
        errors.append(_expect_error(item["expect"]) or "")
    if "unexercised" in item and item["unexercised"] not in EXEMPT_REASONS:
        errors.append(
            f"unexercised must be one of {sorted(EXEMPT_REASONS)}, got {item['unexercised']!r}"
        )
    for key in ("sends", "reads", "callers"):
        if _string_list_error(item.get(key)):
            errors.append(f"{key} must be a list of strings")
    return [error for error in errors if error]


def validate(service: str, contract: dict[str, Any]) -> list[str]:
    """Schema errors for one contract file, each naming the entry it concerns."""
    endpoints = contract.get("endpoints")
    if not isinstance(endpoints, list):
        return [f"{service}: endpoints must be a list"]
    if not isinstance(contract.get("base_path", "/"), str):
        return [f"{service}: base_path must be a string"]
    errors: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(endpoints):
        if not isinstance(item, dict):
            errors.append(f"{service} endpoint #{index}: must be a mapping")
            continue
        label = f"{service} {item.get('id', f'endpoint #{index}')}"
        errors += [f"{label}: {error}" for error in _endpoint_errors(item)]
        if item.get("id") in seen:
            errors.append(f"{label}: duplicate id")
        seen.add(str(item.get("id")))
    return errors


def endpoints(contracts: dict[str, dict[str, Any]]) -> list[Endpoint]:
    """Typed entries for already-validated contracts."""
    found = []
    for service, contract in sorted(contracts.items()):
        base = str(contract.get("base_path", "/"))
        for item in contract["endpoints"]:
            found.append(
                Endpoint(
                    service=service,
                    id=item["id"],
                    method=item["method"],
                    path=item["path"],
                    route=join_path(item.get("base_path", base), item["path"]),
                    expect=tuple(item.get("expect", ())),
                    reads=tuple(item["reads"]),
                    unexercised=item.get("unexercised"),
                )
            )
    return found


def load_endpoints(directory: Path = CONTRACT_DIR) -> list[Endpoint]:
    """Load and validate the whole inventory, or raise ValueError naming every error."""
    contracts, errors = load(directory)
    for service, contract in contracts.items():
        errors += validate(service, contract)
    if errors:
        raise ValueError("invalid contract inventory: " + "; ".join(errors))
    return endpoints(contracts)


def match(found: list[Endpoint], service: str, method: str, path: str) -> Endpoint | None:
    """The entry a request hits. A literal segment wins over ``{id}``, as servers route."""
    hits = [
        item
        for item in found
        if item.service == service and item.method == method and route_matches(item.route, path)
    ]
    return min(hits, key=lambda item: placeholder_count(item.route), default=None)


def fingerprint(directory: Path = CONTRACT_DIR) -> str:
    """sha256 over the sorted contract files' names and bytes."""
    digest = hashlib.sha256()
    for path in sorted(directory.glob("*.yml")):
        digest.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def _present(value: Any) -> bool:
    # The product's JSON helpers print their default for null and print nothing
    # useful for an empty string or container, so those values prove no read.
    return value is not None and value != "" and value != [] and value != {}


def _found(value: Any, parts: list[str]) -> bool:
    if not parts:
        return _present(value)
    head, rest = parts[0], parts[1:]
    is_array = head.endswith("[]")
    key = head[:-2] if is_array else head
    if not isinstance(value, dict) or key not in value:
        return False
    child = value[key]
    if not is_array:
        return _found(child, rest)
    # A path through an array counts only through a non-empty array.
    return isinstance(child, list) and any(_found(element, rest) for element in child)


def _members(body: Any) -> list[Any]:
    """The objects a top-level path applies to; empty when there is nothing to read."""
    if isinstance(body, list):
        return body
    if isinstance(body, dict) and body and all(isinstance(v, dict) for v in body.values()):
        # A collection keyed by name (qBittorrent's torrents/categories) is read
        # member-wise, like a list; the body itself is also tried as one object.
        return [body, *body.values()]
    return [body]


def read_present(body: Any, read: str) -> bool:
    """Whether one declared read path is found in a parsed JSON response body.

    A top-level list must be non-empty and the path must be found in at least
    one member; each ``[]`` step must likewise pass through a non-empty array.
    An empty list therefore satisfies no read, and neither does a value of
    null, an empty string, or an empty list or object.
    """
    parts = read.split(".")
    return any(_found(member, parts) for member in _members(body))

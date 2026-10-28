#!/usr/bin/env python3
"""Check that literal HTTP API calls and contract entries cover each other."""

from __future__ import annotations

import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

import inventory
from inventory import Endpoint

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = inventory.CONTRACT_DIR
CALL_RE = re.compile(
    r"\b(?P<function>curl|curl_basic_auth|curl_data_stdin|curl_data_urlencode_stdin|"
    r"curl_header_stdin|curl_header_data_stdin|"
    r"api_get|api_fetch|api_fetch_auth|api_post|api_put|api_delete|"
    r"wait_for_jellyfin_auth|http_json_post|http_check|"
    r"http_check_data|http_check_auth)\b(?P<args>[^\n]*)"
)
# Readiness probes poll a URL with GET until it answers. They are found only in
# statement position, so prose that names them is not a call.
PROBE_RE = re.compile(
    r"(?:^|[;&|!{(]|\b(?:then|do|else|if|while|until))[ \t]*"
    r"(?P<function>wait_for_service|wait_for_healthy|post_restart_wait)[ \t]+(?P<args>[^\n]*)",
    re.MULTILINE,
)
PROBE_DEFINITION_RE = re.compile(
    r"^\s*(?:wait_for_service|wait_for_healthy|post_restart_wait)\s*\(\)", re.MULTILINE
)
# The position of the polled URL among each probe's arguments.
PROBE_URL_ARG = {"wait_for_service": 1, "wait_for_healthy": 2, "post_restart_wait": 0}
SERVICE_URL_RE = re.compile(r"\$\(service_local_url\s+(?P<name>[^)\s]+)\s*\)(?P<suffix>[^\s\"'}]*)")
SERVICE_NAME_RE = re.compile(r"[a-z][a-z0-9-]*")
SHELL_OPERATOR_RE = re.compile(r"^(?:\|\||&&|;|\||\d*[<>].*)$")
QUOTED_RE = re.compile(r"(?P<quote>['\"])(?P<value>.*?)(?P=quote)")
ASSIGN_RE = re.compile(
    r"(?:\blocal\s+(?:-\w+\s+)*)?(?P<name>[A-Za-z_]\w*)\s*=\s*(?P<value>['\"]?[^\n]+)"
)
ARRAY_RE = re.compile(r"(?P<name>[A-Za-z_]\w*curl_args)\s*=\((?P<args>.*?)\)", re.DOTALL)
VARIABLE_RE = re.compile(r"\$\{(?P<braced>[A-Za-z_]\w*)\}|\$(?P<plain>[A-Za-z_]\w*)")
PATH_RE = re.compile(r"(?P<path>/(?:[A-Za-z0-9_.~${}-]+/?)*)")
ARR_SERVICES = ("sonarr", "radarr")

# The shared arr API helpers are split behind scripts/lib/arr/main.sh; retain
# the same Sonarr/Radarr service attribution for each topical caller.
_ARR_CONTRACT_CALLERS = {
    "scripts/lib/arr/quality.sh",
    "scripts/lib/arr/formats.sh",
    "scripts/lib/arr/indexers.sh",
    "scripts/lib/arr/storage.sh",
    "scripts/lib/arr/connections.sh",
}

# Callers whose unmatched routes are coverage errors rather than noise: the
# service configurators plus the shared helpers that speak to services.
_CONTRACT_REQUIRED_CALLERS = {
    *_ARR_CONTRACT_CALLERS,
    "scripts/lib/health.sh",
    "scripts/lib/http.sh",
    "scripts/lib/npm-remote.sh",
}


@dataclass(frozen=True)
class Route:
    """A request route found in a script. ``services`` is empty when only the path is known."""

    path: str
    dynamic: bool
    services: tuple[str, ...] = ()


@dataclass(frozen=True)
class Call:
    """One statically found request, attributed to the entry it reaches."""

    endpoint: Endpoint
    caller: str
    dynamic: bool


@dataclass(frozen=True)
class ScriptFile:
    """What one script's assignments say about the URLs its calls use."""

    relative: str
    prefixes: dict[str, str]
    service_urls: dict[str, tuple[str, str]]


@dataclass
class Scan:
    """The endpoints scanned against, and everything the scan found."""

    found: list[Endpoint]
    calls: list[Call] = field(default_factory=list)
    findings: set[str] = field(default_factory=set)
    errors: list[str] = field(default_factory=list)


def _variable_prefixes(text: str) -> dict[str, str]:
    prefixes: dict[str, str] = {}
    for match in ASSIGN_RE.finditer(text):
        value = match.group("value")
        route = PATH_RE.search(value)
        if route and re.search(r"(?:url|api|base)", match.group("name"), re.IGNORECASE):
            prefixes[match.group("name")] = route.group("path").rstrip("}")
    return prefixes


def _service_variables(text: str) -> dict[str, tuple[str, str]]:
    """Variables assigned from ``$(service_local_url NAME)``: name -> (service, path suffix).

    A variable assigned more than one service URL in a file is ambiguous and dropped.
    """
    seen: dict[str, set[tuple[str, str]]] = {}
    for match in ASSIGN_RE.finditer(text):
        url = SERVICE_URL_RE.search(match.group("value"))
        if url:
            seen.setdefault(match.group("name"), set()).add(
                (url.group("name"), url.group("suffix"))
            )
    return {
        name: next(iter(values))
        for name, values in seen.items()
        if len(values) == 1 and SERVICE_NAME_RE.fullmatch(next(iter(values))[0])
    }


def _normalize(text: str, services: tuple[str, ...] = ()) -> Route | None:
    route = PATH_RE.search(text.split("?", 1)[0].split("#", 1)[0])
    if not route:
        return None
    dynamic = False

    def replace_variable(match: re.Match[str]) -> str:
        nonlocal dynamic
        name = match.group("braced") or match.group("plain")
        dynamic = dynamic or not (name == "id" or name.endswith("_id"))
        return "{id}"

    path = re.sub(r"/{2,}", "/", VARIABLE_RE.sub(replace_variable, route.group("path")))
    return Route(path or "/", dynamic, services)


def _path_from_token(token: str, prefixes: dict[str, str]) -> Route | None:
    token = token.split("?", 1)[0].split("#", 1)[0]
    token = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]+", "", token)
    variable = VARIABLE_RE.search(token)
    if variable:
        name = variable.group("braced") or variable.group("plain")
        suffix = token[variable.end() :]
        prefix = prefixes.get(name, "")
        if not prefix and not suffix.startswith("/"):
            return None
        # A prefix of "/" is a bare origin such as http://localhost:8096.
        token = f"{prefix.rstrip('/')}{suffix}"
    return _normalize(token)


def _named_services(name: str, caller: str) -> tuple[str, ...]:
    name = name.strip("\"'")
    if SERVICE_NAME_RE.fullmatch(name):
        return (name,)
    # The shared arr helpers pass the app name in a variable; it is one of the two.
    return ARR_SERVICES if caller in _ARR_CONTRACT_CALLERS else ()


def _service_route(token: str, script: ScriptFile, probe: bool) -> Route | None:
    """Resolve ``$(service_local_url NAME)SUFFIX``, directly or through a variable.

    An empty suffix is the bare service URL. A probe polls it; any other helper
    only receives it as a base URL, so it is not a request route there.
    """
    url = SERVICE_URL_RE.search(token)
    if url:
        services, rest = _named_services(url.group("name"), script.relative), url.group("suffix")
    else:
        variable = VARIABLE_RE.match(token)
        name = variable and (variable.group("braced") or variable.group("plain"))
        if not variable or name not in script.service_urls:
            return None
        service, prefix = script.service_urls[str(name)]
        services, rest = (service,), prefix + token[variable.end() :]
    if not services or not (rest or probe):
        return None
    return _normalize(rest or "/", services)


def _method(function: str, args: str) -> str:
    explicit = re.search(r"(?:^|\s)-X\s+(GET|POST|PUT|PATCH|DELETE)\b", args)
    if explicit and explicit.group(1) in inventory.METHODS:
        return explicit.group(1)
    if function in {"api_post", "http_json_post", "curl_data_stdin"}:
        return "POST"
    if function == "api_put":
        return "PUT"
    if function == "api_delete":
        return "DELETE"
    if function == "wait_for_jellyfin_auth":
        return "POST"
    # The stdin wrappers carry the body curl would otherwise be handed with -d,
    # so a request through one of them is a POST unless -X says otherwise.
    if function in {"curl_data_urlencode_stdin", "http_check_data", "curl_header_data_stdin"}:
        return "POST"
    if function == "curl" and re.search(r"(?:^|\s)(?:-d|--data|--data-\w+)(?:\s|=)", args):
        return "POST"
    return "GET"


def _most_specific(hits: list[Endpoint]) -> list[Endpoint]:
    """One entry per service: a literal segment wins over ``{id}``, then file order."""
    best: dict[str, Endpoint] = {}
    for item in hits:
        held = best.get(item.service)
        if held is None or item.route.count("{id}") < held.route.count("{id}"):
            best[item.service] = item
    return list(best.values())


def _local_service(caller: str) -> str | None:
    service_match = re.match(r"scripts/services/([^/]+)/", caller)
    return service_match.group(1) if service_match else None


def _relative_hits(
    found: list[Endpoint], services: tuple[str, ...], method: str, path: str
) -> list[Endpoint]:
    return _most_specific(
        [
            item
            for item in found
            if item.service in services
            and item.method == method
            and inventory.route_matches(item.path, path)
        ]
    )


def _hits_by_path(found: list[Endpoint], caller: str, method: str, path: str) -> list[Endpoint]:
    # A bare root names no service: only a resolved service reaches a root entry.
    if path == "/":
        return []
    hits = _most_specific(
        [
            item
            for item in found
            if item.method == method and inventory.route_matches(item.route, path)
        ]
    )
    local = _local_service(caller)
    if hits:
        return [item for item in hits if item.service == local] or hits
    # A path with its base prefix still in a variable: match the entry path alone.
    if local:
        local_hits = _relative_hits(found, (local,), method, path)
        if local_hits:
            return local_hits
    if caller in _ARR_CONTRACT_CALLERS:
        return _relative_hits(found, ARR_SERVICES, method, path)
    return []


def _hits_by_service(scan: Scan, caller: str, method: str, route: Route) -> list[Endpoint]:
    hits = []
    for service in route.services:
        hit = inventory.match(scan.found, service, method, route.path)
        if hit is None:
            scan.errors.append(f"missing contract: {caller} {service} {method} {route.path}")
        else:
            hits.append(hit)
    return hits


def _record_route(
    scan: Scan, caller: str, method: str, route: Route, require_contract: bool
) -> None:
    if route.services:
        hits = _hits_by_service(scan, caller, method, route)
    else:
        hits = _hits_by_path(scan.found, caller, method, route.path)
        if not hits and require_contract:
            scan.errors.append(f"missing contract: {caller} {method} {route.path}")
    if hits and route.dynamic:
        scan.findings.add(f"{caller}: {method} {route.path} uses path substitution")
    scan.calls += [Call(item, caller, route.dynamic) for item in hits]


def _requires_contract(caller: str) -> bool:
    return caller.startswith("scripts/services/") or caller in _CONTRACT_REQUIRED_CALLERS


def _direct_call_route(args: str, script: ScriptFile) -> Route | None:
    tokens = [item.group("value") for item in QUOTED_RE.finditer(args)]
    tokens += [item for item in args.split() if "/" in item]
    for token in tokens:
        resolved = _service_route(token, script, probe=False)
        if resolved:
            return resolved
        candidate = _path_from_token(token, script.prefixes)
        likely_url = (
            VARIABLE_RE.search(token)
            or "service_local_url" in token
            or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", token)
        )
        if candidate and likely_url:
            return candidate
    return None


def _probe_url(function: str, args: str) -> str | None:
    try:
        words = shlex.split(args, comments=True)
    except ValueError:
        return None
    for index, word in enumerate(words):
        if SHELL_OPERATOR_RE.match(word):
            words = words[:index]
            break
    position = PROBE_URL_ARG[function]
    return words[position] if len(words) > position else None


def _scan_probes(scan: Scan, script: ScriptFile, text: str) -> None:
    # The probe helpers' own module forwards its caller's URL; that is not a call site.
    if PROBE_DEFINITION_RE.search(text):
        return
    for match in PROBE_RE.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if text[line_start : match.start()].lstrip().startswith("#"):
            continue
        token = _probe_url(match.group("function"), match.group("args"))
        route = token and (
            _service_route(token, script, probe=True) or _path_from_token(token, script.prefixes)
        )
        if not route:
            scan.errors.append(
                f"unrecognised probe: {script.relative}: "
                f"{match.group('function')} {match.group('args').strip()}"
            )
            continue
        _record_route(scan, script.relative, "GET", route, require_contract=True)


def _scan_curl_args(scan: Scan, script: ScriptFile, text: str) -> None:
    argument_lists = [
        item.group("value")
        for item in ASSIGN_RE.finditer(text)
        if item.group("name").endswith("curl_args")
    ]
    argument_lists += [item.group("args") for item in ARRAY_RE.finditer(text)]
    for args in argument_lists:
        method = _method("curl", args)
        for token_match in QUOTED_RE.finditer(args):
            route = _path_from_token(token_match.group("value"), script.prefixes)
            if route is not None:
                _record_route(scan, script.relative, method, route, require_contract=False)


def _scan_file(scan: Scan, path: Path) -> None:
    relative = path.relative_to(ROOT).as_posix()
    text = path.read_text(encoding="utf-8").replace("\\\n", " ")
    script = ScriptFile(relative, _variable_prefixes(text), _service_variables(text))
    for match in CALL_RE.finditer(text):
        args = match.group("args")
        route = _direct_call_route(args, script)
        if route is not None:
            method = _method(match.group("function"), args)
            _record_route(scan, relative, method, route, _requires_contract(relative))
    _scan_probes(scan, script, text)
    _scan_curl_args(scan, script, text)


def _steer(errors: list[str]) -> None:
    """Route each failure kind to its remediation, not just its symptom."""
    contract_dir = CONTRACT_DIR.relative_to(ROOT)
    if any(error.startswith("missing contract:") for error in errors):
        print(
            "contract: a missing contract means an API call has no entry covering it "
            "(or the call is malformed):\ncontract: add the endpoint and its caller to "
            f"the service's file in {contract_dir}/ — see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("dead contract entry:") for error in errors):
        print(
            "contract: a dead contract entry means the call it covered is gone: delete "
            f"the entry from the service's file in {contract_dir}/ — "
            "see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("unrecognised probe:") for error in errors):
        print(
            "contract: an unrecognised probe polls a URL this check cannot attribute: pass "
            '"$(service_local_url NAME)" or a variable assigned from it — '
            "see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("schema:") for error in errors):
        print(
            f"contract: a schema error means a file in {contract_dir}/ breaks the format "
            "in tests/contracts/README.md; fix the named entry.",
            file=sys.stderr,
        )


def _load() -> tuple[list[Endpoint], dict[tuple[str, str], set[str]], list[str]]:
    contracts, errors = inventory.load(CONTRACT_DIR)
    if not contracts:
        errors.append("no contract files found")
    for service, contract in contracts.items():
        errors += [f"schema: {error}" for error in inventory.validate(service, contract)]
    if errors:
        return [], {}, errors
    expected = {
        (service, item["id"]): set(item["callers"])
        for service, contract in contracts.items()
        for item in contract["endpoints"]
    }
    return inventory.endpoints(contracts), expected, []


def _sync_errors(expected: dict[tuple[str, str], set[str]], scan: Scan) -> list[str]:
    actual: dict[tuple[str, str], set[str]] = {}
    for call in scan.calls:
        actual.setdefault((call.endpoint.service, call.endpoint.id), set()).add(call.caller)
    routes = {(item.service, item.id): f"{item.method} {item.route}" for item in scan.found}
    errors = []
    for key, callers in sorted(expected.items()):
        label = f"{key[0]} {key[1]} ({routes[key]})"
        if key not in actual:
            errors.append(f"dead contract entry: {label}")
        elif callers != actual[key]:
            errors.append(
                f"caller mismatch: {label} contract={sorted(callers)} actual={sorted(actual[key])}"
            )
    return errors


def main() -> int:
    """Run the bidirectional contract coverage check."""
    found, expected, errors = _load()
    scan = Scan(found)
    if not errors:
        for path in sorted((ROOT / "scripts").rglob("*.sh")):
            _scan_file(scan, path)
        errors = scan.errors + _sync_errors(expected, scan)
    for finding in sorted(scan.findings):
        print(f"contract: finding: {finding}", file=sys.stderr)
    for error in errors:
        print(f"contract: error: {error}", file=sys.stderr)
    if errors:
        _steer(errors)
        return 1
    reached = {(call.endpoint.service, call.endpoint.id) for call in scan.calls}
    print(f"contracts: {len(expected)} endpoints, {len(reached)} reached by literal calls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

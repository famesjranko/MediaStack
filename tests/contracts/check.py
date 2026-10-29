#!/usr/bin/env python3
"""Check that literal API calls, docker exec calls and contract entries cover each other."""

from __future__ import annotations

import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import exec_scan
import inventory
from inventory import Endpoint, ExecEntry

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from preflight.model import HELD  # noqa: E402

CONTRACT_DIR = inventory.CONTRACT_DIR
CALL_RE = re.compile(
    r"\b(?P<function>curl|curl_basic_auth|curl_data_stdin|curl_data_urlencode_stdin|"
    r"curl_header_stdin|curl_header_data_stdin|"
    r"api_get|api_fetch|api_fetch_auth|api_post|api_put|api_delete|"
    r"wait_for_jellyfin_auth|http_json_post|http_json_request|http_check|"
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
SERVICE_URL_RE = re.compile(
    r"\$\(service_local_url\s+(?P<name>[^)\s]+)\s*\)(?P<suffix>(?:\$\{[^}\s]*\}|[^\s\"'}])*)"
)
# A variable holds a service URL only when its value starts with one, maybe as
# the default of a positional parameter: local api="${2:-$(service_local_url npm)/api}".
SERVICE_VALUE_RE = re.compile(r"[\"']?(?:\$\{\w+:-)?(?=\$\(service_local_url\b)")
FUNCTION_RE = re.compile(
    r"^[ \t]*(?:function[ \t]+)?[A-Za-z_][\w:-]*[ \t]*\(\)[ \t]*\{(?P<rest>[^\n]*)$", re.MULTILINE
)
FUNCTION_END_RE = re.compile(r"^\}[ \t]*$", re.MULTILINE)
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


# A variable's service URL, (service, path suffix), or None where the variable
# is assigned something else or more than one service URL in that scope.
ServiceUrl = Optional[tuple[str, str]]


@dataclass(frozen=True)
class ScriptFile:
    """What one script's assignments say about the URLs its calls use.

    Service URL variables are resolved per function, so a local reused in
    another function does not carry the first function's service.
    """

    relative: str
    prefixes: dict[str, tuple[str, ...]]
    spans: list[tuple[int, int]]
    service_urls: dict[tuple[int | None, str], ServiceUrl]

    def service_url(self, name: str, position: int) -> ServiceUrl:
        """The variable's service URL in the function at ``position``, else at file level."""
        scope = _scope(self.spans, position)
        if (scope, name) in self.service_urls:
            return self.service_urls[(scope, name)]
        return self.service_urls.get((None, name))


@dataclass
class Scan:
    """The endpoints scanned against, and everything the scan found."""

    found: list[Endpoint]
    calls: list[Call] = field(default_factory=list)
    findings: set[str] = field(default_factory=set)
    errors: list[str] = field(default_factory=list)


def _variable_prefixes(text: str) -> dict[str, tuple[str, ...]]:
    """URL-like variables and every path prefix the file assigns each one."""
    prefixes: dict[str, set[str]] = {}
    for match in ASSIGN_RE.finditer(text):
        value = match.group("value")
        route = PATH_RE.search(value)
        if route and re.search(r"(?:url|api|base)", match.group("name"), re.IGNORECASE):
            prefixes.setdefault(match.group("name"), set()).add(route.group("path").rstrip("}"))
    return {name: tuple(sorted(paths)) for name, paths in prefixes.items()}


def _function_spans(text: str) -> list[tuple[int, int]]:
    """Character spans of top-level function definitions, in order."""
    spans: list[tuple[int, int]] = []
    for match in FUNCTION_RE.finditer(text):
        if spans and match.start() < spans[-1][1]:
            continue
        # A one-line definition ends on its own line; any other at the next column-0 brace.
        one_line = match.group("rest").rstrip().endswith("}")
        end = None if one_line else FUNCTION_END_RE.search(text, match.end())
        spans.append((match.start(), end.end() if end else match.end()))
    return spans


def _scope(spans: list[tuple[int, int]], position: int) -> int | None:
    """The index of the function span holding ``position``; None at file level."""
    return next(
        (index for index, (start, end) in enumerate(spans) if start <= position < end), None
    )


def _assigned_service_url(value: str) -> ServiceUrl:
    start = SERVICE_VALUE_RE.match(value)
    url = start and SERVICE_URL_RE.match(value, start.end())
    return (url.group("name"), url.group("suffix")) if url else None


def _script_file(relative: str, text: str) -> ScriptFile:
    spans = _function_spans(text)
    seen: dict[tuple[int | None, str], set[ServiceUrl]] = {}
    for match in ASSIGN_RE.finditer(text):
        key = (_scope(spans, match.start()), match.group("name"))
        seen.setdefault(key, set()).add(_assigned_service_url(match.group("value")))
    service_urls: dict[tuple[int | None, str], ServiceUrl] = {}
    for key, values in seen.items():
        only = next(iter(values)) if len(values) == 1 else None
        service_urls[key] = only if only and SERVICE_NAME_RE.fullmatch(only[0]) else None
    return ScriptFile(relative, _variable_prefixes(text), spans, service_urls)


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


def _paths_from_token(token: str, prefixes: dict[str, tuple[str, ...]]) -> list[Route]:
    """The routes a URL token can reach: one per path its leading variable is assigned."""
    token = token.split("?", 1)[0].split("#", 1)[0]
    token = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]+", "", token)
    variable = VARIABLE_RE.search(token)
    tokens = [token]
    if variable:
        name = variable.group("braced") or variable.group("plain")
        suffix = token[variable.end() :]
        known = prefixes.get(name, ())
        if not known and not suffix.startswith("/"):
            return []
        # A prefix of "/" is a bare origin such as http://localhost:8096.
        tokens = [f"{prefix.rstrip('/')}{suffix}" for prefix in known or ("",)]
    return [route for route in map(_normalize, tokens) if route]


def _named_services(name: str, caller: str) -> tuple[str, ...]:
    name = name.strip("\"'")
    if SERVICE_NAME_RE.fullmatch(name):
        return (name,)
    # The shared arr helpers pass the app name in a variable; it is one of the two.
    return ARR_SERVICES if caller in _ARR_CONTRACT_CALLERS else ()


def _service_route(token: str, script: ScriptFile, position: int, probe: bool) -> Route | None:
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
        assigned = script.service_url(str(name), position) if variable else None
        if not variable or assigned is None:
            return None
        services, rest = (assigned[0],), assigned[1] + token[variable.end() :]
    if not services or not (rest or probe):
        return None
    return _normalize(rest or "/", services)


def _method(function: str, args: str) -> str:
    if function == "http_json_request":
        tokens = shlex.split(args)
        return tokens[1] if len(tokens) > 1 and tokens[1] in inventory.METHODS else "GET"
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
    """One entry per service: a literal segment wins over a placeholder, then file order."""
    best: dict[str, Endpoint] = {}
    for item in hits:
        held = best.get(item.service)
        rank = inventory.placeholder_count(item.route)
        if held is None or rank < inventory.placeholder_count(held.route):
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


def _direct_call_routes(args: str, script: ScriptFile, position: int) -> list[Route]:
    tokens = [item.group("value") for item in QUOTED_RE.finditer(args)]
    tokens += [item for item in args.split() if "/" in item]
    for token in tokens:
        resolved = _service_route(token, script, position, probe=False)
        if resolved:
            return [resolved]
        candidates = _paths_from_token(token, script.prefixes)
        likely_url = (
            VARIABLE_RE.search(token)
            or "service_local_url" in token
            or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", token)
        )
        if candidates and likely_url:
            return candidates
    return []


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
        token = token or ""
        service_route = _service_route(token, script, match.start(), probe=True)
        routes = [service_route] if service_route else _paths_from_token(token, script.prefixes)
        if not routes:
            scan.errors.append(
                f"unrecognised probe: {script.relative}: "
                f"{match.group('function')} {match.group('args').strip()}"
            )
            continue
        for route in routes:
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
            for route in _paths_from_token(token_match.group("value"), script.prefixes):
                _record_route(scan, script.relative, method, route, require_contract=False)


def _scan_file(scan: Scan, path: Path) -> exec_scan.Script:
    relative = path.relative_to(ROOT).as_posix()
    text = path.read_text(encoding="utf-8").replace("\\\n", " ")
    script = _script_file(relative, text)
    for match in CALL_RE.finditer(text):
        args = match.group("args")
        method = _method(match.group("function"), args)
        for route in _direct_call_routes(args, script, match.start()):
            _record_route(scan, relative, method, route, _requires_contract(relative))
    _scan_probes(scan, script, text)
    _scan_curl_args(scan, script, text)
    return exec_scan.Script(relative, text, lambda position: _scope(script.spans, position))


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
    if any(error.startswith("unparseable exec:") for error in errors):
        print(
            "contract: an unparseable exec is a docker exec call this check cannot read: "
            "write `docker exec [flags] <container> <command...>` with a literal container, "
            "or a variable assigned one literal service name — see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("possible exec call not parsed:") for error in errors):
        print(
            "contract: a possible exec call not parsed is a line that names docker and exec "
            "in a form this check does not read: write `docker exec [flags] <container> "
            "<command...>`; a line that only prints the command goes in MESSAGES in "
            "tests/contracts/exec_scan.py after you check that it runs nothing — "
            "see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("schema:") for error in errors):
        print(
            f"contract: a schema error means a file in {contract_dir}/ breaks the format "
            "in tests/contracts/README.md; fix the named entry.",
            file=sys.stderr,
        )


def _held_profile_errors(service: str, contract: dict[str, Any]) -> list[str]:
    """``held-profile`` exempts only entries of a service the preflight holds back."""
    if service in HELD:
        return []
    return [
        f"{service} {item['id']}: unexercised held-profile is only for held services "
        f"({', '.join(sorted(HELD))})"
        for item in [*contract["endpoints"], *contract.get("exec", [])]
        if item.get("unexercised") == "held-profile"
    ]


Loaded = tuple[list[Endpoint], list[ExecEntry], dict[tuple[str, str], set[str]], list[str]]


def _load() -> Loaded:
    contracts, errors = inventory.load(CONTRACT_DIR)
    if not contracts:
        errors.append("no contract files found")
    for service, contract in contracts.items():
        problems = inventory.validate(service, contract) or _held_profile_errors(service, contract)
        errors += [f"schema: {error}" for error in problems]
    if errors:
        return [], [], {}, errors
    expected = {
        (service, item["id"]): set(item["callers"])
        for service, contract in contracts.items()
        for item in [*contract["endpoints"], *contract.get("exec", [])]
    }
    return inventory.endpoints(contracts), inventory.exec_entries(contracts), expected, []


def _sync_errors(
    expected: dict[tuple[str, str], set[str]], scan: Scan, execs: exec_scan.ExecScan
) -> list[str]:
    actual: dict[tuple[str, str], set[str]] = {}
    reached = [(call.endpoint, call.caller) for call in scan.calls] + execs.calls
    for entry, caller in reached:
        actual.setdefault((entry.service, entry.id), set()).add(caller)
    routes = {(item.service, item.id): f"{item.method} {item.route}" for item in scan.found}
    routes |= {(item.service, item.id): "exec " + " ".join(item.command) for item in execs.found}
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
    found, found_exec, expected, errors = _load()
    scan, execs = Scan(found), exec_scan.ExecScan(found_exec)
    if not errors:
        for path in sorted((ROOT / "scripts").rglob("*.sh")):
            exec_scan.scan_script(execs, _scan_file(scan, path))
        errors = scan.errors + execs.errors + _sync_errors(expected, scan, execs)
    for finding in sorted(scan.findings):
        print(f"contract: finding: {finding}", file=sys.stderr)
    for error in errors:
        print(f"contract: error: {error}", file=sys.stderr)
    if errors:
        _steer(errors)
        return 1
    reached = {(call.endpoint.service, call.endpoint.id) for call in scan.calls}
    print(
        f"contracts: {len(found)} endpoints, {len(reached)} reached by literal calls; "
        f"{len(found_exec)} exec entries"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

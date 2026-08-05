#!/usr/bin/env python3
"""Check that literal HTTP API calls and contract entries cover each other."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = Path(__file__).resolve().parent
CALL_RE = re.compile(
    r"\b(?P<function>curl|api_get|api_fetch|api_post|api_put|api_delete|"
    r"post_restart_wait|wait_for_jellyfin_auth|http_json_post|http_check)\b(?P<args>[^\n]*)"
)
QUOTED_RE = re.compile(r"(?P<quote>['\"])(?P<value>.*?)(?P=quote)")
ASSIGN_RE = re.compile(
    r"(?:\blocal\s+(?:-\w+\s+)*)?(?P<name>[A-Za-z_]\w*)\s*=\s*(?P<value>['\"]?[^\n]+)"
)
ARRAY_RE = re.compile(r"(?P<name>[A-Za-z_]\w*curl_args)\s*=\((?P<args>.*?)\)", re.DOTALL)
VARIABLE_RE = re.compile(r"\$\{(?P<braced>[A-Za-z_]\w*)\}|\$(?P<plain>[A-Za-z_]\w*)")
PATH_RE = re.compile(r"(?P<path>/(?:[A-Za-z0-9_.~${}-]+/?)*)")
METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}

# The shared arr API helpers are split behind scripts/lib/arr/main.sh; retain
# the same Sonarr/Radarr service attribution for each topical caller.
_ARR_CONTRACT_CALLERS = {
    "scripts/lib/arr/quality.sh",
    "scripts/lib/arr/formats.sh",
    "scripts/lib/arr/indexers.sh",
    "scripts/lib/arr/storage.sh",
    "scripts/lib/arr/connections.sh",
}


@dataclass(frozen=True)
class Call:
    """One statically found request route."""

    service: str
    method: str
    path: str
    caller: str
    dynamic: bool


def _as_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a mapping")
    return value


def _join_path(base_path: str, path: str) -> str:
    return "/" + "/".join(part for part in f"{base_path}/{path}".split("/") if part)


def _load_contracts() -> tuple[dict[str, dict[str, Any]], list[str]]:
    contracts: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    for path in sorted(CONTRACT_DIR.glob("*.yml")):
        try:
            data = _as_mapping(yaml.safe_load(path.read_text(encoding="utf-8")), str(path))
        except (OSError, ValueError, yaml.YAMLError) as exc:
            errors.append(f"{path.relative_to(ROOT)}: {exc}")
            continue
        service = data.get("service")
        if not isinstance(service, str) or not service:
            errors.append(f"{path.relative_to(ROOT)}: service must be a non-empty string")
            continue
        if service in contracts:
            errors.append(f"duplicate contract service: {service}")
        contracts[service] = data
    return contracts, errors


def _variable_prefixes(text: str) -> dict[str, str]:
    prefixes: dict[str, str] = {}
    for match in ASSIGN_RE.finditer(text.replace("\\\n", " ")):
        value = match.group("value")
        route = PATH_RE.search(value)
        if route and re.search(r"(?:url|api|base)", match.group("name"), re.IGNORECASE):
            prefixes[match.group("name")] = route.group("path").rstrip("}")
    return prefixes


def _path_from_token(token: str, prefixes: dict[str, str]) -> tuple[str, bool] | None:
    token = token.split("?", 1)[0].split("#", 1)[0]
    token = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]+", "", token)
    variable = VARIABLE_RE.search(token)
    if variable:
        name = variable.group("braced") or variable.group("plain")
        suffix = token[variable.end() :]
        prefix = prefixes.get(name, "")
        if not prefix and not suffix.startswith("/"):
            return None
        token = f"{prefix}{suffix}"
    route = PATH_RE.search(token)
    if not route:
        return None
    path = route.group("path")
    dynamic = False

    def replace_variable(match: re.Match[str]) -> str:
        nonlocal dynamic
        name = match.group("braced") or match.group("plain")
        dynamic = not (name == "id" or name.endswith("_id"))
        return "{id}"

    path = VARIABLE_RE.sub(replace_variable, path)
    path = re.sub(r"/{2,}", "/", path)
    return path or "/", dynamic


def _method(function: str, args: str) -> str:
    explicit = re.search(r"(?:^|\s)-X\s+(GET|POST|PUT|PATCH|DELETE)\b", args)
    if explicit and explicit.group(1) in METHODS:
        return explicit.group(1)
    if function in {"api_post", "http_json_post"}:
        return "POST"
    if function == "api_put":
        return "PUT"
    if function == "api_delete":
        return "DELETE"
    if function == "wait_for_jellyfin_auth":
        return "POST"
    if function == "curl" and re.search(r"(?:^|\s)(?:-d|--data|--data-\w+)(?:\s|=)", args):
        return "POST"
    return "GET"


def _route_matches(pattern: str, path: str) -> bool:
    regex = re.escape(pattern).replace(r"\{id\}", r"[^/]+")
    return re.fullmatch(regex.rstrip(r"/"), path.rstrip("/"), re.IGNORECASE) is not None


def _services_for_call(
    caller: str,
    method: str,
    full_path: str,
    contracts: dict[str, dict[str, Any]],
) -> list[tuple[str, str]]:
    services: list[tuple[str, str]] = []
    for service, contract in contracts.items():
        base = str(contract.get("base_path", "/"))
        for endpoint in contract.get("endpoints", []):
            endpoint_map = _as_mapping(endpoint, f"{service} endpoint")
            route = _join_path(base, str(endpoint_map.get("path", "")))
            if endpoint_map.get("method") == method and _route_matches(route, full_path):
                services.append((service, str(endpoint_map.get("path", ""))))
                break
    if services:
        service_match = re.match(r"scripts/services/([^/]+)/", caller)
        if service_match:
            local_service = service_match.group(1)
            local_matches = [item for item in services if item[0] == local_service]
            if local_matches:
                return local_matches
        return services
    service_match = re.match(r"scripts/services/([^/]+)/", caller)
    if service_match:
        local_service = service_match.group(1)
        local_contract = contracts.get(local_service)
        if local_contract:
            for endpoint in local_contract.get("endpoints", []):
                endpoint_map = _as_mapping(endpoint, f"{local_service} endpoint")
                if endpoint_map.get("method") == method and _route_matches(
                    str(endpoint_map.get("path", "")), full_path
                ):
                    return [(local_service, str(endpoint_map.get("path", "")))]
    if caller in _ARR_CONTRACT_CALLERS:
        return [
            (service, str(endpoint_map.get("path", "")))
            for service in ("sonarr", "radarr")
            for endpoint in contracts[service].get("endpoints", [])
            for endpoint_map in [_as_mapping(endpoint, f"{service} endpoint")]
            if endpoint_map.get("method") == method
            and _route_matches(str(endpoint_map.get("path", "")), full_path)
        ]
    return []


# Callers whose unmatched routes are coverage errors rather than noise: the
# service configurators plus the shared helpers that speak to services.
_CONTRACT_REQUIRED_CALLERS = {
    *_ARR_CONTRACT_CALLERS,
    "scripts/lib/health.sh",
    "scripts/lib/http.sh",
    "scripts/lib/npm-remote.sh",
}


def _direct_call_route(args: str, prefixes: dict[str, str]) -> tuple[str, bool] | None:
    tokens = [item.group("value") for item in QUOTED_RE.finditer(args)]
    tokens += [item for item in args.split() if "/" in item]
    for token in tokens:
        candidate = _path_from_token(token, prefixes)
        likely_url = (
            VARIABLE_RE.search(token)
            or "service_local_url" in token
            or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", token)
        )
        if candidate and likely_url:
            return candidate
    return None


def _record_route(
    relative: str,
    method: str,
    route: tuple[str, bool],
    contracts: dict[str, dict[str, Any]],
    sink: tuple[list[Call], list[str], list[str]],
    require_contract: bool,
) -> None:
    calls, findings, errors = sink
    path_value, dynamic = route
    matches = _services_for_call(relative, method, path_value, contracts)
    if not matches:
        if require_contract and (
            relative.startswith("scripts/services/") or relative in _CONTRACT_REQUIRED_CALLERS
        ):
            errors.append(f"missing contract: {relative} {method} {path_value}")
        return
    if dynamic:
        findings.append(f"{relative}: {method} {path_value} uses path substitution")
    for service, endpoint_path in matches:
        calls.append(Call(service, method, endpoint_path, relative, dynamic))


def _find_calls(
    contracts: dict[str, dict[str, Any]],
) -> tuple[list[Call], list[str], list[str]]:
    calls: list[Call] = []
    findings: list[str] = []
    errors: list[str] = []
    sink = (calls, findings, errors)
    for path in sorted((ROOT / "scripts").rglob("*.sh")):
        relative = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        normalized = text.replace("\\\n", " ")
        prefixes = _variable_prefixes(normalized)
        for match in CALL_RE.finditer(normalized):
            args = match.group("args")
            method = _method(match.group("function"), args)
            route = _direct_call_route(args, prefixes)
            if route is not None:
                _record_route(relative, method, route, contracts, sink, require_contract=True)
        for assignment in ASSIGN_RE.finditer(normalized):
            if not assignment.group("name").endswith("curl_args"):
                continue
            args = assignment.group("value")
            method = _method("curl", args)
            for token_match in QUOTED_RE.finditer(args):
                route = _path_from_token(token_match.group("value"), prefixes)
                if route is not None:
                    _record_route(relative, method, route, contracts, sink, require_contract=False)
        for array_match in ARRAY_RE.finditer(normalized):
            args = array_match.group("args")
            method = _method("curl", args)
            for token_match in QUOTED_RE.finditer(args):
                route = _path_from_token(token_match.group("value"), prefixes)
                if route is not None:
                    _record_route(relative, method, route, contracts, sink, require_contract=False)
    return calls, sorted(set(findings)), errors


def _contract_calls(contracts: dict[str, dict[str, Any]]) -> dict[tuple[str, str, str], set[str]]:
    expected: dict[tuple[str, str, str], set[str]] = {}
    for service, contract in contracts.items():
        for endpoint in contract.get("endpoints", []):
            item = _as_mapping(endpoint, f"{service} endpoint")
            key = (service, str(item.get("method")), str(item.get("path")))
            expected[key] = {str(caller) for caller in item.get("callers", [])}
    return expected


def _steer(errors: list[str]) -> None:
    """Route each failure kind to its remediation, not just its symptom."""
    if any(error.startswith("missing contract:") for error in errors):
        print(
            "contract: a missing contract means an API call has no entry covering it "
            "(or the call is malformed):\ncontract: add the endpoint and its caller to "
            f"the service's file in {CONTRACT_DIR.relative_to(ROOT)}/ — "
            "see tests/contracts/README.md.",
            file=sys.stderr,
        )
    if any(error.startswith("dead contract entry:") for error in errors):
        print(
            "contract: a dead contract entry means the call it covered is gone: delete "
            f"the entry from the service's file in {CONTRACT_DIR.relative_to(ROOT)}/ — "
            "see tests/contracts/README.md.",
            file=sys.stderr,
        )


def main() -> int:
    """Run the bidirectional contract coverage check."""
    contracts, errors = _load_contracts()
    if not contracts:
        errors.append("no contract files found")
    expected = _contract_calls(contracts)
    calls, findings, scan_errors = _find_calls(contracts)
    errors.extend(scan_errors)
    actual: dict[tuple[str, str, str], set[str]] = {}
    for call in calls:
        actual.setdefault((call.service, call.method, call.path), set()).add(call.caller)

    for key, callers in sorted(actual.items()):
        if key not in expected:
            errors.append(
                f"missing contract: {key[0]} {key[1]} {key[2]} (callers: {sorted(callers)})"
            )
    for key, callers in sorted(expected.items()):
        if key not in actual:
            errors.append(f"dead contract entry: {key[0]} {key[1]} {key[2]}")
        elif callers != actual[key]:
            errors.append(
                f"caller mismatch: {key[0]} {key[1]} {key[2]} "
                f"contract={sorted(callers)} actual={sorted(actual[key])}"
            )
    for finding in findings:
        print(f"contract: finding: {finding}", file=sys.stderr)
    for error in errors:
        print(f"contract: error: {error}", file=sys.stderr)
    if errors:
        _steer(errors)
        return 1
    print(f"contracts: {len(expected)} endpoints, {len(actual)} literal calls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

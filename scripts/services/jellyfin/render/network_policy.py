#!/usr/bin/env python3
"""Plan Jellyfin network config changes.

Reads the current Jellyfin network config JSON on stdin and emits the line
protocol consumed by configure_jellyfin_networking:
    SKIP
    DRIFT + warning lines
    APPLY + JSON body
    APPLY_WITH_DRIFT + warning lines + --- + JSON body
"""

from __future__ import annotations

import dataclasses
import json
import os
import sys
from collections.abc import Iterable
from enum import Enum
from typing import cast

_AUTO_DISCOVERY = "AutoDiscovery"
_KNOWN_PROXIES = "KnownProxies"
_PUBLISHED_SERVER_URI_BY_SUBNET = "PublishedServerUriBySubnet"
_INTERNAL_PUBLISHED_PREFIX = "internal=http://"
_EXTERNAL_PUBLISHED_PREFIX = "external=https://jellyfin."
_JELLYFIN_HTTP_PORT = ":8096"
_MANAGED_PROXY_NAME = "npm"
_LEGACY_PROXY_IP = "172.28.0.10"
_DEFAULT_PROXY_IP = _LEGACY_PROXY_IP
_POLICY_SEPARATOR = "---"
_REMOTE_READY_VALUE = "true"


class _PolicyAction(str, Enum):
    SKIP = "SKIP"
    DRIFT = "DRIFT"
    APPLY = "APPLY"
    APPLY_WITH_DRIFT = "APPLY_WITH_DRIFT"


@dataclasses.dataclass
class _DesiredPolicy:
    auto_discovery: bool
    known_proxies: list[object]
    published_uris: list[str]


@dataclasses.dataclass
class _PolicyPlan:
    action: _PolicyAction
    changes: dict[str, object]
    drift: list[str]


def _desired_known_proxies(current: object, remote_ready: bool, npm_proxy_ip: str) -> list[object]:
    if not isinstance(current, list):
        current = []
    managed_proxy_values = {_MANAGED_PROXY_NAME, _LEGACY_PROXY_IP, npm_proxy_ip}
    out: list[object] = []
    managed_added = False
    for entry in current:
        if entry in managed_proxy_values:
            if remote_ready and not managed_added:
                out.append(npm_proxy_ip)
                managed_added = True
            continue
        out.append(entry)
    if remote_ready and not managed_added:
        out.append(npm_proxy_ip)
    return out


def _desired_published_uris(host: str, domain: str, remote_ready: bool) -> list[str]:
    want_published = [f"{_INTERNAL_PUBLISHED_PREFIX}{host}{_JELLYFIN_HTTP_PORT}"]
    if remote_ready:
        want_published.append(f"{_EXTERNAL_PUBLISHED_PREFIX}{domain}")
    return want_published


def _desired_policy(
    host: str,
    domain: str,
    remote_ready: bool,
    npm_proxy_ip: str,
    config: dict[str, object],
) -> _DesiredPolicy:
    return _DesiredPolicy(
        auto_discovery=True,
        known_proxies=_desired_known_proxies(
            config.get(_KNOWN_PROXIES, []), remote_ready, npm_proxy_ip
        ),
        published_uris=_desired_published_uris(host, domain, remote_ready),
    )


def _is_our_published_entry(entry: str) -> bool:
    if entry.startswith(_INTERNAL_PUBLISHED_PREFIX) and entry.endswith(_JELLYFIN_HTTP_PORT):
        published_host = entry[len(_INTERNAL_PUBLISHED_PREFIX) : -len(_JELLYFIN_HTTP_PORT)]
        if published_host == "localhost":
            return True
        return all(char.isdigit() or char == "." for char in published_host) and (
            published_host.count(".") == 3
        )
    return entry.startswith(_EXTERNAL_PUBLISHED_PREFIX)


def _assess_policy(config: dict[str, object], desired: _DesiredPolicy) -> _PolicyPlan:
    current_auto = config.get(_AUTO_DISCOVERY, True)
    current_proxies = config.get(_KNOWN_PROXIES, [])
    current_published = config.get(_PUBLISHED_SERVER_URI_BY_SUBNET, [])

    changes: dict[str, object] = {}
    drift: list[str] = []

    if current_auto == desired.auto_discovery:
        pass
    elif current_auto is not True:
        drift.append(f"{_AUTO_DISCOVERY} is {current_auto} (expected {desired.auto_discovery})")

    if current_proxies != desired.known_proxies:
        changes[_KNOWN_PROXIES] = desired.known_proxies

    if current_published == desired.published_uris:
        pass
    elif not current_published or all(
        _is_our_published_entry(entry) for entry in cast(Iterable[str], current_published)
    ):
        changes[_PUBLISHED_SERVER_URI_BY_SUBNET] = desired.published_uris
    else:
        drift.append(
            f"{_PUBLISHED_SERVER_URI_BY_SUBNET} is {current_published} "
            f"(expected {desired.published_uris})"
        )

    if drift and not changes:
        action = _PolicyAction.DRIFT
    elif not changes:
        action = _PolicyAction.SKIP
    elif drift:
        action = _PolicyAction.APPLY_WITH_DRIFT
    else:
        action = _PolicyAction.APPLY
    return _PolicyPlan(action=action, changes=changes, drift=drift)


def _emit_plan(config: dict[str, object], plan: _PolicyPlan) -> None:
    if plan.action is _PolicyAction.DRIFT:
        print(plan.action.value)
        for item in plan.drift:
            print(item)
        return
    if plan.action is _PolicyAction.SKIP:
        print(plan.action.value)
        return

    for key, value in plan.changes.items():
        config[key] = value
    print(plan.action.value)
    if plan.action is _PolicyAction.APPLY_WITH_DRIFT:
        for item in plan.drift:
            print(item)
        print(_POLICY_SEPARATOR)
    print(json.dumps(config))


def main() -> int:
    config: dict[str, object] = json.load(sys.stdin)
    remote_ready = os.environ["REMOTE_READY"] == _REMOTE_READY_VALUE
    host = os.environ["HOST_ADDR"]
    domain = os.environ["DOMAIN_VAL"]
    npm_proxy_ip = os.environ.get("NPM_PROXY_IP") or _DEFAULT_PROXY_IP
    desired = _desired_policy(host, domain, remote_ready, npm_proxy_ip, config)
    _emit_plan(config, _assess_policy(config, desired))
    return 0


if __name__ == "__main__":
    sys.exit(main())

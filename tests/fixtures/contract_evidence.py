"""Synthetic contracts.json data for the hosted preflight unit tests.

``covering`` returns the evidence a traced image job writes when the product
called every inventoried entry of the job's services on the candidate, with an
accepted status, and every declared read was seen. Tests remove or change one
part of it to prove a rule. The shape is the one tests/contracts/observe.py
writes; the verdict in tests/preflight/contracts.py judges it.
"""

from __future__ import annotations

from typing import Any

from preflight import contracts


def covering(plan: dict[str, Any], job: dict[str, Any]) -> dict[str, Any]:
    found, fingerprint = contracts.own_inventory()
    entries: dict[str, dict[str, Any]] = {}
    for entry in found:
        if entry.service in job["services"] and not entry.unexercised:
            status = entry.expect[0] if entry.expect else 200
            entries.setdefault(entry.service, {})[entry.id] = {
                "candidate": {f"{status:03d}": 1},
                "other": {},
                "reads": list(entry.reads),
            }
    return {
        "schema": contracts.SCHEMA,
        "inventory": fingerprint,
        "scenario": job["scenario"],
        "run_id": job["run_id"],
        "candidates": {service: plan["candidates"][service] for service in job["combination"]},
        "requests": 1 + sum(len(by_id) for by_id in entries.values()),
        "unparsed": 0,
        "entries": entries,
        "unmatched": {},
    }

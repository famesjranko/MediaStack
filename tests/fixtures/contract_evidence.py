"""Synthetic contracts.json data for the hosted preflight unit tests.

``covering`` returns the evidence a traced image job writes when the product
called every inventoried entry of the job's services on the candidate, with an
accepted status, every declared read was seen, and every exec entry exited with
an accepted status. Tests remove or change one
part of it to prove a rule. The shape is the one tests/contracts/observe.py
writes; the verdict in tests/preflight/contracts.py judges it.
"""

from __future__ import annotations

from typing import Any

from preflight import contracts


def covering(plan: dict[str, Any], job: dict[str, Any]) -> dict[str, Any]:
    found, fingerprint = contracts.own_inventory()
    entries: dict[str, dict[str, Any]] = {}
    execs: dict[str, dict[str, Any]] = {}
    for entry in found:
        if entry.service not in job["services"] or entry.unexercised:
            continue
        if not isinstance(entry, contracts.Endpoint):
            code = entry.expect_exit[0] if entry.expect_exit else 0
            execs.setdefault(entry.service, {})[entry.id] = {
                "candidate": {str(code): 1},
                "other": {},
            }
        else:
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
        "exec": {
            "calls": sum(len(by_id) for by_id in execs.values()),
            "unparsed": 0,
            "entries": execs,
            "unmatched": {},
        },
    }

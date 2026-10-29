"""Contract-coverage acceptance: pure rules over parsed contracts.json evidence.

Each image job uploads one contracts.json (tests/contracts/observe.py). A job
qualifies when its file is well formed, matches the job, its planned candidate
refs and the verifier's own inventory fingerprint, traced at least one product
request, and parsed every traced request. A candidate service qualifies when,
over every job whose ``services`` include it, each of its entries without
``unexercised`` was called on the candidate with an accepted status, every
declared read was seen, and nothing called it outside the inventory. Each of
its exec entries without ``unexercised`` likewise ran on the candidate with an
accepted exit status, and no exec into it was unlisted. An entry belongs to its
file's service, so an entry or an unlisted call of one service never blocks
another; held services are never candidates, so their entries block nothing.

Some candidates (socket-proxy, ddns-updater, ...) have no HTTP API or docker
exec that MediaStack calls, so no entries. Such a service passes this verdict,
and the verdict says so in ``uncovered``: its acceptance rests on its scenarios.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from dataclasses import dataclass, field
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "contracts"))
import inventory
from inventory import Endpoint, ExecEntry

SCHEMA = 2
MAX_BYTES = 1_000_000
# The scenarios that set MS_CONTRACT_TRACE on the commands that start product
# code. Only their jobs carry contract evidence; the others make no traced call.
TRACED_SCENARIOS = frozenset(
    {
        "fresh-install",
        "install-e2e",
        "upgrade-path",
        "portainer-upgrade",
        "npm-upgrade",
        "wireguard",
        "wireguard-upgrade",
    }
)
TIMES = chr(0xD7)  # the multiplication sign, as in "seen 404 times 2"
Job = dict[str, Any]
Observations = list[tuple[str, dict[str, Any]]]


@dataclass(frozen=True)
class Failure:
    """One reason a job or a candidate service does not qualify."""

    scope: str
    message: str


@dataclass
class Verdict:
    """Failures, plus what the digest PR body reports for the services that pass."""

    failures: list[Failure] = field(default_factory=list)
    exempt: dict[str, list[str]] = field(default_factory=dict)
    stale: list[str] = field(default_factory=list)
    uncovered: list[str] = field(default_factory=list)


def own_inventory() -> tuple[list[Endpoint | ExecEntry], str]:
    """The verifier's endpoint and exec entries and fingerprint, from the checkout under test."""
    return [*inventory.load_endpoints(), *inventory.load_exec()], inventory.fingerprint()


def read_contracts(path: pathlib.Path) -> Any:
    """Parse one job's contracts.json: a regular file under 1 MB."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size >= MAX_BYTES:
        raise ValueError(f"invalid contract evidence file: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def _counts_ok(value: Any, key_pattern: str = r"\d{3}") -> bool:
    return isinstance(value, dict) and all(
        isinstance(key, str) and re.fullmatch(key_pattern, key) and type(count) is int and count > 0
        for key, count in value.items()
    )


def _exits_ok(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"candidate", "other"}
        and all(_counts_ok(counts, r"\d{1,3}") for counts in value.values())
    )


def _exec_ok(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {"calls", "unparsed", "entries", "unmatched"}:
        return False
    entries, unmatched = value["entries"], value["unmatched"]
    return (
        _count_ok(value["calls"])
        and _count_ok(value["unparsed"])
        and isinstance(entries, dict)
        and all(
            isinstance(by_id, dict) and all(_exits_ok(item) for item in by_id.values())
            for by_id in entries.values()
        )
        and isinstance(unmatched, dict)
        and all(_unmatched_ok(item) for item in unmatched.values())
    )


def _entry_ok(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"candidate", "other", "reads"}
        and _counts_ok(value["candidate"])
        and _counts_ok(value["other"])
        and isinstance(value["reads"], list)
        and all(isinstance(read, str) for read in value["reads"])
    )


def _unmatched_ok(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"candidate", "other"}
        and all(_count_ok(count) for count in value.values())
    )


def _count_ok(value: Any) -> bool:
    return type(value) is int and value >= 0


def _shape_ok(data: Any) -> bool:
    keys = {"schema", "inventory", "scenario", "run_id", "candidates", "requests", "unparsed"}
    if not isinstance(data, dict) or set(data) != keys | {"entries", "unmatched", "exec"}:
        return False
    entries, unmatched, candidates = data["entries"], data["unmatched"], data["candidates"]
    return (
        type(data["schema"]) is int
        and _count_ok(data["requests"])
        and _count_ok(data["unparsed"])
        and isinstance(candidates, dict)
        and all(isinstance(ref, str) for ref in candidates.values())
        and isinstance(entries, dict)
        and all(
            isinstance(by_id, dict) and all(_entry_ok(item) for item in by_id.values())
            for by_id in entries.values()
        )
        and isinstance(unmatched, dict)
        and all(_unmatched_ok(item) for item in unmatched.values())
        and _exec_ok(data["exec"])
    )


def _unknown(data: dict[str, Any], found: list[Endpoint | ExecEntry]) -> list[str]:
    declared = {(item.service, item.id): item.reads for item in found if isinstance(item, Endpoint)}
    execs = {(item.service, item.id) for item in found if isinstance(item, ExecEntry)}
    unknown = [
        f"unknown exec entry {service} {entry_id}"
        for service, by_id in sorted(data["exec"]["entries"].items())
        for entry_id in sorted(by_id)
        if (service, entry_id) not in execs
    ]
    for service, by_id in sorted(data["entries"].items()):
        for entry_id, item in sorted(by_id.items()):
            reads = declared.get((service, entry_id))
            if reads is None:
                unknown.append(f"unknown contract entry {service} {entry_id}")
            elif set(item["reads"]) - set(reads):
                unknown.append(f"{service} {entry_id}: reports reads it does not declare")
    return unknown


def _identity_problem(job: Job, data: dict[str, Any], candidates: dict[str, str]) -> str | None:
    """Why the evidence is not this job's own: another schema, scenario, run or image."""
    if data["schema"] != SCHEMA or data["scenario"] != job["scenario"]:
        return "contracts.json schema or scenario does not match the job"
    if data["run_id"] != job["run_id"]:
        return "contracts.json comes from another run"
    if data["candidates"] != {service: candidates[service] for service in job["combination"]}:
        return "contracts.json candidates do not match the job's planned candidates"
    return None


def check_job(
    job: Job,
    data: Any,
    candidates: dict[str, str],
    fingerprint: str,
    found: list[Endpoint | ExecEntry],
) -> list[str]:
    """Why one job's contract evidence does not qualify; empty when it does.

    ``candidates`` are the plan's candidate refs by service.
    """
    if not _shape_ok(data):
        return ["contracts.json is malformed"]
    problem = _identity_problem(job, data, candidates)
    if problem:
        return [problem]
    if data["inventory"] != fingerprint:
        return ["contract inventory fingerprint does not match the tested source"]
    problems = _unknown(data, found)
    if data["requests"] == 0:
        problems.append("contract trace inactive: no product request was traced")
    if data["unparsed"]:
        plural = "" if data["unparsed"] == 1 else "s"
        problems.append(f"contract trace has {data['unparsed']} unparsed request{plural}")
    bad_exec = data["exec"]["unparsed"]
    if bad_exec:
        plural = "" if bad_exec == 1 else "s"
        problems.append(f"contract trace has {bad_exec} unparsed exec record{plural}")
    return problems


def _section(data: dict[str, Any], entry: Endpoint | ExecEntry) -> dict[str, Any]:
    """The evidence for one entry's kind: HTTP entries, or exec entries."""
    section: dict[str, Any] = (
        data["entries"] if isinstance(entry, Endpoint) else data["exec"]["entries"]
    )
    return section


def _observations(
    entry: Endpoint | ExecEntry, evidence: list[tuple[Job, dict[str, Any]]]
) -> Observations:
    return [
        (job["scenario"], _section(data, entry)[entry.service][entry.id])
        for job, data in evidence
        if entry.id in _section(data, entry).get(entry.service, {})
    ]


def _accepted_in(entry: Endpoint | ExecEntry, observations: Observations) -> list[str]:
    return sorted(
        {
            scenario
            for scenario, item in observations
            if any(entry.accepts(int(status)) for status in item["candidate"])
        }
    )


def _seen(observations: Observations, prefix: str = "") -> str:
    parts = []
    for scenario, item in observations:
        for side, where in (("candidate", ""), ("other", " on another image")):
            parts += [
                f"{prefix}{status}{TIMES}{count}{where} in {scenario}"
                for status, count in sorted(item[side].items())
            ]
    return "seen " + ", ".join(parts) if parts else "never called"


def _exec_failure(entry: ExecEntry, evidence: list[tuple[Job, dict[str, Any]]]) -> str | None:
    observations = _observations(entry, evidence)
    if _accepted_in(entry, observations):
        return None
    exits = sorted({int(code) for _, item in observations for code in item["candidate"]})
    if exits:
        return f"{entry.key}: exit {', '.join(map(str, exits))}"
    return f"{entry.key}: not exercised on candidate ({_seen(observations, 'exit ')})"


def _entry_failure(entry: Endpoint, evidence: list[tuple[Job, dict[str, Any]]]) -> str | None:
    observations = _observations(entry, evidence)
    if not _accepted_in(entry, observations):
        return f"{entry.key}: not exercised on candidate ({_seen(observations)})"
    seen_reads = {read for _, item in observations for read in item["reads"]}
    missing = [read for read in entry.reads if read not in seen_reads]
    return f"{entry.key}: missing reads {', '.join(missing)}" if missing else None


def _unlisted_calls(
    service: str, evidence: list[tuple[Job, dict[str, Any]]], kind: str
) -> dict[str, set[str]]:
    """Unmatched HTTP calls or execs into ``service``, each with its scenarios."""
    scenarios: dict[str, set[str]] = {}
    for job, data in evidence:
        unmatched = data["unmatched"] if kind == "http" else data["exec"]["unmatched"]
        for call, counts in unmatched.items():
            if call.split(" ", 1)[0] == service and counts["candidate"] + counts["other"]:
                scenarios.setdefault(call, set()).add(job["scenario"])
    return scenarios


def _unlisted(service: str, evidence: list[tuple[Job, dict[str, Any]]]) -> list[str]:
    calls = _unlisted_calls(service, evidence, "http")
    execs = _unlisted_calls(service, evidence, "exec")
    return [
        f"{call}: unlisted call ({', '.join(sorted(names))})"
        for call, names in sorted(calls.items())
    ] + [
        f"{service}: unlisted exec {call.partition(' ')[2] or '(no command)'} "
        f"({', '.join(sorted(names))})"
        for call, names in sorted(execs.items())
    ]


def _check_service(
    verdict: Verdict,
    service: str,
    evidence: list[tuple[Job, dict[str, Any]]],
    found: list[Endpoint | ExecEntry],
) -> None:
    entries = [item for item in found if item.service == service]
    if not entries:
        verdict.uncovered.append(
            f"{service}: no contract entries; acceptance rests on its scenarios"
        )
    messages = []
    for entry in entries:
        if entry.unexercised:
            verdict.exempt.setdefault(service, []).append(f"{entry.id} ({entry.unexercised})")
            exercised = _accepted_in(entry, _observations(entry, evidence))
            if exercised:
                verdict.stale.append(
                    f"{entry.key}: exempt as {entry.unexercised} but exercised on candidate "
                    f"in {', '.join(exercised)}"
                )
            continue
        if isinstance(entry, ExecEntry):
            messages.append(_exec_failure(entry, evidence))
        else:
            messages.append(_entry_failure(entry, evidence))
    messages += _unlisted(service, evidence)
    verdict.failures += [Failure(service, message) for message in messages if message]


def verdict(
    evidence: list[tuple[Job, Any]],
    services: list[str],
    candidates: dict[str, str],
    fingerprint: str,
    found: list[Endpoint | ExecEntry],
) -> Verdict:
    """Judge every job's evidence, then each candidate service over its qualifying jobs.

    ``evidence`` pairs each plan job with its parsed contracts.json; ``services``
    are the candidates under acceptance; ``candidates`` is the plan's ref for
    each candidate service, which each job's evidence must name for the
    services in its ``combination``.
    """
    result = Verdict()
    qualified = []
    for job, data in evidence:
        problems = check_job(job, data, candidates, fingerprint, found)
        result.failures += [Failure(job["id"], problem) for problem in problems]
        if not problems:
            qualified.append((job, data))
    for service in services:
        jobs = [(job, data) for job, data in qualified if service in job["services"]]
        if not jobs:
            result.failures.append(Failure(service, "no qualifying contract evidence"))
            continue
        _check_service(result, service, jobs, found)
    return result

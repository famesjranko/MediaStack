#!/usr/bin/env python3
"""Reconcile a gitleaks report against the declared finding set.

Split out of tests/secret-scan.sh so the reconciliation contract can be proved
directly - feed it a report and a declaration file and read the exit code - and
so the scanner wrapper's slow probes go back to proving only the scanner.

Usage: secret_scan_reconcile.py <report.json> <expected> <scan-root> <tree|history>
Exit codes match the caller's: 0 all declared, 1 mismatch, 2 unreadable report
or a declaration file holding no declarations.
"""

from __future__ import annotations

import collections
import hashlib
import json
import os
import sys
from typing import Any

# Steering branches by scan mode because the remediations differ: a tree finding
# can still be removed, a published one cannot. Declaring either is never the fix.
DOC = "see the secret-scan section of tests/README.md"


def identity(finding: dict[str, Any], root: str) -> str:
    """Stable per-finding identity: rule, repo-relative path, content fingerprint.

    The fingerprint hashes the rule, the path, gitleaks' redacted Match and its
    Entropy - all properties of the finding's own content, never its line
    number, so an edit elsewhere in the file leaves it unchanged while a
    different secret in a file that already carries a declared false positive
    produces a new identity. Match is already redacted (--redact=100) and only
    its hash is ever emitted.
    """
    path = finding.get("File", "")
    if os.path.isabs(path):
        path = os.path.relpath(path, root)
    rule = finding.get("RuleID", "?")
    entropy = f"{float(finding.get('Entropy') or 0.0):.6f}"
    material = "\0".join([rule, path, finding.get("Match", ""), entropy])
    digest = hashlib.sha256(material.encode()).hexdigest()[:16]
    return f"{rule}\t{path}\t{digest}"


def _load_findings(report_path: str) -> list[dict[str, Any]]:
    # A missing report is the no-findings case; it can never read as a pass,
    # because the caller has already refused to run with an empty declaration set.
    if not os.path.isfile(report_path):
        return []
    try:
        with open(report_path) as handle:
            loaded: list[dict[str, Any]] = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"SCAN-ERROR\tunreadable report: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    return loaded


def _declarations(expected_path: str, mode: str) -> list[str]:
    # A "history-only\t" prefix declares a finding that only reachable history
    # produces - a file since deleted or renamed. The tree gate ignores those
    # lines entirely (the tree cannot produce them, so listing them plainly
    # would read as stale); the history gate strips the marker and holds them
    # to the same reconciliation as every other declaration.
    expected_lines = []
    with open(expected_path) as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("history-only\t"):
                if mode == "history":
                    expected_lines.append(line[len("history-only\t") :])
                continue
            expected_lines.append(line)
    return expected_lines


def _steer(mode: str, expected_path: str, unexpected: bool, absent: bool) -> None:
    if unexpected and mode == "tree":
        print(
            "tree gate: remove the secret from the tree - and rotate it if it was ever real.\n"
            f"Declaring it is not the fix: {expected_path} grows only under human review, "
            f"never to make a run pass ({DOC}).",
            file=sys.stderr,
        )
    elif unexpected:
        print(
            "history gate: the commit is published and cannot be taken back - rotating the "
            "credential is the only real remediation.\nDeclaring the finding afterwards needs "
            f"human review; {expected_path} never grows to make a run pass ({DOC}).",
            file=sys.stderr,
        )
    if absent:
        print(
            f"{mode} gate: a declaration nothing produced is stale - remove its line from "
            f"{expected_path} ({DOC}).",
            file=sys.stderr,
        )


def main(argv: list[str]) -> int:
    """Reconcile the report at argv[0] against the declarations at argv[1]."""
    if len(argv) != 4:
        print(
            "SCAN-ERROR\tusage: secret_scan_reconcile.py <report.json> <expected> "
            "<scan-root> <tree|history>",
            file=sys.stderr,
        )
        return 2
    report_path, expected_path, root, mode = argv

    actual = collections.Counter(identity(f, root) for f in _load_findings(report_path))
    expected = collections.Counter(_declarations(expected_path, mode))

    # History compares distinct identities: every edit of a declared line re-adds
    # it as a new finding, while tree multiplicity is the tree gate's job.
    if mode == "history":
        actual = collections.Counter(set(actual))
        expected = collections.Counter(set(expected))

    # Fail closed: an all-comment declaration file would otherwise turn the gate
    # into "report whatever you find", which is what a rubber stamp looks like.
    if not expected:
        print(f"SCAN-ERROR\tno declarations in {expected_path}", file=sys.stderr)
        return 2

    rc, unexpected, absent = 0, False, False
    for line, n in sorted((actual - expected).items()):
        print(f"UNEXPECTED\t{line}\t(x{n})", file=sys.stderr)
        rc, unexpected = 1, True
    for line, n in sorted((expected - actual).items()):
        print(f"DECLARED-BUT-ABSENT\t{line}\t(x{n})", file=sys.stderr)
        rc, absent = 1, True

    _steer(mode, expected_path, unexpected, absent)
    if not rc:
        print(f"{mode} gate: {sum(actual.values())} finding(s), all declared")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

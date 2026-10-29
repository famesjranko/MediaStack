"""Check accepted images without candidate drift; maintain failure and inactivity issues."""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import subprocess
import tempfile
from typing import Any

from .model import ROOT, build_plan, load_json, make_job, one_line, rows, source_sha
from .runner import sanitize


def plan(run_id: str, fixtures: dict[str, str]) -> dict[str, Any]:
    baseline = rows(ROOT / "docs/operations/image-digests.lock")
    result = build_plan(baseline, baseline, [], source_sha(), run_id, fixtures)
    result["jobs"] = [make_job(result, "baseline-install-e2e", "install-e2e", [], [])]
    return result


def read_optional(path: pathlib.Path) -> str:
    return path.read_text(errors="replace") if path.exists() else ""


def report_data(path: pathlib.Path) -> tuple[dict[str, Any], str]:
    try:
        value = load_json(path)
        if not isinstance(value, dict):
            raise ValueError("expected an object")
    except (OSError, ValueError) as exc:
        return {}, f"Missing or invalid {path.name}: {one_line(exc)}"
    return value, ""


def complete(result: dict[str, Any]) -> bool:
    counts = {"rc": 0, "failures": 0, "skips": 0}
    return (
        all(type(result.get(key)) is int and result[key] == value for key, value in counts.items())
        and type(result.get("passes")) is int
        and result["passes"] > 0
        and all(
            key in result and result[key] is None
            for key in ("evidence_error", "disk_error", "runner_error")
        )
    )


def failure_report(folder: pathlib.Path, outcome: str, url: str) -> str | None:
    result, result_error = report_data(folder / "result/result.json")
    runtime, runtime_error = report_data(folder / "result/runtime.json")
    if not all(
        isinstance(runtime.get(key), str) and runtime[key]
        for key in ("client", "engine", "compose")
    ):
        runtime_error = runtime_error or "Missing or invalid runtime version fields."
    if outcome == "success" and complete(result) and not runtime_error:
        return None
    log = read_optional(folder / "result/scenario.log") or read_optional(folder / "runner.log")
    failures = [line for line in log.splitlines() if "[FAIL]" in line or "[SKIP]" in line]
    diagnostics = failures or log.splitlines()[-30:] or ["Result missing; see the job log."]
    lines = [
        "The weekly accepted-Stable `install-e2e` check lacks complete passing evidence.",
        "No candidate image was selected and no digest was published.",
        "",
        f"[Run and artifacts]({url}). Job result: {outcome}.",
        "",
        "Runtime inside DinD (after the installer ran):",
    ]
    lines.extend(
        f"- {key}: `{one_line(runtime.get(key, 'unavailable'))}`"
        for key in ("client", "engine", "compose")
    )
    lines += ["", result_error, runtime_error] if result_error or runtime_error else []
    lines += ["", "Failed or skipped assertions, or the final diagnostic lines:", "", "```text"]
    lines.extend(sanitize(line).replace("`", "'")[:500] for line in diagnostics[:30])
    lines += [
        "```",
        "",
        "Inspect `result.json`, `runtime.json` and `scenario.log` in the artifact.",
    ]
    return "\n".join(lines) + "\n"


def inactivity_report(timestamp: str, now: dt.datetime, url: str) -> str | None:
    last_commit = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    age = (now - last_commit).days
    if age < 45:
        return None
    return (
        f"The default branch's newest commit is {age} days old ({last_commit.date()}).\n\n"
        "GitHub can disable scheduled workflows after 60 days without repository activity. "
        "This conservative reminder uses the last default-branch commit; it does not assume "
        "issue edits or workflow runs reset GitHub's inactivity clock.\n\n"
        "Review the Actions tab before day 60. After repository activity resumes, enable any "
        "disabled workflow and dispatch the canary to confirm it works:\n\n"
        "```bash\ngh workflow enable image-drift.yml\n"
        "gh workflow enable baseline-canary.yml\n"
        "gh workflow run baseline-canary.yml --ref main\n```\n\n"
        "Set a reminder outside GitHub if the repository will stay idle: a disabled schedule "
        "cannot report its own absence. No keepalive commit is made.\n\n"
        "[GitHub schedule documentation]"
        "(https://docs.github.com/en/actions/reference/workflows-and-actions/"
        "events-that-trigger-workflows#schedule).\n\n"
        f"[Latest check]({url}).\n"
    )


def gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True, timeout=60)


def sync_issue(label: str, title: str, body: str | None) -> None:
    gh("label", "create", label, "--color", "D93F0B", "--description", title, "--force")
    issues = json.loads(
        gh(
            "issue",
            "list",
            "--label",
            label,
            "--state",
            "all",
            "--limit",
            "100",
            "--json",
            "number,state",
        )
    )
    opened = [issue for issue in issues if issue["state"] == "OPEN"]
    if len(opened) > 1:
        raise ValueError(f"multiple open {label} issues; reconcile them before reporting")
    previous = next(iter(opened or issues), None)
    if body is None:
        if opened:
            gh("issue", "close", str(opened[0]["number"]))
        return
    with tempfile.TemporaryDirectory() as temp:
        path = pathlib.Path(temp) / "body.md"
        path.write_text(body)
        if previous:
            number = str(previous["number"])
            gh("issue", "edit", number, "--title", title, "--body-file", str(path))
            if previous["state"] == "CLOSED":
                gh("issue", "reopen", number)
        else:
            gh("issue", "create", "--label", label, "--title", title, "--body-file", str(path))

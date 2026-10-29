"""Prove saved monitoring state survives a real Kuma image replacement.

Socket.IO and HTTP reads use the running service, including fresh admin login.
Only the paused fixture monitor's history is compared: normal service monitors
keep polling throughout the update. No database writes bypass the application.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from upgrade_state import assert_no_secrets, changed_keys, read_env

NAME = "MediaStack migration fixture"
SNAPSHOT = pathlib.Path("/tmp/ms-kuma-upgrade-state.json")


def collect(action: str) -> dict[str, Any]:
    env = read_env()
    credentials = {
        "username": env["JELLYFIN_ADMIN_USER"],
        "password": env["JELLYFIN_ADMIN_PASSWORD"],
    }
    script = pathlib.Path(__file__).with_name("kuma_socket.js").read_text()
    result = subprocess.run(
        ["docker", "exec", "-i", "-w", "/app", "uptime-kuma", "node", "-e", script, action],
        input=json.dumps(credentials),
        capture_output=True,
        text=True,
        timeout=75,
    )
    if result.returncode:
        # Never print a transport payload or server error that can hold secrets.
        raise ValueError(f"Kuma {action} failed (login, request or required state)")
    data: dict[str, Any] = json.loads(result.stdout)
    assert_no_secrets(data, {credentials["password"]})
    return data


def records(value: Any, label: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value or any(not isinstance(x, dict) for x in value):
        raise ValueError(f"Kuma {label} is empty or malformed")
    return value


def fields(row: dict[str, Any], names: tuple[str, ...]) -> dict[str, Any]:
    result = {name: row[name] for name in names}
    if any(value is None for value in result.values()):
        raise ValueError("Kuma required field is null")
    return result


def monitor_state(data: dict[str, Any]) -> tuple[list[dict[str, Any]], int]:
    monitors = records(data["monitors"], "monitors")
    fixtures = [m for m in monitors if m["name"] == NAME]
    managed = [m for m in monitors if m["name"] != NAME]
    if len(fixtures) != 1 or len(managed) < 2:
        raise ValueError("Kuma fixture or managed monitors missing")
    fixture = fixtures[0]
    if fixture["active"] not in (False, 0) or fixture["type"] != "push":
        raise ValueError("Kuma fixture is not a paused push monitor")
    common: tuple[str, ...] = (
        "id",
        "name",
        "type",
        "active",
        "interval",
        "retryInterval",
        "maxretries",
    )
    result = []
    for monitor in monitors:
        names = common
        if monitor["type"] == "http":
            names += ("url", "method", "accepted_statuscodes", "maxredirects")
        elif monitor["type"] == "push":
            names += ("pushTokenFingerprint",)
        result.append(fields(monitor, names))
    return sorted(result, key=lambda m: m["id"]), int(fixture["id"])


def history_state(value: Any, monitor_id: int) -> list[dict[str, Any]]:
    history = records(value, "history")
    expected = {(1, "migration-up", 12), (0, "migration-down", 30), (1, "migration-up", 24)}
    seen = {(row["status"], row["msg"], row["ping"]) for row in history}
    if not expected <= seen or any(row["monitor_id"] != monitor_id for row in history):
        raise ValueError("Kuma history lost seeded up/down events")
    if not any(row["status"] == 0 and row["duration"] > 0 for row in history):
        raise ValueError("Kuma history lost the timed outage")
    names = ("id", "monitor_id", "status", "time", "msg", "ping", "important", "duration")
    return sorted((fields(row, names) for row in history), key=lambda row: row["id"])


def chart_state(value: Any) -> list[dict[str, Any]]:
    rows = records(value, "history chart")
    result = [
        fields(row, ("timestamp", "up", "down", "avgPing", "minPing", "maxPing"))
        for row in rows
        if row["up"] or row["down"]
    ]
    if sum(row["up"] for row in result) < 2 or sum(row["down"] for row in result) < 1:
        raise ValueError("Kuma history chart lost seeded samples")
    return sorted(result, key=lambda row: row["timestamp"])


def page_state(data: dict[str, Any]) -> dict[str, Any]:
    config = fields(data["config"], ("slug", "title", "theme", "published", "showPoweredBy"))
    groups = records(data["publicGroupList"], "status page groups")
    config["groups"] = [
        {
            "name": group["name"],
            "weight": group["weight"],
            "monitors": sorted(row["id"] for row in records(group["monitorList"], "page monitors")),
        }
        for group in groups
    ]
    return config


def snapshot(data: dict[str, Any]) -> dict[str, Any]:
    monitors, monitor_id = monitor_state(data)
    result: dict[str, Any] = {
        "kuma/monitors": monitors,
        "kuma/history": history_state(data["history"], monitor_id),
        "kuma/settings": fields(data["settings"], ("keepDataPeriodDays", "checkUpdate")),
    }
    if result["kuma/settings"]["keepDataPeriodDays"] != 365:
        raise ValueError("Kuma lost the custom retention setting")
    for period in ("minute", "hour", "day"):
        result[f"kuma/history-{period}"] = chart_state(data["charts"][period])
    for slug in ("mediastack", "migration-fixture"):
        result[f"kuma/page-{slug}"] = page_state(data["pages"][slug])
    membership = result["kuma/page-migration-fixture"]["groups"]
    if not any(monitor_id in group["monitors"] for group in membership):
        raise ValueError("Kuma status page lost the fixture monitor")
    return result


def main() -> None:
    action = sys.argv[1]
    data = collect(action if action in ("seed", "drop") else "snapshot")
    if action == "drop":
        return
    current = snapshot(data)
    if action in ("seed", "save"):
        SNAPSHOT.write_text(json.dumps(current, sort_keys=True))
    elif action == "check":
        previous = json.loads(SNAPSHOT.read_text())
        changed = changed_keys(previous, current)
        if changed:
            raise ValueError("persistent state changed: " + ", ".join(changed))
    else:
        raise ValueError("unknown Kuma fixture action")
    print(f"Kuma {action}: {len(current)} state groups verified")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.exit(f"Kuma history/settings/login validation failed: {exc}")
    except subprocess.SubprocessError:
        sys.exit("Kuma history/settings/login request timed out")

"""Seed and compare persistent user state through the real service APIs in DinD."""

from __future__ import annotations

import http.cookiejar
import json
import pathlib
import sys
import urllib.parse
import urllib.request
from typing import Any


def read_env() -> dict[str, str]:
    values = {}
    for line in pathlib.Path(".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key] = value
    return values


class StateClient:
    def __init__(self) -> None:
        self.env = read_env()
        self.http = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def call(self, app: str, path: str, body: Any = None, method: str = "GET") -> Any:
        ports = {"sonarr": 8989, "radarr": 7878, "jellyfin": 8096, "seerr": 5055}
        headers = {"Content-Type": "application/json"}
        key = self.env[f"{app.upper()}_API_KEY"]
        headers["X-Api-Key" if app != "jellyfin" else "X-Emby-Token"] = key
        req = urllib.request.Request(
            f"http://127.0.0.1:{ports[app]}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers,
            method=method,
        )
        with self.http.open(req, timeout=20) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def flip_profile(self) -> None:
        profiles = self.call("sonarr", "/api/v3/qualityprofile")
        profile = next(p for p in profiles if p["name"] == "1080p Balanced")
        profile["upgradeAllowed"] = not profile["upgradeAllowed"]
        self.call("sonarr", f"/api/v3/qualityprofile/{profile['id']}", profile, "PUT")

    def seed(self) -> None:
        self.call("jellyfin", "/Users/New", {"Name": "upgrade-fixture-user"}, "POST")
        self.flip_profile()

    def qbt(self, endpoint: str) -> Any:
        credentials = urllib.parse.urlencode(
            {
                "username": self.env["JELLYFIN_ADMIN_USER"],
                "password": self.env["JELLYFIN_ADMIN_PASSWORD"],
            }
        ).encode()
        with self.http.open(
            "http://127.0.0.1:8080/api/v2/auth/login", credentials, timeout=20
        ) as response:
            if response.read().strip() != b"Ok.":
                raise ValueError("qBittorrent login failed")
        with self.http.open(f"http://127.0.0.1:8080/api/v2/{endpoint}", timeout=20) as response:
            return json.load(response)

    def snapshot(self) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for app in ("sonarr", "radarr"):
            for endpoint in ("rootfolder", "qualityprofile", "downloadclient", "indexer"):
                rows = self.call(app, f"/api/v3/{endpoint}")
                if not isinstance(rows, list) or not rows:
                    raise ValueError(f"{app}/{endpoint}: required population is empty")
                # Free space and disk totals change during a run; configuration does not.
                result[f"{app}/{endpoint}"] = [
                    {
                        k: v
                        for k, v in row.items()
                        if k not in ("freeSpace", "totalSpace", "unmappedFolders")
                    }
                    for row in rows
                ]
        users = self.call("jellyfin", "/Users")
        if not any(u["Name"] == "upgrade-fixture-user" for u in users):
            raise ValueError("Jellyfin lost the fixture user")
        result["jellyfin/users"] = sorted((u["Id"], u["Name"]) for u in users)
        result["jellyfin/libraries"] = [
            {k: row[k] for k in ("Name", "Locations", "ItemId", "CollectionType")}
            for row in self.call("jellyfin", "/Library/VirtualFolders")
        ]
        for app in ("sonarr", "radarr"):
            result[f"seerr/{app}"] = self.call("seerr", f"/api/v1/settings/{app}")
        result["qbittorrent/categories"] = self.qbt("torrents/categories")
        preferences = self.qbt("app/preferences")
        result["qbittorrent/preferences"] = {
            name: preferences[name]
            for name in (
                "save_path",
                "temp_path",
                "web_ui_username",
                "max_ratio",
                "max_seeding_time",
            )
        }
        result["keys"] = {
            name: value for name, value in self.env.items() if name.endswith("_API_KEY")
        }
        return result


def main() -> None:
    client = StateClient()
    command = sys.argv[1]
    if command == "seed":
        client.seed()
    elif command == "flip":
        client.flip_profile()
    else:
        snapshot = json.loads(json.dumps(client.snapshot()))
        path = pathlib.Path("/tmp/upgrade-state.json")
        if command == "save":
            path.write_text(json.dumps(snapshot, sort_keys=True))
        elif command == "check":
            previous = json.loads(path.read_text())
            changed = sorted(
                k for k in previous.keys() | snapshot.keys() if previous.get(k) != snapshot.get(k)
            )
            if changed:
                raise SystemExit("persistent state changed: " + ", ".join(changed))
            print("persistent user state preserved")
        else:
            raise SystemExit("unknown upgrade-state command")


if __name__ == "__main__":
    main()

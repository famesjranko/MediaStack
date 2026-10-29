"""Seed Portainer on the accepted image; compare through authenticated APIs only."""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.request
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from upgrade_state import assert_no_secrets, changed_keys, fingerprint, read_env

USER = "migration-reader"
TAG = "migration-tag"
ENDPOINT = "migration-local"
STATE = pathlib.Path("/tmp/portainer-state.json")


class Client:
    def __init__(self) -> None:
        self.env = read_env()
        self.password = self.env["JELLYFIN_ADMIN_PASSWORD"]
        self.key = self.env["PORTAINER_API_KEY"]
        if not self.password or not self.key:
            raise ValueError("Portainer stored credentials are missing")

    def call(self, path: str, body: Any = None, method: str = "GET", headers: Any = None) -> Any:
        request = urllib.request.Request(
            "http://127.0.0.1:9000/api" + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json", **(headers or {"X-API-Key": self.key})},
            method=method,
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def login(self, username: str, user_id: int, role: int) -> None:
        login = self.call("/auth", {"Username": username, "Password": self.password}, "POST")
        token = login["jwt"]
        if not isinstance(token, str) or not token:
            raise ValueError("Portainer login returned no token")
        user = self.call("/users/me", headers={"Authorization": "Bearer " + token})
        if (user["Id"], user["Username"], user["Role"]) != (user_id, username, role):
            raise ValueError("Portainer login identity changed")

    def seed(self) -> None:
        # Candidate checks never call this: lost records must stay lost.
        self.call("/users", {"Username": USER, "Password": self.password, "Role": 2}, "POST")
        tag = self.call("/tags", {"Name": TAG}, "POST")
        endpoints = self.call("/endpoints")
        if len(endpoints) != 1:
            raise ValueError("expected one configured local Docker endpoint")
        self.call(
            f"/endpoints/{endpoints[0]['Id']}",
            {"Name": ENDPOINT, "TagIds": [tag["ID"]]},
            "PUT",
        )

    def snapshot(self) -> dict[str, Any]:
        users = self.call("/users")
        identities = sorted(
            ({name: user[name] for name in ("Id", "Username", "Role")} for user in users),
            key=lambda row: row["Id"],
        )
        admin = next(u for u in identities if u["Username"] == self.env["JELLYFIN_ADMIN_USER"])
        reader = next(u for u in identities if u["Username"] == USER)
        self.login(admin["Username"], admin["Id"], 1)
        self.login(USER, reader["Id"], 2)
        tags = sorted(
            ({name: tag[name] for name in ("ID", "Name")} for tag in self.call("/tags")),
            key=lambda row: row["ID"],
        )
        tag = next(t for t in tags if t["Name"] == TAG)
        endpoints = self.call("/endpoints")
        local = next(e for e in endpoints if e["Name"] == ENDPOINT)
        if local["URL"] != "unix:///var/run/docker.sock" or tag["ID"] not in local["TagIds"]:
            raise ValueError("Portainer fixture endpoint configuration was lost")
        # An unchanged database is insufficient if the migrated endpoint no
        # longer reaches Docker. The existing Homepage token must work too.
        containers = self.call(f"/endpoints/{local['Id']}/docker/containers/json")
        if not any("/portainer" in c["Names"] for c in containers):
            raise ValueError("Portainer local endpoint cannot see its running container")
        result = {
            "users": identities,
            "tags": tags,
            "endpoints": sorted(
                (
                    {name: e[name] for name in ("Id", "Name", "Type", "URL", "GroupId", "TagIds")}
                    for e in endpoints
                ),
                key=lambda row: row["Id"],
            ),
            "homepage-key": fingerprint(self.key),
        }
        assert_no_secrets(result, {self.key, self.password})
        return result

    def probe(self) -> None:
        """Prove the comparison sees a real persisted change, then restore it."""
        before = self.snapshot()
        endpoint = before["endpoints"][0]
        path = f"/endpoints/{endpoint['Id']}"
        self.call(path, {"Name": ENDPOINT + "-changed"}, "PUT")
        try:
            try:
                after = self.snapshot()
            except (ValueError, StopIteration):
                return
            if not changed_keys(before, after):
                raise ValueError("Portainer comparison missed an endpoint change")
        finally:
            self.call(path, {"Name": endpoint["Name"]}, "PUT")


def main() -> None:
    client = Client()
    command = sys.argv[1]
    if command == "seed":
        client.seed()
    elif command == "probe":
        client.probe()
    elif command == "save":
        STATE.write_text(json.dumps(client.snapshot(), sort_keys=True))
    elif command == "check":
        changed = changed_keys(json.loads(STATE.read_text()), client.snapshot())
        if changed:
            raise ValueError("Portainer persistent state changed: " + ", ".join(changed))
        print("Portainer persistent state and stored logins preserved")
    else:
        raise ValueError("unknown Portainer state command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration) as exc:
        raise SystemExit(f"Portainer state check failed ({type(exc).__name__})") from None

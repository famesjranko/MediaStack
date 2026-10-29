"""Persistent Beszel records, read through PocketBase before any repair runs."""

from __future__ import annotations

import json
import pathlib
import secrets
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from upgrade_state import PORTS, StateClient, changed_keys, fingerprint

PORTS["beszel"] = 8090
FIXTURE = pathlib.Path("/tmp/beszel-fixture.json")
SNAPSHOT = pathlib.Path("/tmp/beszel-upgrade-state.json")
EMAIL = "upgrade-fixture@beszel.test"
FIELDS = {
    "users": ("id", "email", "username", "role", "verified"),
    "systems": ("id", "name", "host", "port", "users", "status"),
    "user_settings": ("id", "user", "settings"),
    "system_stats": ("id", "system", "type", "stats", "created"),
    "container_stats": ("id", "system", "type", "stats", "created"),
}


class BeszelState(StateClient):
    def login(self, collection: str = "_superusers", **credentials: str) -> dict[str, Any]:
        body = credentials or {
            "identity": self.env["NPM_ADMIN_EMAIL"],
            "password": self.env["JELLYFIN_ADMIN_PASSWORD"],
        }
        result = self.send(
            "beszel", f"/api/collections/{collection}/auth-with-password", body, "POST", {}
        )
        if not result["token"] or not result["record"]["id"]:
            raise ValueError("Beszel login returned no identity")
        return dict(result)

    def request(self, path: str, body: Any = None, method: str = "GET") -> Any:
        return self.send("beszel", "/api/" + path, body, method, {"Authorization": self.token})

    def records(self, collection: str) -> list[dict[str, Any]]:
        result = self.request(f"collections/{collection}/records?perPage=500")
        if result["totalItems"] > len(result["items"]):
            raise ValueError(f"Beszel {collection} inventory was truncated")
        return list(result["items"])

    def create(self, collection: str, body: dict[str, Any]) -> str:
        return str(self.request(f"collections/{collection}/records", body, "POST")["id"])

    def prepare_recovery(self) -> None:
        """Exercise the configurator's TCP-entry and superuser recovery paths."""
        auth = self.login()
        self.token = auth["token"]
        local = [row for row in self.records("systems") if row["name"] == "MediaStack"]
        if len(local) != 1:
            raise ValueError("Beszel local system is missing or duplicated")
        self.request(
            f"collections/systems/records/{local[0]['id']}",
            {"host": "host.docker.internal", "port": "45876"},
            "PATCH",
        )
        password = secrets.token_urlsafe(24)
        self.request(
            f"collections/_superusers/records/{auth['record']['id']}",
            {"password": password, "passwordConfirm": password},
            "PATCH",
        )

    def seed(self) -> None:
        self.token = self.login()["token"]
        password = secrets.token_urlsafe(24)
        user = self.create(
            "users",
            {
                "email": EMAIL,
                "username": "upgrade-fixture",
                "role": "user",
                "verified": True,
                "password": password,
                "passwordConfirm": password,
            },
        )
        # A paused system retains synthetic history without generating new
        # samples or contacting an external host during the test.
        system = self.create(
            "systems",
            {
                "name": "Upgrade fixture",
                "host": "127.0.0.1",
                "port": "45876",
                "status": "paused",
                "users": [user],
            },
        )
        # A newly created system starts pending regardless of the payload.
        self.request(f"collections/systems/records/{system}", {"status": "paused"}, "PATCH")
        settings = self.create(
            "user_settings",
            {"user": user},
        )
        # Beszel's create hook replaces settings with its defaults. Save the
        # deliberate preference change through the same PATCH as its UI.
        self.request(
            f"collections/user_settings/records/{settings}",
            {"settings": {"unitTemp": 3, "chartTime": "24h"}},
            "PATCH",
        )
        ids = {"users": user, "systems": system, "user_settings": settings}
        samples = {
            "system_stats": {"cpu": 12.5, "m": 8, "mu": 2, "mp": 25, "d": 100, "du": 20, "dp": 20},
            "container_stats": [{"n": "fixture-container", "cpu": 1.5, "m": 64}],
        }
        for collection, stats in samples.items():
            ids[collection] = self.create(
                collection,
                {"system": system, "type": "480m", "stats": stats},
            )
        FIXTURE.touch(mode=0o600, exist_ok=False)
        FIXTURE.write_text(json.dumps({"ids": ids, "password": password}))
        actual = self.snapshot()
        if actual["systems"]["status"] != "paused":
            raise ValueError("Beszel did not pause the fixture system")
        if actual["user_settings"]["settings"] != {"unitTemp": 3, "chartTime": "24h"}:
            raise ValueError("Beszel did not persist fixture preferences")
        for collection, stats in samples.items():
            if actual[collection]["stats"] != stats:
                raise ValueError(f"Beszel did not persist fixture {collection}")

    def snapshot(self) -> dict[str, Any]:
        fixture = json.loads(FIXTURE.read_text())
        auth = self.login()
        self.token = auth["token"]
        result: dict[str, Any] = {"superuser": auth["record"]["id"]}
        for collection, fields in FIELDS.items():
            record = self.request(f"collections/{collection}/records/{fixture['ids'][collection]}")
            result[collection] = {name: record[name] for name in fields}
        admin = self.login("users")["record"]
        result["admin"] = {name: admin[name] for name in FIELDS["users"]}
        local = [row for row in self.records("systems") if row["name"] == "MediaStack"]
        if len(local) != 1 or local[0]["host"] != "/beszel_data/socket/beszel.sock":
            raise ValueError("Beszel local system is missing or no longer uses its socket")
        # The active agent's status is transient and its TCP port is ignored
        # on a socket. Both fields remain significant for the fixture system.
        result["local-system"] = {
            name: local[0][name] for name in FIELDS["systems"] if name not in ("status", "port")
        }
        key = self.request("beszel/getkey")["key"]
        if not key or key != self.env["BESZEL_AGENT_KEY"]:
            raise ValueError("Beszel agent key no longer matches the installed agent")
        result["agent-key"] = fingerprint(key)
        # Re-authenticate the extra user and read its actual saved preferences
        # through the user's permissions, not only the superuser API.
        user = self.login("users", identity=EMAIL, password=fixture["password"])
        if user["record"]["id"] != fixture["ids"]["users"]:
            raise ValueError("Beszel fixture login returned a different user")
        self.token = user["token"]
        settings = self.records("user_settings")
        if len(settings) != 1 or settings[0]["id"] != fixture["ids"]["user_settings"]:
            raise ValueError("Beszel user cannot read its saved preferences")
        return result


def main() -> None:
    state = BeszelState()
    command = sys.argv[1]
    if command == "prepare-recovery":
        state.prepare_recovery()
    elif command == "seed":
        state.seed()
    elif command == "save":
        SNAPSHOT.write_text(json.dumps(state.snapshot(), sort_keys=True))
    elif command == "check":
        changed = changed_keys(json.loads(SNAPSHOT.read_text()), state.snapshot())
        if changed:
            raise ValueError("Beszel persistent state changed: " + ", ".join(changed))
        print("Beszel users, systems, preferences, history and agent key preserved")
    else:
        raise ValueError("unknown Beszel state command")


if __name__ == "__main__":
    main()

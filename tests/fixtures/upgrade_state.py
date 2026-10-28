"""Seed and compare persistent user state through the real service APIs in DinD.

The snapshot may land in test artifacts, so it never holds a secret value. A
credential is recorded as a short SHA-256 fingerprint or as a boolean, and
every stored credential must authenticate against the running service.
"""

from __future__ import annotations

import hashlib
import http.cookiejar
import json
import pathlib
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

FIXTURE_USER = "upgrade-fixture-user"
FIXTURE_KEY_APP = "upgrade-fixture-key"
FIXTURE_SEERR_EMAIL = "upgrade-fixture@mediastack.test"
JACKETT_CONFIG = pathlib.Path("config/jackett/Jackett/ServerConfig.json")
PORTS = {"sonarr": 8989, "radarr": 7878, "jellyfin": 8096, "seerr": 5055, "jackett": 9117}


def read_env() -> dict[str, str]:
    values = {}
    for line in pathlib.Path(".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key] = value
    return values


def fingerprint(value: str) -> str | None:
    """Identify a credential without storing it; None marks an absent one."""
    return hashlib.sha256(value.encode()).hexdigest()[:16] if value else None


def redact(value: Any, known: set[str]) -> Any:
    """Replace every string equal to a known secret with its fingerprint."""
    if isinstance(value, dict):
        return {k: redact(v, known) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, known) for v in value]
    if isinstance(value, str) and value in known:
        return f"sha256:{fingerprint(value)}"
    return value


def assert_no_secrets(snapshot: dict[str, Any], known: set[str]) -> None:
    """Refuse a snapshot that still embeds a secret, for example inside a URL."""
    text = json.dumps(snapshot, sort_keys=True)
    if any(value in text for value in known):
        raise ValueError("snapshot would contain a secret value")


class StateClient:
    def __init__(self) -> None:
        self.env = read_env()
        self.http = self.session()
        # Values that must never reach the snapshot file. Short values such as
        # "false" are configuration, not credentials, and would match by chance.
        self.secrets = {
            value
            for name, value in self.env.items()
            if (name.endswith("_API_KEY") or "PASSWORD" in name) and len(value) >= 8
        }

    @staticmethod
    def session() -> urllib.request.OpenerDirector:
        return urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def call(self, app: str, path: str, body: Any = None, method: str = "GET") -> Any:
        headers = {"Content-Type": "application/json"}
        key = self.env[f"{app.upper()}_API_KEY"]
        if app == "jellyfin":
            headers["Authorization"] = f'MediaBrowser Token="{key}"'
        else:
            headers["X-Api-Key"] = key
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORTS[app]}{path}",
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

    def jellyfin_keys(self) -> list[dict[str, Any]]:
        items = self.call("jellyfin", "/Auth/Keys")["Items"]
        for item in items:
            self.secrets.add(item["AccessToken"])
        return list(items)

    def seerr_users(self) -> list[dict[str, Any]]:
        return list(self.call("seerr", "/api/v1/user?take=1000&skip=0")["results"])

    def ensure_fixtures(self) -> None:
        """Create the user-owned records that an upgrade must keep (idempotent)."""
        if not any(u["Name"] == FIXTURE_USER for u in self.call("jellyfin", "/Users")):
            self.call("jellyfin", "/Users/New", {"Name": FIXTURE_USER}, "POST")
        if not any(k["AppName"] == FIXTURE_KEY_APP for k in self.jellyfin_keys()):
            self.call("jellyfin", f"/Auth/Keys?app={FIXTURE_KEY_APP}", method="POST")
        if not any(u["email"] == FIXTURE_SEERR_EMAIL for u in self.seerr_users()):
            # Seerr requires a password for a local user. Nothing reads it later.
            user = {
                "email": FIXTURE_SEERR_EMAIL,
                "username": "upgrade-fixture",
                "password": secrets.token_urlsafe(18),
            }
            self.call("seerr", "/api/v1/user", user, "POST")

    def drop_fixtures(self) -> None:
        """Simulate an upgrade that loses a Seerr user and a Jellyfin API key."""
        for key in self.jellyfin_keys():
            if key["AppName"] == FIXTURE_KEY_APP:
                self.call("jellyfin", f"/Auth/Keys/{key['AccessToken']}", method="DELETE")
        for user in self.seerr_users():
            if user["email"] == FIXTURE_SEERR_EMAIL:
                self.call("seerr", f"/api/v1/user/{user['id']}", method="DELETE")

    def seed(self) -> None:
        self.ensure_fixtures()
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
            body = response.read().strip()
            if body != b"Ok." and not (response.status == 204 and not body):
                raise ValueError("qBittorrent login failed")
        with self.http.open(f"http://127.0.0.1:8080/api/v2/{endpoint}", timeout=20) as response:
            return json.load(response)

    def jackett_key(self) -> str:
        """The key MediaStack reads from Jackett's own file (api_get_jackett_key)."""
        key = str(json.loads(JACKETT_CONFIG.read_text()).get("APIKey") or "")
        if key:
            self.secrets.add(key)
        return key

    def jackett_admin(self) -> dict[str, Any]:
        """Log in to the Jackett admin UI as configure.sh does; read the server config."""
        base = f"http://127.0.0.1:{PORTS['jackett']}"
        key = self.jackett_key()
        # A fresh cookie jar: an older session must not hide a failed login.
        jar = self.session()
        login = urllib.parse.urlencode({"password": self.env["JELLYFIN_ADMIN_PASSWORD"]})
        jar.open(f"{base}/UI/Dashboard", login.encode(), timeout=20).close()
        url = f"{base}/api/v2.0/server/config?apikey={urllib.parse.quote(key)}"
        with jar.open(url, timeout=20) as response:
            # Jackett redirects to its login page instead of answering 401.
            if "/UI/Login" in response.geturl():
                raise ValueError("Jackett admin login failed")
            config: dict[str, Any] = json.load(response)
        self.secrets.add(str(config.get("api_key") or ""))
        return config

    def jackett_torznab(self) -> None:
        query = urllib.parse.urlencode({"t": "caps", "apikey": self.jackett_key()})
        url = f"http://127.0.0.1:{PORTS['jackett']}/api/v2.0/indexers/all/results/torznab/api"
        with self.http.open(f"{url}?{query}", timeout=30) as response:
            if b"<caps" not in response.read():
                raise ValueError("Jackett Torznab caps missing")

    def authenticate(self) -> None:
        """Every stored credential must still work on the running image."""
        probes: dict[str, Callable[[], Any]] = {
            "sonarr": lambda: self.call("sonarr", "/api/v3/system/status"),
            "radarr": lambda: self.call("radarr", "/api/v3/system/status"),
            "jellyfin": lambda: self.call("jellyfin", "/System/Info"),
            "seerr": lambda: self.call("seerr", "/api/v1/auth/me"),
            "jackett": self.jackett_torznab,
            "qbittorrent": lambda: self.qbt("torrents/categories"),
        }
        failed = []
        for service, probe in probes.items():
            try:
                probe()
            except (OSError, ValueError, KeyError) as exc:
                # HTTPError is an OSError; its str() carries no credential.
                failed.append(f"{service} ({exc})")
        if failed:
            raise SystemExit("stored credentials do not authenticate: " + ", ".join(failed))

    def arr_state(self, result: dict[str, Any]) -> None:
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

    def jellyfin_state(self, result: dict[str, Any]) -> None:
        users = self.call("jellyfin", "/Users")
        if not any(u["Name"] == FIXTURE_USER for u in users):
            raise ValueError("Jellyfin lost the fixture user")
        result["jellyfin/users"] = sorted((u["Id"], u["Name"]) for u in users)
        result["jellyfin/libraries"] = [
            {k: row[k] for k in ("Name", "Locations", "ItemId", "CollectionType")}
            for row in self.call("jellyfin", "/Library/VirtualFolders")
        ]
        keys = self.jellyfin_keys()
        result["jellyfin/api-keys"] = sorted(
            (k["AppName"], fingerprint(k["AccessToken"])) for k in keys
        )
        # Other services hold this key; a key that is gone breaks them all.
        stored = self.env.get("JELLYFIN_API_KEY", "")
        if not any(k["AppName"] == "MediaStack" and k["AccessToken"] == stored for k in keys):
            raise ValueError("Jellyfin no longer lists MediaStack's stored API key")
        result["jellyfin/mediastack-key-present"] = True

    def seerr_state(self, result: dict[str, Any]) -> None:
        result["seerr/users"] = sorted(
            (u["id"], u["email"], u["permissions"]) for u in self.seerr_users()
        )
        api_key = str(self.call("seerr", "/api/v1/settings/main").get("apiKey") or "")
        self.secrets.add(api_key)
        result["seerr/api-key"] = {"set": bool(api_key), "sha256": fingerprint(api_key)}
        for app in ("sonarr", "radarr"):
            result[f"seerr/{app}"] = self.call("seerr", f"/api/v1/settings/{app}")

    def jackett_state(self, result: dict[str, Any]) -> None:
        config = self.jackett_admin()
        api_key = str(config.get("api_key") or "")
        result["jackett/admin"] = {
            # Jackett returns a prefix of the password hash, or "" when unset.
            "admin_password_set": bool(config.get("password")),
            "api_key_set": bool(api_key),
            "api_key_sha256": fingerprint(api_key),
            "api_key_matches_stored": api_key == self.jackett_key(),
        }

    def qbittorrent_state(self, result: dict[str, Any]) -> None:
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

    def snapshot(self) -> dict[str, Any]:
        self.authenticate()
        result: dict[str, Any] = {}
        self.arr_state(result)
        self.jellyfin_state(result)
        self.seerr_state(result)
        self.jackett_state(result)
        self.qbittorrent_state(result)
        # A rotated key that was also rewritten into .env still authenticates,
        # but every client that holds the old key breaks.
        result["credentials"] = {
            name: fingerprint(value)
            for name, value in sorted(self.env.items())
            if name.endswith("_API_KEY")
        }
        self.secrets.discard("")
        result = redact(json.loads(json.dumps(result)), self.secrets)
        assert_no_secrets(result, self.secrets)
        return result


def main() -> None:
    client = StateClient()
    command = sys.argv[1]
    actions = {
        "seed": client.seed,
        "flip": client.flip_profile,
        "drop": client.drop_fixtures,
        "restore": client.ensure_fixtures,
    }
    if command in actions:
        actions[command]()
        return
    path = pathlib.Path("/tmp/upgrade-state.json")
    if command == "save":
        path.write_text(json.dumps(client.snapshot(), sort_keys=True))
    elif command == "check":
        snapshot = client.snapshot()
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

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
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from typing import Any, Callable

FIXTURE_USER = "upgrade-fixture-user"
FIXTURE_KEY_APP = "upgrade-fixture-key"
FIXTURE_SEERR_EMAIL = "upgrade-fixture@mediastack.test"
JACKETT_CONFIG = pathlib.Path("config/jackett/Jackett/ServerConfig.json")
PORTS = {"sonarr": 8989, "radarr": 7878, "jellyfin": 8096, "seerr": 5055, "jackett": 9117}
JELLYFIN_CLIENT = (
    'MediaBrowser Client="MediaStack", Device="upgrade-state", '
    'DeviceId="mediastack-upgrade-state", Version="1"'
)
# A recreated Jackett can report healthy shortly before it serves Torznab.
JACKETT_ATTEMPTS = 6
# Every preference that scripts/services/qbittorrent/main.sh writes, except the
# write-only web_ui_password.
QBT_PREFERENCES = (
    "save_path",
    "temp_path",
    "temp_path_enabled",
    "listen_port",
    "max_ratio",
    "max_ratio_enabled",
    "max_ratio_act",
    "max_seeding_time",
    "max_seeding_time_enabled",
    "dl_limit",
    "up_limit",
    "max_connec",
    "max_connec_per_torrent",
    "max_uploads",
    "max_uploads_per_torrent",
    "queueing_enabled",
    "max_active_downloads",
    "max_active_uploads",
    "max_active_torrents",
    "upnp",
    "preallocate_all",
    "bypass_auth_subnet_whitelist",
    "bypass_auth_subnet_whitelist_enabled",
    "web_ui_username",
)
# The Jellyfin connection as scripts/lib/arr/connections.sh writes it. The
# apiKey field is left out: Sonarr and Radarr mask it on every read.
ARR_JELLYFIN_FLAGS = (
    "onGrab",
    "onDownload",
    "onUpgrade",
    "onImportComplete",
    "onRename",
    "onHealthIssue",
    "onHealthRestored",
    "onApplicationUpdate",
)
ARR_JELLYFIN_FIELDS = ("host", "port", "useSsl", "notify", "updateLibrary")


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
    """Replace every string or dict key equal to a known secret with its fingerprint."""
    if isinstance(value, dict):
        return {redact(k, known): redact(v, known) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, known) for v in value]
    if isinstance(value, str) and value in known:
        return f"sha256:{fingerprint(value)}"
    return value


def strings(value: Any) -> Iterator[str]:
    """Every string leaf and every dict key, unescaped."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


def assert_no_secrets(snapshot: dict[str, Any], known: set[str]) -> None:
    """Refuse a snapshot that still embeds a secret, for example inside a URL.

    The search runs on the raw strings: json.dumps escapes a quote or a
    backslash, so a password that holds one would not match the serialised text.
    """
    if any(secret in text for text in strings(snapshot) for secret in known):
        raise ValueError("snapshot would contain a secret value")


def changed_keys(previous: dict[str, Any], current: dict[str, Any]) -> list[str]:
    """Keys whose value differs, including keys present on one side only."""
    missing = object()
    return sorted(
        k
        for k in previous.keys() | current.keys()
        if previous.get(k, missing) != current.get(k, missing)
    )


def assert_populated(result: dict[str, Any]) -> None:
    """A comparison is vacuous if the baseline already lacks configured state."""
    required = {
        "seerr/api-key": result["seerr/api-key"]["set"],
        "jackett/admin": result["jackett/admin"]["admin_password_set"],
        "jellyfin/libraries": bool(result["jellyfin/libraries"]),
        "sonarr/notification": bool(result["sonarr/notification"]),
        "radarr/notification": bool(result["radarr/notification"]),
    }
    missing = [name for name, present in required.items() if not present]
    if missing:
        raise ValueError("configured state is missing: " + ", ".join(missing))


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
        key = self.env[f"{app.upper()}_API_KEY"]
        if app == "jellyfin":
            headers = {"Authorization": f'MediaBrowser Token="{key}"'}
        else:
            headers = {"X-Api-Key": key}
        return self.send(app, path, body, method, headers)

    def send(self, app: str, path: str, body: Any, method: str, headers: dict[str, str]) -> Any:
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORTS[app]}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json", **headers},
            method=method,
        )
        with self.http.open(req, timeout=20) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def jellyfin_admin(self) -> None:
        """Log in as the wizard admin, as the post-Revert login check does."""
        login = {
            "Username": self.env.get("JELLYFIN_ADMIN_USER", "admin"),
            "Pw": self.env["JELLYFIN_ADMIN_PASSWORD"],
        }
        session = self.send(
            "jellyfin",
            "/Users/AuthenticateByName",
            login,
            "POST",
            {"Authorization": JELLYFIN_CLIENT},
        )
        self.secrets.add(str(session.get("AccessToken") or ""))
        if session.get("User", {}).get("Policy", {}).get("IsAdministrator") is not True:
            raise ValueError("Jellyfin admin login is not an administrator")

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

    def jackett_admin(self) -> tuple[dict[str, Any], list[Any]]:
        """Log in to the Jackett admin UI as configure.sh does.

        Returns the server config and the configured indexers.
        """
        base = f"http://127.0.0.1:{PORTS['jackett']}"
        key = urllib.parse.quote(self.jackett_key())
        # A fresh cookie jar: an older session must not hide a failed login.
        jar = self.session()
        login = urllib.parse.urlencode({"password": self.env["JELLYFIN_ADMIN_PASSWORD"]})
        jar.open(f"{base}/UI/Dashboard", login.encode(), timeout=20).close()

        def read(path: str) -> Any:
            with jar.open(f"{base}/api/v2.0/{path}apikey={key}", timeout=20) as response:
                # Jackett redirects to its login page instead of answering 401.
                if "/UI/Login" in response.geturl():
                    raise ValueError("Jackett admin login failed")
                return json.load(response)

        config: dict[str, Any] = read("server/config?")
        self.secrets.add(str(config.get("api_key") or ""))
        indexers: list[Any] = read("indexers?configured=true&")
        return config, indexers

    def jackett_torznab(self) -> None:
        query = urllib.parse.urlencode({"t": "caps", "apikey": self.jackett_key()})
        url = f"http://127.0.0.1:{PORTS['jackett']}/api/v2.0/indexers/all/results/torznab/api"
        error = ""
        for attempt in range(1, JACKETT_ATTEMPTS + 1):
            try:
                with self.http.open(f"{url}?{query}", timeout=30) as response:
                    if b"<caps" in response.read():
                        return
                error = "Jackett Torznab caps missing"
            except OSError as exc:
                error = str(exc)
            if attempt < JACKETT_ATTEMPTS:
                time.sleep(5)
        raise ValueError(error)

    def authenticate(self) -> None:
        """Every stored credential must still work on the running image."""
        probes: dict[str, Callable[[], Any]] = {
            "sonarr": lambda: self.call("sonarr", "/api/v3/system/status"),
            "radarr": lambda: self.call("radarr", "/api/v3/system/status"),
            "jellyfin": lambda: self.call("jellyfin", "/System/Info"),
            "jellyfin admin": self.jellyfin_admin,
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
            result[f"{app}/notification"] = [
                self.arr_jellyfin_connection(row)
                for row in self.call(app, "/api/v3/notification")
                if row.get("implementation") == "MediaBrowser"
            ]

    @staticmethod
    def arr_jellyfin_connection(row: dict[str, Any]) -> dict[str, Any]:
        fields = {f.get("name"): f.get("value") for f in row.get("fields", [])}
        return {
            "id": row.get("id"),
            "implementation": row.get("implementation"),
            **{name: row[name] for name in ARR_JELLYFIN_FLAGS if name in row},
            **{name: fields.get(name) for name in ARR_JELLYFIN_FIELDS},
        }

    def jellyfin_state(self, result: dict[str, Any]) -> None:
        users = self.call("jellyfin", "/Users")
        if not any(u["Name"] == FIXTURE_USER for u in users):
            raise ValueError("Jellyfin lost the fixture user")
        result["jellyfin/users"] = sorted(
            (u["Id"], u["Name"], u["Policy"]["IsAdministrator"], u["Policy"]["IsDisabled"])
            for u in users
        )
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
        main = self.call("seerr", "/api/v1/settings/main")
        api_key = str(main.get("apiKey") or "")
        self.secrets.add(api_key)
        result["seerr/api-key"] = {"set": bool(api_key), "sha256": fingerprint(api_key)}
        # configure.sh re-applies these, so only a check before it can see a loss.
        result["seerr/defaults"] = {
            "defaultPermissions": main.get("defaultPermissions"),
            "defaultQuotas": main.get("defaultQuotas"),
        }
        for app in ("sonarr", "radarr"):
            result[f"seerr/{app}"] = self.call("seerr", f"/api/v1/settings/{app}")

    def jackett_state(self, result: dict[str, Any]) -> None:
        config, indexers = self.jackett_admin()
        api_key = str(config.get("api_key") or "")
        result["jackett/indexers"] = sorted(i["id"] for i in indexers if i.get("configured"))
        result["jackett/flaresolverr"] = config.get("flaresolverrurl")
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
        recorded = {name: preferences[name] for name in QBT_PREFERENCES}
        # The configurator reads the list as a set split on "," or newline;
        # an image may store the same set in the other form.
        whitelist = str(recorded["bypass_auth_subnet_whitelist"])
        recorded["bypass_auth_subnet_whitelist"] = sorted(
            {x.strip() for x in re.split(r"[\n,]", whitelist) if x.strip()}
        )
        result["qbittorrent/preferences"] = recorded

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
        assert_populated(result)
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
        changed = changed_keys(json.loads(path.read_text()), client.snapshot())
        if changed:
            raise SystemExit("persistent state changed: " + ", ".join(changed))
        print("persistent user state preserved")
    else:
        raise SystemExit("unknown upgrade-state command")


if __name__ == "__main__":
    main()

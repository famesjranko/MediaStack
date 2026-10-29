"""Seed stopped Bazarr and compare persisted subtitle state through its API.

The fixture inserts local media/history records without contacting a subtitle
provider or a metadata service. Database reads use a fixed field projection so
new migration columns do not count as lost user data.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import sqlite3
import sys
import urllib.error
import urllib.request
from typing import Any

import yaml

DB = pathlib.Path("config/bazarr/db/bazarr.db")
SNAPSHOT = pathlib.Path("/tmp/bazarr-upgrade-state.json")
FIXTURE_ID = 700001
PROFILE_ID = 4242
PROFILE_ITEM = {
    "id": 1,
    "language": "en",
    "forced": "False",
    "hi": "True",
    "audio_exclude": "False",
}
SUBTITLE = "1\n00:00:00,000 --> 00:00:01,000\nMediaStack upgrade fixture.\n"
VIDEO = "/data/media/movies/upgrade-fixture/fixture.avi"
EPISODE = "/data/media/tv/upgrade-fixture/episode.avi"
PROJECTIONS = {
    "table_languages_profiles": (
        "profileId",
        "name",
        "items",
        "cutoff",
        "mustContain",
        "mustNotContain",
    ),
    "table_history": (
        "id",
        "action",
        "description",
        "sonarrSeriesId",
        "sonarrEpisodeId",
        "language",
        "provider",
        "score",
        "subs_id",
        "subtitles_path",
        "video_path",
        "timestamp",
    ),
    "table_history_movie": (
        "id",
        "action",
        "description",
        "radarrId",
        "language",
        "provider",
        "score",
        "subs_id",
        "subtitles_path",
        "video_path",
        "timestamp",
    ),
}


def connect() -> sqlite3.Connection:
    # mode=rw refuses an absent database instead of silently creating one.
    conn = sqlite3.connect(f"file:{DB}?mode=rw", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def insert(conn: sqlite3.Connection, table: str, values: dict[str, Any]) -> None:
    keys = ", ".join(f'"{key}"' for key in values)
    marks = ", ".join("?" for _ in values)
    conn.execute(f'INSERT INTO "{table}" ({keys}) VALUES ({marks})', list(values.values()))


def seed() -> None:
    """Called only with Bazarr stopped; refuses a duplicate fixture population."""
    with connect() as conn:
        insert(
            conn,
            "table_languages_profiles",
            {
                "profileId": PROFILE_ID,
                "name": "User hearing-impaired subtitles",
                "items": json.dumps([PROFILE_ITEM]),
                "cutoff": 1,
                "mustContain": "['WEB']",
                "mustNotContain": "['CAM']",
            },
        )
        insert(
            conn,
            "table_shows",
            {
                "sonarrSeriesId": FIXTURE_ID,
                "title": "Upgrade fixture series",
                "path": "/data/media/tv/upgrade-fixture",
                "profileId": PROFILE_ID,
                "monitored": "False",
                "tags": "[]",
                "audio_language": "['English']",
            },
        )
        insert(
            conn,
            "table_episodes",
            {
                "sonarrSeriesId": FIXTURE_ID,
                "sonarrEpisodeId": FIXTURE_ID,
                "title": "Upgrade fixture episode",
                "path": EPISODE,
                "season": 1,
                "episode": 1,
                "monitored": "False",
            },
        )
        insert(
            conn,
            "table_movies",
            {
                "radarrId": FIXTURE_ID,
                "tmdbId": "700001",
                "title": "Upgrade fixture movie",
                "path": VIDEO,
                "profileId": PROFILE_ID,
                "monitored": "False",
                "tags": "[]",
                "audio_language": "['English']",
            },
        )
        history = {
            "id": FIXTURE_ID,
            "action": 1,
            "description": "Upgrade fixture subtitle download",
            "language": "en:hi",
            "provider": "embedded",
            "score": 100,
            "timestamp": "2026-01-01 00:00:00.000000",
        }
        for table, path, relation in (
            (
                "table_history",
                EPISODE,
                {"sonarrSeriesId": FIXTURE_ID, "sonarrEpisodeId": FIXTURE_ID},
            ),
            ("table_history_movie", VIDEO, {"radarrId": FIXTURE_ID}),
        ):
            columns = {row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')}
            # Older accepted versions predate the explicit score denominator.
            score = (
                {"score_out_of": 360 if table == "table_history" else 120}
                if "score_out_of" in columns
                else {}
            )
            insert(
                conn,
                table,
                {
                    **history,
                    **relation,
                    **score,
                    "subs_id": table + "-fixture",
                    "video_path": path,
                    "subtitles_path": path.replace(".avi", ".en.srt"),
                },
            )
    for name in ("movies/upgrade-fixture/fixture.en.srt", "tv/upgrade-fixture/episode.en.srt"):
        subtitle_path = pathlib.Path("/tmp/ms-data/media") / name
        subtitle_path.parent.mkdir(parents=True, exist_ok=True)
        subtitle_path.write_text(SUBTITLE)


def api_key() -> str:
    config = yaml.safe_load(pathlib.Path("config/bazarr/config/config.yaml").read_text())
    key = config["auth"]["apikey"]
    if not isinstance(key, str) or not key:
        raise ValueError("Bazarr API key is missing")
    return key


def get(path: str, key: str) -> Any:
    request = urllib.request.Request(
        "http://127.0.0.1:6767/api/" + path, headers={"X-API-KEY": key}
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise ValueError(f"Bazarr {path} returned HTTP {exc.code}") from None


def database_state() -> dict[str, Any]:
    result: dict[str, Any] = {}
    with connect() as conn:
        for table, columns in PROJECTIONS.items():
            actual_columns = {row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')}
            if not set(columns) <= actual_columns:
                raise ValueError(f"missing Bazarr schema fields: {table}")
            fields = ", ".join(f'"{column}"' for column in columns)
            rows = [dict(row) for row in conn.execute(f'SELECT {fields} FROM "{table}" ORDER BY 1')]
            if not rows:
                raise ValueError(f"empty Bazarr population: {table}")
            for row in rows:
                if "items" in row:
                    # Startup migrations can add default fields. The user's
                    # language choices must retain the fields this version seeds.
                    row["items"] = [
                        {key: item[key] for key in PROFILE_ITEM}
                        for item in json.loads(row["items"])
                    ]
            result[table] = rows
    return result


def snapshot() -> dict[str, Any]:
    key = api_key()
    result = database_state()
    result["api-key"] = hashlib.sha256(key.encode()).hexdigest()
    settings = get("system/settings", key)
    result["settings"] = {
        section: {name: settings[section][name] for name in names}
        for section, names in {
            "general": (
                "use_sonarr",
                "use_radarr",
                "serie_default_profile",
                "movie_default_profile",
            ),
            "sonarr": ("ip", "port", "apikey"),
            "radarr": ("ip", "port", "apikey"),
        }.items()
    }
    for section in ("sonarr", "radarr"):
        value = result["settings"][section]["apikey"]
        if not value:
            raise ValueError(f"Bazarr {section} credential is missing")
        result["settings"][section]["apikey"] = hashlib.sha256(value.encode()).hexdigest()
    for kind, table in (("episodes", "table_history"), ("movies", "table_history_movie")):
        rows = get(f"{kind}/history", key)["data"]
        matches = [row for row in rows if row["subs_id"] == table + "-fixture"]
        if len(matches) != 1:
            raise ValueError(f"Bazarr {kind} history fixture is missing or duplicated")
        result[kind + "/history"] = {
            name: matches[0][name]
            for name in (
                "action",
                "description",
                "language",
                "provider",
                "subs_id",
                "subtitles_path",
            )
        }
        identity_fields = (
            ("seriesTitle", "episodeTitle", "sonarrSeriesId", "sonarrEpisodeId")
            if kind == "episodes"
            else ("title", "radarrId")
        )
        result[kind + "/history"].update({name: matches[0][name] for name in identity_fields})
    for name in ("movies/upgrade-fixture/fixture.en.srt", "tv/upgrade-fixture/episode.en.srt"):
        result[name] = hashlib.sha256(
            (pathlib.Path("/tmp/ms-data/media") / name).read_bytes()
        ).hexdigest()
    return result


def check(previous: dict[str, Any], current: dict[str, Any]) -> None:
    changed = sorted(
        key for key in previous.keys() | current.keys() if previous.get(key) != current.get(key)
    )
    if changed:
        raise ValueError("Bazarr state changed: " + ", ".join(changed))


def prove_history_loss() -> None:
    """Delete only the fixture's movie history, require rejection, then restore it."""
    previous = snapshot()
    with connect() as conn:
        row = dict(
            conn.execute("SELECT * FROM table_history_movie WHERE id=?", (FIXTURE_ID,)).fetchone()
        )
        conn.execute("DELETE FROM table_history_movie WHERE id=?", (FIXTURE_ID,))
    rejected = False
    try:
        try:
            check(previous, snapshot())
        except ValueError as exc:
            if "table_history_movie" not in str(exc) and "movies history" not in str(exc):
                raise
            rejected = True
    finally:
        with connect() as conn:
            insert(conn, "table_history_movie", row)
    if not rejected:
        raise ValueError("Bazarr comparison accepted lost movie history")
    check(previous, snapshot())


def main() -> None:
    action = sys.argv[1]
    if action == "seed":
        seed()
    elif action == "save":
        SNAPSHOT.write_text(json.dumps(snapshot(), sort_keys=True))
    elif action == "check":
        check(json.loads(SNAPSHOT.read_text()), snapshot())
    elif action == "prove-history-loss":
        prove_history_loss()
    else:
        raise ValueError("expected seed, save, check or prove-history-loss")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Responses and credentials never enter the test log.
        print(f"Bazarr state fixture failed ({type(exc).__name__})", file=sys.stderr)
        if type(exc) is ValueError:
            print(str(exc), file=sys.stderr)
        elif isinstance(exc, KeyError):
            print(f"Bazarr state fixture is missing field {exc}", file=sys.stderr)
        sys.exit(1)

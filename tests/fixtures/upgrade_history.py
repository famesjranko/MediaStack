"""Seed accepted-image SQLite records offline, then verify through real APIs.

Metadata lookup and request creation contact public providers. These small
records use the accepted schemas instead, with each writer stopped. Candidate
images only read/migrate them; they never seed or repair a fixture.
"""

from __future__ import annotations

import json
import pathlib
import sqlite3
import subprocess
import time
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from upgrade_state import StateClient

ID = 157001
TITLE = "MediaStack Upgrade History"
DATE = "2020-01-02 03:04:05"


def insert(db: sqlite3.Connection, table: str, values: dict[str, Any]) -> None:
    if db.execute(f'SELECT 1 FROM "{table}" WHERE Id = ?', (ID,)).fetchone():
        return
    columns = ", ".join(f'"{name}"' for name in values)
    placeholders = ", ".join("?" for _ in values)
    db.execute(f'INSERT INTO "{table}" ({columns}) VALUES ({placeholders})', list(values.values()))


def seed_arr(app: str) -> None:
    with sqlite3.connect(f"file:config/{app}/{app}.db?mode=rw", uri=True) as db:
        db.execute("PRAGMA foreign_keys = ON")
        profile = db.execute(
            "SELECT Id FROM QualityProfiles WHERE Name = '1080p Balanced'"
        ).fetchone()[0]
        if app == "sonarr":
            insert(
                db,
                "Series",
                {
                    "Id": ID,
                    "TvdbId": 999999991,
                    "TvRageId": 0,
                    "TvMazeId": 0,
                    "Title": TITLE,
                    "TitleSlug": "mediastack-upgrade-history",
                    "CleanTitle": TITLE,
                    "SortTitle": TITLE,
                    "Status": 1,
                    "Images": "[]",
                    "Path": f"/data/media/tv/{TITLE}",
                    "Monitored": 0,
                    "SeasonFolder": 1,
                    "Runtime": 30,
                    "SeriesType": 0,
                    "UseSceneNumbering": 0,
                    "OriginalLanguage": 1,
                    "Year": 2000,
                    "Seasons": '[{"seasonNumber":1,"monitored":false}]',
                    "Tags": "[]",
                    "Genres": "[]",
                    "Actors": "[]",
                    "Ratings": "{}",
                    "QualityProfileId": profile,
                    "Added": DATE,
                    "LastInfoSync": DATE,
                },
            )
            insert(
                db,
                "Episodes",
                {
                    "Id": ID,
                    "SeriesId": ID,
                    "SeasonNumber": 1,
                    "EpisodeNumber": 1,
                    "Title": "Migration episode",
                    "EpisodeFileId": 0,
                    "Monitored": 0,
                    "UnverifiedSceneNumbering": 0,
                    "Runtime": 30,
                    "AirDate": "2000-01-01",
                    "AirDateUtc": "2000-01-01 00:00:00",
                    "Ratings": "{}",
                    "Images": "[]",
                },
            )
            relation = {"SeriesId": ID, "EpisodeId": ID}
        else:
            insert(
                db,
                "MovieMetadata",
                {
                    "Id": ID,
                    "TmdbId": 999999992,
                    "Title": TITLE,
                    "SortTitle": TITLE,
                    "CleanTitle": TITLE,
                    "OriginalTitle": TITLE,
                    "Images": "[]",
                    "Genres": "[]",
                    "OriginalLanguage": 1,
                    "Status": 0,
                    "Runtime": 90,
                    "Recommendations": "[]",
                    "Ratings": "{}",
                    "Year": 2000,
                    "LastInfoSync": DATE,
                },
            )
            insert(
                db,
                "Movies",
                {
                    "Id": ID,
                    "MovieMetadataId": ID,
                    "Path": f"/data/media/movies/{TITLE}",
                    "Monitored": 0,
                    "QualityProfileId": profile,
                    "MovieFileId": 0,
                    "MinimumAvailability": 0,
                    "Tags": "[]",
                    "Added": DATE,
                },
            )
            relation = {"MovieId": ID}
        insert(
            db,
            "History",
            {
                "Id": ID,
                **relation,
                "SourceTitle": TITLE,
                "Date": DATE,
                "EventType": 1,
                "DownloadId": "mediastack-history-download",
                "Quality": json.dumps(
                    {"quality": 3, "revision": {"version": 1, "real": 0, "isRepack": False}}
                ),
                "Languages": "[1]",
                "Data": json.dumps({"downloadClient": "qBittorrent", "indexer": "mstest"}),
            },
        )


def seed_seerr() -> None:
    path = pathlib.Path("config/seerr/db/db.sqlite3")
    with sqlite3.connect(f"file:{path}?mode=rw", uri=True) as db:
        db.execute("PRAGMA foreign_keys = ON")
        # The separate local-user loss probe deletes its fixture user. Request
        # history belongs to the stable administrator, so that probe cannot
        # cascade-delete this record before the migration starts.
        user = db.execute("SELECT id FROM user WHERE id = 1").fetchone()[0]
        insert(
            db,
            "media",
            {
                "id": ID,
                "mediaType": "movie",
                "tmdbId": 999999993,
                "status": 1,
                "createdAt": DATE,
                "updatedAt": DATE,
            },
        )
        insert(
            db,
            "media_request",
            {
                "id": ID,
                "mediaId": ID,
                "type": "movie",
                "status": 3,
                "requestedById": user,
                "createdAt": DATE,
                "updatedAt": DATE,
            },
        )


def seed(client: StateClient) -> None:
    services = ["sonarr", "radarr", "seerr"]
    subprocess.run(["docker", "compose", "stop", *services], check=True)
    try:
        seed_arr("sonarr")
        seed_arr("radarr")
        seed_seerr()
    finally:
        subprocess.run(["docker", "compose", "start", *services], check=True)
    for app in services:
        path = "/api/v1/auth/me" if app == "seerr" else "/api/v3/system/status"
        for _ in range(90):
            try:
                client.call(app, path)
                break
            except OSError:
                time.sleep(1)
        else:
            raise ValueError(f"fixture not ready: {app}")


def selected(row: dict[str, Any], names: tuple[str, ...]) -> dict[str, Any]:
    return {key: row[key] for key in names}


def snapshot(client: StateClient) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for app, resource, identity in (("sonarr", "series", "tvdbId"), ("radarr", "movie", "tmdbId")):
        rows = client.call(app, f"/api/v3/{resource}")
        row = next((row for row in rows if row["id"] == ID), None)
        if not row:
            raise ValueError(f"{app} lost the fixture {resource}")
        result[f"{app}/media"] = selected(
            row, ("id", identity, "title", "path", "monitored", "qualityProfileId")
        )
        history = client.call(
            app, "/api/v3/history?pageSize=1000&sortKey=date&sortDirection=ascending"
        )
        entries = [row for row in history["records"] if row["id"] == ID]
        if len(entries) != 1:
            raise ValueError(f"{app} lost the fixture history")
        relation = ("seriesId", "episodeId") if app == "sonarr" else ("movieId",)
        result[f"{app}/history"] = [
            selected(
                entries[0],
                (
                    "id",
                    "sourceTitle",
                    "date",
                    "eventType",
                    "quality",
                    "languages",
                    "downloadId",
                    "data",
                    *relation,
                ),
            )
        ]
    episodes = client.call("sonarr", f"/api/v3/episode?seriesId={ID}")
    episode = next((row for row in episodes if row["id"] == ID), None)
    if not episode:
        raise ValueError("Sonarr lost the fixture episode")
    result["sonarr/episode"] = selected(
        episode, ("id", "seriesId", "seasonNumber", "episodeNumber", "title", "monitored")
    )
    requests = client.call("seerr", "/api/v1/request?take=1000&skip=0")["results"]
    request = next((row for row in requests if row["id"] == ID), None)
    if not request:
        raise ValueError("Seerr lost the fixture request")
    result["seerr/requests"] = {
        **selected(request, ("id", "type", "status", "createdAt", "updatedAt", "is4k")),
        "requestedBy": selected(request["requestedBy"], ("id", "email")),
        "media": selected(request["media"], ("id", "tmdbId", "mediaType", "status")),
    }
    return result

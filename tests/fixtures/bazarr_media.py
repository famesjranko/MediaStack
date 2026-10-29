"""Local Arr file records that keep Bazarr's normal startup sync meaningful.

Sonarr and Radarr must be stopped. A real uncompressed clip clears Bazarr's
minimum file-size filter without network metadata or subtitle providers.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from bazarr_state import EPISODE, FIXTURE_ID, VIDEO, insert
from upgrade_state import StateClient

DATE = "2026-01-01 00:00:00"
QUALITY = json.dumps({"quality": 3, "revision": {"version": 1, "real": 0, "isRepack": False}})


def disable_metadata_lookups() -> None:
    """The generated files must not trigger Jellyfin's internet metadata lookup."""
    client = StateClient()
    for library in client.call("jellyfin", "/Library/VirtualFolders"):
        options = library["LibraryOptions"]
        options["EnableRealtimeMonitor"] = False
        options["TypeOptions"] = [
            {"Type": kind, "MetadataFetchers": [], "ImageFetchers": []}
            for kind in ("Movie", "Series", "Season", "Episode")
        ]
        client.call(
            "jellyfin",
            "/Library/VirtualFolders/LibraryOptions",
            {"Id": library["ItemId"], "LibraryOptions": options},
            "POST",
        )


def clip() -> int:
    paths = [
        pathlib.Path("/tmp/ms-data") / path.removeprefix("/data/") for path in (VIDEO, EPISODE)
    ]
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
    with paths[0].open("wb") as output:
        subprocess.run(
            [
                "docker",
                "exec",
                "jellyfin",
                "/usr/lib/jellyfin-ffmpeg/ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=512x512:r=30",
                "-t",
                "1",
                "-c:v",
                "rawvideo",
                "-pix_fmt",
                "bgr24",
                "-threads",
                "1",
                "-f",
                "avi",
                "pipe:1",
            ],
            stdout=output,
            check=True,
            timeout=60,
        )
    shutil.copyfile(paths[0], paths[1])
    return paths[0].stat().st_size


def seed_sonarr(conn: sqlite3.Connection, profile: int, size: int) -> None:
    insert(
        conn,
        "Series",
        {
            "Id": FIXTURE_ID,
            "TvdbId": 999999961,
            "TvRageId": 0,
            "TvMazeId": 0,
            "Title": "Upgrade fixture series",
            "TitleSlug": "upgrade-fixture-series",
            "CleanTitle": "Upgrade fixture series",
            "SortTitle": "Upgrade fixture series",
            "Status": 1,
            "Images": "[]",
            "Path": str(pathlib.PurePosixPath(EPISODE).parent),
            "Monitored": 0,
            "SeasonFolder": 0,
            "Runtime": 1,
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
        conn,
        "EpisodeFiles",
        {
            "Id": FIXTURE_ID,
            "SeriesId": FIXTURE_ID,
            "Quality": QUALITY,
            "Size": size,
            "DateAdded": DATE,
            "SeasonNumber": 1,
            "RelativePath": "episode.avi",
            "Languages": "[1]",
        },
    )
    insert(
        conn,
        "Episodes",
        {
            "Id": FIXTURE_ID,
            "SeriesId": FIXTURE_ID,
            "SeasonNumber": 1,
            "EpisodeNumber": 1,
            "Title": "Upgrade fixture episode",
            "EpisodeFileId": FIXTURE_ID,
            "Monitored": 0,
            "UnverifiedSceneNumbering": 0,
            "Runtime": 1,
            "AirDate": "2000-01-01",
            "AirDateUtc": "2000-01-01 00:00:00",
            "Ratings": "{}",
            "Images": "[]",
        },
    )


def seed_radarr(conn: sqlite3.Connection, profile: int, size: int) -> None:
    insert(
        conn,
        "MovieMetadata",
        {
            "Id": FIXTURE_ID,
            "TmdbId": 999999962,
            "Title": "Upgrade fixture movie",
            "SortTitle": "Upgrade fixture movie",
            "CleanTitle": "Upgrade fixture movie",
            "OriginalTitle": "Upgrade fixture movie",
            "Images": "[]",
            "Genres": "[]",
            "OriginalLanguage": 1,
            "Status": 0,
            "Runtime": 1,
            "Recommendations": "[]",
            "Ratings": "{}",
            "Year": 2000,
            "LastInfoSync": DATE,
        },
    )
    insert(
        conn,
        "Movies",
        {
            "Id": FIXTURE_ID,
            "MovieMetadataId": FIXTURE_ID,
            "Path": str(pathlib.PurePosixPath(VIDEO).parent),
            "Monitored": 0,
            "QualityProfileId": profile,
            "MovieFileId": FIXTURE_ID,
            "MinimumAvailability": 0,
            "Tags": "[]",
            "Added": DATE,
        },
    )
    insert(
        conn,
        "MovieFiles",
        {
            "Id": FIXTURE_ID,
            "MovieId": FIXTURE_ID,
            "Quality": QUALITY,
            "Size": size,
            "DateAdded": DATE,
            "RelativePath": "fixture.avi",
            "Languages": "[1]",
            "IndexerFlags": 0,
        },
    )


def main() -> None:
    disable_metadata_lookups()
    size = clip()
    for app, seed in (("sonarr", seed_sonarr), ("radarr", seed_radarr)):
        with sqlite3.connect(f"file:config/{app}/{app}.db?mode=rw", uri=True) as conn:
            conn.execute("PRAGMA foreign_keys=ON")
            profile = conn.execute(
                "SELECT Id FROM QualityProfiles WHERE Name='1080p Balanced'"
            ).fetchone()[0]
            seed(conn, profile, size)


if __name__ == "__main__":
    main()

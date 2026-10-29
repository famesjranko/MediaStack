#!/usr/bin/env bash
# Subtitle migration oracle: real SQLite and files, fixed independent API responses.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin bazarr-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import contextlib
import copy
import importlib.util
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bazarr_state", pathlib.Path(sys.argv.pop()) / "tests/fixtures/bazarr_state.py")
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)

# These are the accepted schema's public record fields, not a schema generated
# by the implementation. The live scenario also seeds the real image schema.
DDL = '''
CREATE TABLE table_languages_profiles (
 profileId INTEGER PRIMARY KEY, name TEXT NOT NULL, items TEXT NOT NULL,
 cutoff INTEGER, mustContain TEXT, mustNotContain TEXT);
CREATE TABLE table_shows (
 sonarrSeriesId INTEGER PRIMARY KEY, title TEXT NOT NULL, path TEXT NOT NULL,
 profileId INTEGER REFERENCES table_languages_profiles(profileId),
 monitored TEXT, tags TEXT, audio_language TEXT);
CREATE TABLE table_episodes (
 sonarrEpisodeId INTEGER PRIMARY KEY, sonarrSeriesId INTEGER REFERENCES table_shows(sonarrSeriesId),
 title TEXT NOT NULL, path TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
 monitored TEXT);
CREATE TABLE table_movies (
 radarrId INTEGER PRIMARY KEY, tmdbId TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
 path TEXT NOT NULL, profileId INTEGER REFERENCES table_languages_profiles(profileId),
 monitored TEXT, tags TEXT, audio_language TEXT);
CREATE TABLE table_history (
 id INTEGER PRIMARY KEY, action INTEGER NOT NULL, description TEXT NOT NULL,
 sonarrSeriesId INTEGER REFERENCES table_shows(sonarrSeriesId),
 sonarrEpisodeId INTEGER REFERENCES table_episodes(sonarrEpisodeId),
 language TEXT, provider TEXT, score INTEGER, subs_id TEXT, subtitles_path TEXT,
 video_path TEXT, timestamp DATETIME NOT NULL);
CREATE TABLE table_history_movie (
 id INTEGER PRIMARY KEY, action INTEGER NOT NULL, description TEXT NOT NULL,
 radarrId INTEGER REFERENCES table_movies(radarrId),
 language TEXT, provider TEXT, score INTEGER, subs_id TEXT, subtitles_path TEXT,
 video_path TEXT, timestamp DATETIME NOT NULL);
'''
SETTINGS = {
    "general": {"use_sonarr": True, "use_radarr": True,
                "serie_default_profile": 1, "movie_default_profile": 1},
    "sonarr": {"ip": "sonarr", "port": 8989, "apikey": "fixture-sonarr-secret"},
    "radarr": {"ip": "radarr", "port": 7878, "apikey": "fixture-radarr-secret"},
}


class SubtitleState(unittest.TestCase):
    def setUp(self):
        # Given an accepted schema, local files and independent API responses.
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.old_cwd = pathlib.Path.cwd()
        os.chdir(self.folder.name)
        self.addCleanup(os.chdir, self.old_cwd)
        state.DB.parent.mkdir(parents=True)
        with sqlite3.connect(state.DB) as conn:
            conn.executescript(DDL)
        config = pathlib.Path("config/bazarr/config/config.yaml")
        config.parent.mkdir()
        config.write_text("auth:\n  apikey: fixture-bazarr-secret\n")
        # Remap only the fixture media root; no test writes into the host /tmp/ms-data.
        original_path = pathlib.Path
        self.paths = patch.object(state.pathlib, "Path", side_effect=lambda p: original_path(
            "media" if str(p) == "/tmp/ms-data/media" else p))
        self.paths.start()
        self.addCleanup(self.paths.stop)
        self.responses = {"system/settings": copy.deepcopy(SETTINGS)}
        for kind, table, title in (("movies", "table_history_movie", "Upgrade fixture movie"),
                                   ("episodes", "table_history", "Upgrade fixture episode")):
            self.responses[kind + "/history"] = {"data": [{
                "action": 1, "description": "Upgrade fixture subtitle download",
                "language": {"code2": "en", "hi": True, "forced": False},
                "provider": "embedded", "subs_id": table + "-fixture",
                "subtitles_path": "/data/fixture.en.srt",
                **({"seriesTitle": "Upgrade fixture series", "episodeTitle": title,
                    "sonarrSeriesId": 700001, "sonarrEpisodeId": 700001} if kind == "episodes"
                   else {"title": title, "radarrId": 700001}),
            }]}
        self.api = patch.object(state, "get", side_effect=lambda path, key: copy.deepcopy(self.responses[path]))
        self.api.start()
        self.addCleanup(self.api.stop)
        state.seed()
        self.before = state.snapshot()

    def test_intact_state_survives_a_fresh_database_connection(self):
        # Given a seeded database and independently supplied API responses.
        # When a second snapshot opens the database again.
        actual = state.snapshot()

        # Then the persisted state compares equal and no raw key is recorded.
        state.check(self.before, actual)
        encoded = json.dumps(actual)
        for secret in ("fixture-bazarr-secret", "fixture-sonarr-secret", "fixture-radarr-secret"):
            self.assertNotIn(secret, encoded)

    def test_a_lost_history_record_is_rejected_despite_stale_api_data(self):
        # Given a database that lost movie history while its API still reports it.
        with state.connect() as conn:
            conn.execute("DELETE FROM table_history_movie")

        # When a new snapshot reads the database.
        # Then an empty history population cannot earn a snapshot.
        with self.assertRaisesRegex(ValueError, "table_history_movie"):
            state.snapshot()

    def test_history_loss_probe_restores_the_original_record(self):
        # Given a populated database whose state is recorded before the upgrade.
        # When the live negative probe deletes and restores its movie history.
        state.prove_history_loss()

        # Then the probe leaves the exact original history available for migration.
        state.check(self.before, state.snapshot())

    def test_a_reset_user_profile_is_rejected(self):
        # Given an accepted baseline and a reset cutoff in the current database.
        with state.connect() as conn:
            conn.execute("UPDATE table_languages_profiles SET cutoff=0")

        # When the candidate state is snapshotted.
        actual = state.snapshot()

        # Then the comparator rejects the changed profile.
        with self.assertRaisesRegex(ValueError, "table_languages_profiles"):
            state.check(self.before, actual)

    def test_a_changed_history_response_is_rejected(self):
        # Given an intact database and baseline history returned by the application.
        self.responses["episodes/history"]["data"][0]["description"] = "overwritten"

        # When the candidate application returns changed history.
        actual = state.snapshot()

        # Then a readable SQLite file alone cannot prove application compatibility.
        with self.assertRaisesRegex(ValueError, "episodes/history"):
            state.check(self.before, actual)

    def test_an_empty_history_response_is_rejected(self):
        # Given an intact database but an application that returns no movie history.
        self.responses["movies/history"]["data"] = []

        # When the candidate is snapshotted.
        # Then its missing fixture is refused before comparison.
        with self.assertRaisesRegex(ValueError, "movies history fixture"):
            state.snapshot()

    def test_a_missing_required_setting_is_rejected(self):
        # Given a settings response whose credential field was renamed upstream.
        del self.responses["system/settings"]["sonarr"]["apikey"]

        # When the snapshot reads required settings.
        # Then no default can hide the missing field.
        with self.assertRaises(KeyError):
            state.snapshot()

    def test_a_changed_api_key_is_rejected(self):
        # Given an accepted snapshot and a newly generated API key.
        pathlib.Path("config/bazarr/config/config.yaml").write_text("auth:\n  apikey: changed-fixture-secret\n")

        # When the candidate is snapshotted.
        actual = state.snapshot()

        # Then key rotation is detected even if authentication otherwise works.
        with self.assertRaisesRegex(ValueError, "api-key"):
            state.check(self.before, actual)

    def test_a_lost_subtitle_file_is_rejected(self):
        # Given an accepted snapshot and a deleted external subtitle file.
        pathlib.Path("media/movies/upgrade-fixture/fixture.en.srt").unlink()

        # When the candidate is snapshotted.
        # Then a surviving history row cannot hide the missing subtitle.
        with self.assertRaises(FileNotFoundError):
            state.snapshot()

    def test_a_missing_database_is_not_created(self):
        # Given a missing database after an upgrade.
        state.DB.unlink()

        # When the reader opens it.
        # Then it refuses the missing database without creating an empty replacement.
        with self.assertRaises(sqlite3.OperationalError):
            state.database_state()
        self.assertFalse(state.DB.exists())


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SubtitleState))
sys.exit(not result.wasSuccessful())
PY
    pass 'Bazarr migration rejects lost records, settings, credentials and files'
else
    fail 'Bazarr migration rejects lost records, settings, credentials and files'
fi
scenario_end "$CURRENT_SCENARIO"
summary

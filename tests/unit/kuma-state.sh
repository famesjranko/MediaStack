#!/usr/bin/env bash
# Kuma migration compares application-visible history, not a health response.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin kuma-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import json
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(sys.argv.pop()) / "tests/fixtures"))
import kuma_state as kuma


def baseline():
    # Public fields observed on the accepted 2.5.7 image; no database fixture.
    monitor = {"id": 1, "name": "Jellyfin", "type": "http", "url": "http://jellyfin:8096/health",
               "active": True, "interval": 60, "retryInterval": 60, "maxretries": 3,
               "method": "GET", "accepted_statuscodes": ["200-299", "300-399"], "maxredirects": 0}
    fixture = dict(monitor, id=3, name=kuma.NAME, type="push", active=False, interval=3600,
                   maxretries=0, pushTokenFingerprint="a" * 64)
    history = [{"id": i, "monitor_id": 3, "status": status, "msg": "migration-" + name,
                "ping": ping, "time": f"2026-10-29 09:21:{15+i}.001", "important": 1, "duration": int(i > 1)}
               for i, status, name, ping in [(1, 1, "up", 12), (2, 0, "down", 30), (3, 1, "up", 24)]]
    page = {"config": {"slug": "mediastack", "title": "MediaStack", "theme": "auto",
                       "published": True, "showPoweredBy": True},
            "publicGroupList": [{"id": 1, "name": "Services", "weight": 1,
                                 "monitorList": [{"id": 1}, {"id": 2}]}]}
    custom = copy.deepcopy(page)
    custom["config"].update(slug="migration-fixture", title=kuma.NAME, theme="dark", showPoweredBy=False)
    custom["publicGroupList"][0].update(id=2, name="Migration history", monitorList=[{"id": 3}])
    return {"monitors": [monitor, dict(monitor, id=2, name="Sonarr"), fixture], "history": history,
            "charts": {period: [{"timestamp": 1793265660, "up": 2, "down": 1,
                                  "avgPing": 18, "minPing": 12, "maxPing": 24}]
                       for period in ("minute", "hour", "day")},
            "settings": {"keepDataPeriodDays": 365, "checkUpdate": False, "serverTimezone": "UTC"},
            "pages": {"mediastack": page, "migration-fixture": custom}}


class KumaState(unittest.TestCase):
    def test_valid_state_keeps_false_and_zero(self):
        # Given realistic history and a paused custom monitor.
        raw = baseline()

        # When the migration snapshot is collected.
        state = kuma.snapshot(raw)

        # Then state contains all eight groups and preserves false and zero.
        self.assertEqual(len(state), 8)
        self.assertIs(state["kuma/monitors"][2]["active"], False)
        self.assertEqual(state["kuma/history"][1]["status"], 0)
        self.assertNotIn("password", json.dumps(state))

    def test_lost_records_or_required_fields_fail(self):
        # Given independent ways that an upgrade can lose required state.
        defects = [
            lambda x: x["monitors"].pop(),
            lambda x: x["history"].pop(1),
            lambda x: x["history"][0].pop("ping"),
            lambda x: x["history"][0].update(monitor_id=99),
            lambda x: x["history"][1].update(duration=0),
            lambda x: x["settings"].pop("checkUpdate"),
            lambda x: x["settings"].update(keepDataPeriodDays=30),
            lambda x: x["monitors"][2].update(active=True),
            lambda x: x["monitors"][2].pop("pushTokenFingerprint"),
            lambda x: x["pages"]["mediastack"]["publicGroupList"].clear(),
            lambda x: x["pages"]["migration-fixture"]["publicGroupList"][0].update(monitorList=[{"id": 99}]),
        ]
        for defect in defects:
            raw = baseline()
            defect(raw)

            # When the saved application state is read after the upgrade.
            # Then missing or invalid state cannot become a passing empty snapshot.
            with self.subTest(defect=defects.index(defect)), self.assertRaises((ValueError, KeyError)):
                kuma.snapshot(raw)

    def test_each_chart_period_requires_saved_up_and_down_samples(self):
        # Given each persisted chart period independently loses its history.
        for period in ("minute", "hour", "day"):
            raw = baseline()
            raw["charts"][period] = []

            # When migration state is read.
            # Then the remaining periods cannot conceal that loss.
            with self.subTest(period=period), self.assertRaisesRegex(ValueError, "history chart"):
                kuma.snapshot(raw)

    def test_changed_persisted_values_are_detected(self):
        # Given plausible surviving records with changed settings, IDs or history.
        defects = {
            "kuma/monitors": lambda x: x["monitors"][2].update(pushTokenFingerprint="b" * 64),
            "kuma/history": lambda x: x["history"][0].update(time="2026-10-29 10:00:00"),
            "kuma/settings": lambda x: x["settings"].update(checkUpdate=True),
            "kuma/page-mediastack": lambda x: x["pages"]["mediastack"]["publicGroupList"][0]["monitorList"].pop(),
            "kuma/page-migration-fixture": lambda x: x["pages"]["migration-fixture"]["config"].update(theme="light"),
        }
        for period in ("minute", "hour", "day"):
            defects["kuma/history-" + period] = lambda x, p=period: x["charts"][p][0].update(avgPing=99)
        expected = kuma.snapshot(baseline())
        for group, defect in defects.items():
            raw = baseline()
            defect(raw)

            # When the current state is compared with the independent baseline.
            changed = kuma.changed_keys(expected, kuma.snapshot(raw))

            # Then every state group detects a plausible migration defect.
            with self.subTest(group=group):
                self.assertIn(group, changed)

    def test_login_or_transport_failure_cannot_authorize_a_snapshot(self):
        # Given Kuma rejects authentication or the bounded request fails.
        env = {"JELLYFIN_ADMIN_USER": "admin", "JELLYFIN_ADMIN_PASSWORD": "not-a-real-password"}
        failed = subprocess.CompletedProcess([], 1, "", "private server diagnostic")

        # When the real process boundary reports failure.
        with patch.object(kuma, "read_env", return_value=env), patch.object(kuma.subprocess, "run", return_value=failed) as run:
            with self.assertRaisesRegex(ValueError, "login"):
                kuma.collect("snapshot")

        # Then failure stops collection and credentials never appear in argv.
        self.assertNotIn(env["JELLYFIN_ADMIN_PASSWORD"], str(run.call_args.args[0]))
        self.assertEqual(run.call_args.kwargs["timeout"], 75)


unittest.main(argv=["kuma-state"], verbosity=2)
PY
    pass 'Kuma state rejects lost, changed and unavailable migration data'
else
    fail 'Kuma state rejects lost, changed and unavailable migration data'
fi
summary

#!/usr/bin/env bash
# Pin authentication responses observed from the real accepted images, and
# prove that the saved snapshot holds no secret value and that a lost or
# changed record changes it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin upgrade-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import copy
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse

spec = importlib.util.spec_from_file_location("upgrade_state", pathlib.Path(sys.argv.pop()) / "tests/fixtures/upgrade_state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.time.sleep = lambda seconds: None

# install-e2e's real admin password: it holds a quote and a backslash.
PASSWORD = 'Fr3sh!$tack"with\\special#chars^&*'
ENV = {
    "JELLYFIN_ADMIN_USER": "admin",
    "JELLYFIN_ADMIN_PASSWORD": PASSWORD,
    "JELLYFIN_API_KEY": "test-key",
    "SONARR_API_KEY": "s" * 32,
    "RADARR_API_KEY": "r" * 32,
    "SEERR_API_KEY": "e" * 32,
}
module.read_env = lambda: dict(ENV)
JACKETT_KEY = "j" * 32
JACKETT_FILE = pathlib.Path(tempfile.mkdtemp()) / "ServerConfig.json"
module.JACKETT_CONFIG = JACKETT_FILE
module.upgrade_media.BACKUP = JACKETT_FILE.parent
for suffix in ("torrent", "fastresume"):
    (JACKETT_FILE.parent / f"{module.upgrade_media.TORRENT_HASH}.{suffix}").write_bytes(b"resume fixture")


def arr(app, trigger):
    jellyfin = {"id": 1, "name": "Jellyfin", "implementation": "MediaBrowser", "onGrab": False, trigger: True,
                "fields": [{"name": "host", "value": "jellyfin"}, {"name": "port", "value": 8096},
                           {"name": "apiKey", "value": "********"}, {"name": "updateLibrary", "value": True}]}
    port = module.PORTS[app]
    return {
        f"{port}/api/v3/system/status": {"version": "4"},
        f"{port}/api/v3/rootfolder": [{"id": 1, "path": f"/data/{app}", "freeSpace": 1}],
        f"{port}/api/v3/qualityprofile": [{"id": 1, "name": "1080p Balanced", "upgradeAllowed": True}],
        f"{port}/api/v3/downloadclient": [{"id": 1, "name": "qBittorrent"}],
        f"{port}/api/v3/indexer": [{"id": 1, "name": "mstest"}],
        f"{port}/api/v3/notification": [jellyfin, {"id": 2, "implementation": "Email"}],
        **{f"{port}/api/v3/{name}/testall": [{"id": 1, "isValid": True}]
           for name in ("indexer", "downloadclient", "notification")},
        f"{port}/api/v3/customformat": [{"id": 1, "name": "Repack"}],
        f"{port}/api/v3/qualitydefinition": [{"id": 1, "minSize": 10}],
        f"{port}/api/v3/config/naming": {"renameEpisodes": True},
        f"{port}/api/v3/config/mediamanagement": {"minimumFreeSpaceWhenImporting": 1024},
        f"{port}/api/v3/{'series' if app == 'sonarr' else 'movie'}": [
            {"id": 157001, "title": "MediaStack Upgrade History", "path": "/data/media/fixture",
             "tvdbId": 999999991, "tmdbId": 999999992, "monitored": False, "qualityProfileId": 1}],
        f"{port}/api/v3/history": {"records": [{"id": 157001, "sourceTitle": "MediaStack Upgrade History",
            "date": "2020-01-02T03:04:05Z", "eventType": "grabbed", "quality": {"quality": {"id": 3}},
            "languages": [{"id": 1}], "downloadId": "fixture", "data": {"indexer": "mstest"},
            "seriesId": 157001, "episodeId": 157001, "movieId": 157001}]},
    }


# What the accepted images answer, keyed by port and path. A test changes one entry.
SERVICES = {
    **arr("sonarr", "onImportComplete"),
    **arr("radarr", "onDownload"),
    "8989/api/v3/episode": [{"id": 157001, "seriesId": 157001, "seasonNumber": 1,
                              "episodeNumber": 1, "title": "Migration episode", "monitored": False}],
    "8096/System/Info": {"Version": "10"},
    "8096/Users/AuthenticateByName": {"AccessToken": "t" * 32, "User": {"Policy": {"IsAdministrator": True}}},
    "8096/Users": [{"Id": "u1", "Name": "admin", "Policy": {"IsAdministrator": True, "IsDisabled": False}},
                   {"Id": "u2", "Name": module.FIXTURE_USER, "Policy": {"IsAdministrator": False, "IsDisabled": False}}],
    "8096/Library/VirtualFolders": [{"Name": "Movies", "Locations": ["/data/movies"], "ItemId": "l1",
                                      "CollectionType": "movies", "LibraryOptions": {"EnableRealtimeMonitor": True}}],
    "8096/System/Configuration": {"ServerName": "MediaStack"},
    "8096/System/Configuration/encoding": {"EnableHardwareEncoding": False},
    "8096/System/Configuration/network": {"EnableIPv6": False},
    "8096/Items": {"Items": [{"Id": "m1", "Path": module.upgrade_media.MOVIE_PATH}]},
    "8096/Users/u2/Items/m1": {"UserData": {"Played": True, "PlayCount": 1,
                                           "PlaybackPositionTicks": 0, "LastPlayedDate": "2020-01-02T03:04:05Z"}},
    "8096/Auth/Keys": {"Items": [{"AppName": "MediaStack", "AccessToken": "test-key"},
                                 {"AppName": module.FIXTURE_KEY_APP, "AccessToken": "k" * 32}]},
    "5055/api/v1/auth/me": {"id": 1},
    "5055/api/v1/user": {"results": [{"id": 1, "email": "admin@mediastack.test", "permissions": 2},
                                     {"id": 2, "email": module.FIXTURE_SEERR_EMAIL, "permissions": 32}]},
    "5055/api/v1/settings/main": {"apiKey": "m" * 32, "defaultPermissions": 32,
                                  "defaultQuotas": {"movie": {"quotaLimit": 0}, "tv": {"quotaLimit": 0}}},
    "5055/api/v1/settings/sonarr": [{"id": 0, "apiKey": "s" * 32}],
    "5055/api/v1/settings/radarr": [{"id": 0, "apiKey": "r" * 32}],
    "5055/api/v1/settings/jellyfin": {"hostname": "jellyfin", "apiKey": "test-key"},
    "5055/api/v1/settings/network": {"trustProxy": True},
    "5055/api/v1/request": {"results": [{"id": 157001, "type": "movie", "status": 3, "is4k": False,
                                        "createdAt": "2020-01-02T03:04:05Z", "updatedAt": "2020-01-02T03:04:05Z",
                                        "requestedBy": {"id": 2, "email": module.FIXTURE_SEERR_EMAIL},
                                        "media": {"id": 157001, "tmdbId": 999999993, "mediaType": "movie", "status": 1}}]},
    "9117/UI/Dashboard": b"",
    "9117/api/v2.0/server/config": {"api_key": JACKETT_KEY, "password": "a1b2", "flaresolverrurl": "http://flaresolverr:8191"},
    "9117/api/v2.0/indexers": [{"id": "mstest", "configured": True}],
    "9117/api/v2.0/indexers/all/results/torznab/api": b"<caps></caps>",
    "8080/api/v2/torrents/categories": {"tv": {"savePath": "/data/torrents/tv"}},
    "8080/api/v2/app/preferences": {**{name: 1 for name in module.QBT_PREFERENCES},
                                    "bypass_auth_subnet_whitelist": "172.28.0.22/32\n172.28.0.23/32"},
    "8080/api/v2/torrents/info": [{"hash": module.upgrade_media.TORRENT_HASH,
                                   "name": "mediastack-upgrade-resume", "size": 32768,
                                   "save_path": "/data/torrents/migration", "progress": 0.5,
                                   "amount_left": 16384, "tags": "upgrade-fixture", "dl_limit": 123456,
                                   "up_limit": 234567, "state": "stoppedDL"}],
    "8080/api/v2/torrents/files": [{"name": "present.bin", "size": 16384, "progress": 1, "priority": 1},
                                  {"name": "missing.bin", "size": 16384, "progress": 0, "priority": 1}],
}


class Response(io.BytesIO):
    def __init__(self, status, body, url=""):
        super().__init__(body)
        self.status, self.url = status, url

    def geturl(self):
        return self.url


class Late:
    """A route that gives its answers in order, for a service that starts late."""

    def __init__(self, answers):
        self.answers = answers


class Opener:
    """Answers as the accepted images do. An int route is an HTTP error status;
    a (url, body) route is a redirect."""

    def __init__(self, status=200, body=b"Ok.", routes=None):
        self.status, self.body, self.request = status, body, None
        self.routes = routes or {}

    def open(self, request, *args, **kwargs):
        self.request = request
        url = request if isinstance(request, str) else request.full_url
        if url.endswith("/auth/login"):
            return Response(self.status, self.body)
        parts = urllib.parse.urlsplit(url)
        answer = self.routes.get(f"{parts.port}{parts.path}", {"fixture": True})
        if isinstance(answer, Late):
            answer = answer.answers.pop(0)
        if isinstance(answer, int):
            raise urllib.error.HTTPError(url, answer, "Unauthorized", {}, None)
        if isinstance(answer, tuple):
            url, answer = answer
        return Response(200, answer if isinstance(answer, bytes) else json.dumps(answer).encode(), url)


def client(**changes):
    JACKETT_FILE.write_text(json.dumps({"APIKey": changes.pop("jackett_file_key", JACKETT_KEY)}))
    routes = copy.deepcopy(SERVICES)
    routes.update(changes)
    state = module.StateClient()
    state.http = Opener(routes=routes)
    state.session = lambda: state.http
    return state


class AuthContract(unittest.TestCase):
    def test_no_content_login_is_supported(self):
        # Given the accepted qBittorrent image returns its documented 204 login.
        state = module.StateClient()
        state.http = Opener(204, b"")

        # When the migration probe reads authenticated preferences.
        actual = state.qbt("app/preferences")

        # Then it accepts the successful login and reads the response.
        self.assertEqual(actual, {"fixture": True})

    def test_false_success_body_is_rejected(self):
        # Given qBittorrent rejects credentials with HTTP 200 and Fails.
        state = module.StateClient()
        state.http = Opener(200, b"Fails.")

        # When the migration probe attempts an authenticated read.
        # Then an HTTP success code cannot hide authentication failure.
        with self.assertRaisesRegex(ValueError, "login failed"):
            state.qbt("app/preferences")

    def test_jellyfin_uses_product_authorization(self):
        # Given a configured Jellyfin integration key.
        state = module.StateClient()
        state.http = Opener()

        # When the probe reads administrative user state.
        state.call("jellyfin", "/Users")

        # Then it sends the authorization form that the accepted image supports.
        self.assertEqual(state.http.request.get_header("Authorization"), 'MediaBrowser Token="test-key"')

    def test_one_rejected_credential_names_only_its_service(self):
        probes = {
            "sonarr": "8989/api/v3/system/status",
            "radarr": "7878/api/v3/system/status",
            "jellyfin": "8096/System/Info",
            "jellyfin admin": "8096/Users/AuthenticateByName",
            "seerr": "5055/api/v1/auth/me",
            "jackett": "9117/api/v2.0/indexers/all/results/torznab/api",
            "qbittorrent": "8080/api/v2/torrents/categories",
        }
        for service, route in probes.items():
            with self.subTest(service=service):
                # Given every service accepts its stored credential except one, which answers 401.
                state = client(**{route: 401})

                # When the probes authenticate before a snapshot.
                with self.assertRaises(SystemExit) as raised:
                    state.authenticate()

                # Then the failure names that service and no other.
                failed = str(raised.exception).split(": ", 1)[1]
                self.assertEqual([entry.split(" (")[0] for entry in failed.split(", ")], [service])

    def test_jellyfin_login_without_admin_rights_fails(self):
        # Given the shared admin password logs in to a Jellyfin user that is not an administrator.
        state = client(**mutated("8096/Users/AuthenticateByName", lambda a: a["User"]["Policy"].update(IsAdministrator=False)))

        # When the probes authenticate before a snapshot.
        # Then the Jellyfin admin login is named as failed.
        with self.assertRaisesRegex(SystemExit, r"jellyfin admin \(Jellyfin admin login is not an administrator\)"):
            state.authenticate()

    def test_jackett_login_redirect_is_a_failed_login(self):
        # Given Jackett answers the config read with its login page, as it does for a wrong password.
        state = client(**{"9117/api/v2.0/server/config": ("http://127.0.0.1:9117/UI/Login?ReturnUrl=x", b"<html>")})

        # When the snapshot reads Jackett's admin state.
        # Then the redirect counts as a failed admin login.
        with self.assertRaisesRegex(ValueError, "Jackett admin login failed"):
            state.jackett_state({})

    def test_jackett_caps_wait_for_late_readiness(self):
        # Given Jackett answers 503 twice before it serves its Torznab caps.
        late = Late([503, 503, b"<caps></caps>"])
        state = client(**{"9117/api/v2.0/indexers/all/results/torznab/api": late})

        # When the Jackett probe runs.
        state.jackett_torznab()

        # Then it retried until the caps arrived.
        self.assertEqual(late.answers, [])


class SecretFreeSnapshot(unittest.TestCase):
    def test_stored_key_is_replaced_by_its_fingerprint(self):
        # Given Seerr's Arr settings echo the Sonarr API key, as the real API does.
        key = "a" * 32
        state = {"seerr/sonarr": [{"apiKey": key, "port": 8989}]}

        # When the snapshot is redacted for the artifact file.
        actual = module.redact(state, {key})

        # Then only a fingerprint of the key remains.
        self.assertEqual(actual["seerr/sonarr"][0], {"apiKey": "sha256:" + module.fingerprint(key), "port": 8989})
        # And the secret guard accepts the redacted snapshot.
        module.assert_no_secrets(actual, {key})

    def test_embedded_key_is_refused(self):
        # Given a snapshot value that carries a key inside a URL.
        key = "a" * 32
        state = {"jackett/indexer": f"http://jackett:9117/api?apikey={key}"}

        # When the snapshot is checked before it is written.
        # Then the guard refuses it.
        with self.assertRaisesRegex(ValueError, "secret value"):
            module.assert_no_secrets(module.redact(state, {key}), {key})

    def test_password_with_json_escapes_inside_a_url_is_refused(self):
        # Given a URL that embeds the install-e2e password, which JSON escapes.
        state = {"seerr/sonarr": [{"url": f"http://admin:{PASSWORD}@sonarr:8989"}]}

        # When the snapshot is checked before it is written.
        # Then the guard still finds the password.
        with self.assertRaisesRegex(ValueError, "secret value"):
            module.assert_no_secrets(state, {PASSWORD})

    def test_secret_dict_key_is_redacted(self):
        # Given a record keyed by an API key.
        key = "a" * 32
        state = {"jellyfin/sessions": {key: "MediaStack"}}

        # When the snapshot is redacted.
        actual = module.redact(state, {key})

        # Then the key is replaced by its fingerprint.
        self.assertEqual(actual, {"jellyfin/sessions": {"sha256:" + module.fingerprint(key): "MediaStack"}})
        # And the guard refuses the same key left unredacted.
        with self.assertRaisesRegex(ValueError, "secret value"):
            module.assert_no_secrets(state, {key})

    def test_fingerprint_is_sixty_four_bits_of_sha256(self):
        # Given a credential value.
        value = "a" * 32

        # When it is fingerprinted.
        actual = module.fingerprint(value)

        # Then the fingerprint is the first 16 hex digits of its SHA-256.
        self.assertEqual(actual, "3ba3f5f43b926026")
        # And an absent credential has no fingerprint.
        self.assertIsNone(module.fingerprint(""))

    def test_admin_password_is_a_secret(self):
        # Given an .env with the shared admin password.
        # When the state client starts.
        state = module.StateClient()

        # Then the password is one of the values the snapshot must never hold.
        self.assertIn(PASSWORD, state.secrets)

    def test_snapshot_holds_fingerprints_and_no_secret(self):
        # Given every service answers with its stored credentials.
        state = client()

        # When the snapshot is taken.
        actual = state.snapshot()

        # Then each .env API key is recorded as its fingerprint.
        expected = {name: module.fingerprint(value) for name, value in ENV.items() if name.endswith("_API_KEY")}
        self.assertEqual(actual["credentials"], expected)
        # And the Jellyfin connection is recorded without its masked apiKey.
        self.assertNotIn("apiKey", actual["sonarr/notification"][0])
        # And no API key or token reaches the snapshot text.
        self.assertFalse([s for s in state.secrets if s != PASSWORD and s in json.dumps(actual)])


def mutated(route, change):
    answer = copy.deepcopy(SERVICES[route])
    change(answer)
    return {route: answer}


class ComparisonContract(unittest.TestCase):
    def test_each_recorded_value_is_compared(self):
        users = "5055/api/v1/user"
        cases = {
            "seerr/users": mutated(users, lambda a: a["results"][1].update(id=3, email="other@mediastack.test")),
            "jellyfin/api-keys": mutated("8096/Auth/Keys", lambda a: a["Items"][1].update(AccessToken="n" * 32)),
            "jellyfin/users": mutated("8096/Users", lambda a: a[1]["Policy"].update(IsDisabled=True)),
            "seerr/defaults": mutated("5055/api/v1/settings/main", lambda a: a["defaultQuotas"]["tv"].update(quotaLimit=5)),
            "sonarr/notification": mutated("8989/api/v3/notification", lambda a: a[0]["fields"][0].update(value="jf")),
            "jackett/indexers": {"9117/api/v2.0/indexers": []},
            "jackett/flaresolverr": mutated("9117/api/v2.0/server/config", lambda a: a.update(flaresolverrurl="")),
            "jackett/admin": {"jackett_file_key": "x" * 32},
            "qbittorrent/preferences": mutated("8080/api/v2/app/preferences", lambda a: a.update(upnp=0)),
            "jellyfin/system": mutated("8096/System/Configuration", lambda a: a.update(ServerName="reset")),
            "jellyfin/encoding": mutated("8096/System/Configuration/encoding", lambda a: a.update(EnableHardwareEncoding=True)),
            "jellyfin/network": mutated("8096/System/Configuration/network", lambda a: a.update(EnableIPv6=True)),
            "jellyfin/libraries": mutated("8096/Library/VirtualFolders", lambda a: a[0]["LibraryOptions"].update(EnableRealtimeMonitor=False)),
            "seerr/jellyfin": mutated("5055/api/v1/settings/jellyfin", lambda a: a.update(hostname="wrong-server")),
            "seerr/network": mutated("5055/api/v1/settings/network", lambda a: a.update(trustProxy=False)),
            "seerr/requests": mutated("5055/api/v1/request", lambda a: a["results"][0].update(status=1)),
            "jellyfin/watch-state": mutated("8096/Users/u2/Items/m1", lambda a: a["UserData"].update(PlayCount=2)),
            "qbittorrent/torrent": mutated("8080/api/v2/torrents/info", lambda a: a[0].update(dl_limit=0)),
            "qbittorrent/files": mutated("8080/api/v2/torrents/files", lambda a: a[0].update(priority=0)),
            "sonarr/episode": mutated("8989/api/v3/episode", lambda a: a[0].update(title="reset")),
        }
        for app, port in (("sonarr", 8989), ("radarr", 7878)):
            for name, change in (
                ("naming", lambda a: a.update(renameEpisodes=False)),
                ("mediamanagement", lambda a: a.update(minimumFreeSpaceWhenImporting=0)),
            ):
                cases[f"{app}/{name}"] = mutated(f"{port}/api/v3/config/{name}", change)
            cases[f"{app}/customformat"] = mutated(f"{port}/api/v3/customformat", lambda a: a[0].update(name="reset"))
            cases[f"{app}/qualitydefinition"] = mutated(f"{port}/api/v3/qualitydefinition", lambda a: a[0].update(minSize=0))
            cases[f"{app}/history"] = mutated(f"{port}/api/v3/history", lambda a: a["records"][0].update(eventType="downloadFailed"))
            resource = "series" if app == "sonarr" else "movie"
            cases[f"{app}/media"] = mutated(f"{port}/api/v3/{resource}", lambda a: a[0].update(path="/reset"))
        before = client().snapshot()
        for key, change in cases.items():
            with self.subTest(key=key):
                # Given a saved snapshot and one recorded value changed by an upgrade.
                state = client(**change)

                # When the state is compared again.
                actual = module.changed_keys(before, state.snapshot())

                # Then the comparison names that value.
                self.assertEqual(actual, [key])

    def test_empty_history_and_reset_resume_state_are_refused(self):
        cases = {
            "sonarr.*history": {"8989/api/v3/history": {"records": []}},
            "radarr.*history": {"7878/api/v3/history": {"records": []}},
            "Seerr.*request": {"5055/api/v1/request": {"results": []}},
            "Sonarr.*episode": {"8989/api/v3/episode": []},
            "watch state": mutated("8096/Users/u2/Items/m1", lambda a: a["UserData"].update(Played=False)),
            "paused fixture": {"8080/api/v2/torrents/info": []},
            "verified piece": mutated("8080/api/v2/torrents/info", lambda a: a[0].update(progress=0)),
            "paused fixture or": mutated("8080/api/v2/torrents/info", lambda a: a[0].update(state="downloading")),
        }
        for message, change in cases.items():
            with self.subTest(message=message):
                # Given an upgrade lost a history record or reset a torrent to an empty shell.
                state = client(**change)

                # When a migration snapshot is requested.
                # Then the missing population fails before it can become an accepted baseline.
                with self.assertRaisesRegex(ValueError, message):
                    state.snapshot()

    def test_masked_credentials_must_work_from_the_storing_service(self):
        for port in (8989, 7878):
            for resource in ("notification", "indexer", "downloadclient"):
                with self.subTest(port=port, resource=resource):
                    # Given a stored integration still looks correct but its masked secret is rejected.
                    state = client(**{f"{port}/api/v3/{resource}/testall": [{"id": 1, "isValid": False}]})

                    # When the snapshot tests that integration through its owning Arr service.
                    # Then a failed authenticated operation blocks the migration result.
                    with self.assertRaisesRegex(ValueError, "stored credentials failed"):
                        state.snapshot()

    def test_missing_resume_file_is_refused(self):
        # Given the paused torrent still appears in the API but its on-disk resume data was lost.
        state = client()
        path = module.upgrade_media.BACKUP / f"{module.upgrade_media.TORRENT_HASH}.fastresume"
        original = path.read_bytes()
        path.unlink()

        # When the migration snapshot checks the persisted torrent.
        # Then the API entry alone cannot conceal missing resume data.
        try:
            with self.assertRaisesRegex(ValueError, "resume files"):
                state.snapshot()
        finally:
            path.write_bytes(original)

    def test_same_whitelist_in_another_form_is_unchanged(self):
        # Given a saved snapshot, and an image that stores the same whitelist comma-separated.
        before = client().snapshot()
        state = client(**mutated("8080/api/v2/app/preferences",
                                 lambda a: a.update(bypass_auth_subnet_whitelist="172.28.0.23/32, 172.28.0.22/32")))

        # When the state is compared again.
        actual = module.changed_keys(before, state.snapshot())

        # Then the comparison reports no change.
        self.assertEqual(actual, [])

    def test_key_missing_after_upgrade_is_a_change(self):
        # Given a saved snapshot and a later one that lacks one of its keys.
        before = {"seerr/users": [], "jackett/admin": {"api_key_set": True}}
        after = {"seerr/users": []}

        # When the two are compared.
        actual = module.changed_keys(before, after)

        # Then the missing key is reported.
        self.assertEqual(actual, ["jackett/admin"])

    def test_baseline_without_configured_state_is_refused(self):
        cases = {
            "seerr/api-key": mutated("5055/api/v1/settings/main", lambda a: a.update(apiKey="")),
            "jackett/admin": mutated("9117/api/v2.0/server/config", lambda a: a.update(password="")),
            "jellyfin/libraries": {"8096/Library/VirtualFolders": []},
            "radarr/notification": mutated("7878/api/v3/notification", lambda a: a.pop(0)),
            "seerr/network": {"5055/api/v1/settings/network": {}},
        }
        for key, change in cases.items():
            with self.subTest(key=key):
                # Given an install that lacks one value MediaStack configures.
                state = client(**change)

                # When a snapshot is taken.
                # Then it is refused and names the missing value.
                with self.assertRaisesRegex(ValueError, f"configured state is missing: {key}$"):
                    state.snapshot()


unittest.main()
PY
    pass 'upgrade-state authentication, comparison and secret handling follow their contracts'
else
    fail 'upgrade-state authentication, comparison and secret handling follow their contracts'
fi
summary

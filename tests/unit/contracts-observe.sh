#!/usr/bin/env bash
# tests/unit/contracts-observe.sh
#
# Proves the contract trace path end to end without images: real /usr/bin/curl
# runs through tests/lib/contract-trace-curl.sh against a stdlib http.server
# fixture that answers as Sonarr, in each call style the product uses (-o with
# -w, -K - config on stdin, --data-binary @-, a chunked response, a 100
# Continue POST, and -L through a 302). A second fixture pair proves that a
# reused connection and a redirect back to the first server are attributed by
# the Host header. tests/contracts/observe.py then reduces the traces, and the
# assertions read its contracts.json. No stored traces and no network beyond
# 127.0.0.1. When Docker works, the suite runs again in a bookworm-slim
# container with curl 7.88, the DinD image's curl; otherwise that step skips.
# tests/unit/contracts-observe-rules.sh covers the reducer rules in process.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-observe"
scenario_begin "$CURRENT_SCENARIO"

if [[ ! -x /usr/bin/curl ]]; then
    fail "the contract trace shim needs /usr/bin/curl" "/usr/bin/curl is missing"
    summary
    exit 1
fi

SUITE=$(
    cat <<'PY'
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(sys.argv[1])
SECRET = "fixture-secret-key"
CANDIDATE = "lscr.io/linuxserver/sonarr@sha256:" + "c" * 64
ACCEPTED = "lscr.io/linuxserver/sonarr@sha256:" + "a" * 64
PROFILES = [{"id": 1, "name": "HD-fixture", "cutoff": 7, "upgradeAllowed": True,
             "items": [{"quality": {"id": 3}, "allowed": True}], "formatItems": [{"score": 10}]}]
NAMING = {"renameEpisodes": True, "replaceIllegalCharacters": True, "multiEpisodeStyle": 5}
LONG_SEGMENT = "abcdefghijklmnopqrstuvwx-0123456789"
GETS = {
    "/api/v3/qualityprofile": PROFILES,
    "/api/v3/rootfolder": [{"id": 1, "path": "/data/tv-fixture"}],
    "/api/v3/indexer": [],
    "/api/v3/qualityprofile/1": {"id": 1, "name": "HD-fixture", "formatItems": []},
    "/api/v3/config/naming": NAMING,
}


NOTIFICATION = {"id": 7, "name": "n", "implementation": "Emby", "fields": [{"name": "h", "value": "x"}]}


class Sonarr(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    bodies: dict[str, bytes] = {}
    # Absolute redirect targets by path, set once the fixture servers have ports.
    redirects: dict[str, str] = {}

    def _send(self, status, payload, chunked=False):
        data = json.dumps(payload).encode()
        self.send_response(status)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (data[:7], data[7:]):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
            return
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == f"/api/v3/legacy/{LONG_SEGMENT}":
            self._redirect("/api/v3/config/naming")
        elif self.path in Sonarr.redirects:
            self._redirect(Sonarr.redirects[self.path])
        elif self.path == "/api/v3/downloadclient":
            self.close_connection = True  # an empty reply: no status line at all
        elif self.path == "/api/v3/notification/7":
            self._send(404, NOTIFICATION)
        elif self.path == "/api/v3/customformat":
            self._send(200, [{"id": 5, "name": "x265-fixture"}], chunked=True)
        elif self.path.split("?", 1)[0] in GETS:
            self._send(200, GETS[self.path.split("?", 1)[0]])
        else:
            self._send(404, {"message": "NotFound"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Sonarr.bodies[self.path] = body
        self._send(201, {"id": 9, **json.loads(body)})

    def log_message(self, *_args):
        pass


class Fixture:
    """One recorded session: fixture servers by service, the shim on PATH, and the traces."""

    def __init__(self, folder, names=("sonarr",)):
        self.folder = folder
        self.traces = folder / "traces"
        self.traces.mkdir()
        shim_bin = folder / "bin"
        shim_bin.mkdir()
        (shim_bin / "curl").symlink_to(ROOT / "tests/lib/contract-trace-curl.sh")
        self.env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
        self.env.update(PATH=f"{shim_bin}:{os.environ['PATH']}", NO_PROXY="127.0.0.1",
                        MS_CONTRACT_TRACE=str(self.traces))
        self.servers = {name: http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sonarr)
                        for name in names}
        for server in self.servers.values():
            threading.Thread(target=server.serve_forever, daemon=True).start()
        self.url = self.url_of("sonarr")

    def url_of(self, name):
        return f"http://127.0.0.1:{self.servers[name].server_port}"

    def close(self):
        for server in self.servers.values():
            server.shutdown()
            server.server_close()

    def curl(self, *args, stdin="", env=None):
        return subprocess.run(["curl", *args], input=stdin, capture_output=True, text=True,
                              env=env or self.env, timeout=30)

    def events(self, *starts):
        """Start events from (time, image) for Sonarr, or (time, image, service)."""
        lines = [json.dumps({"Type": "container", "Action": "start", "timeNano": t,
                             "Actor": {"ID": f"id{t}", "Attributes": {
                                 "com.docker.compose.service": (rest or ["sonarr"])[0],
                                 "image": image}}})
                 for t, image, *rest in starts]
        path = self.folder / f"events-{len(lines)}-{starts[-1][0]}.jsonl"
        path.write_text("\n".join(lines) + "\n")
        return path

    def reduce(self, events, mapped=("sonarr",)):
        out = subprocess.run(
            [sys.executable, "-I", str(ROOT / "tests/contracts/observe.py"),
             "--traces", str(self.traces), "--events", str(events),
             "--ports", json.dumps({name: self.servers[name].server_port for name in mapped}),
             "--candidates", f"sonarr={CANDIDATE}", "--scenario", "fresh-install",
             "--run-id", "run-fixture"],
            capture_output=True, text=True, timeout=60, check=True)
        return out.stdout


class ObserveContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.fx = Fixture(pathlib.Path(cls.tmp.name))
        url = cls.fx.url
        cls.started = time.time_ns()
        out = cls.fx.folder / "profiles.json"
        cls.write_out = cls.fx.curl("-sS", "-o", str(out), "-w", "%{http_code}",
                                    f"{url}/api/v3/qualityprofile")
        cls.out_file = out.read_text()
        cls.fx.curl("-sS", "-K", "-", stdin=f'url = "{url}/api/v3/rootfolder"\n'
                    f'header = "X-Api-Key: {SECRET}"\n')
        cls.fx.curl("-sS", "-X", "POST", "-H", "Content-Type: application/json",
                    "--data-binary", "@-", f"{url}/api/v3/rootfolder",
                    stdin=json.dumps({"path": "/data/tv-fixture"}))
        cls.fx.curl("-sS", f"{url}/api/v3/customformat")
        cls.fx.curl("-sS", "-H", "Expect: 100-continue", "-H", "Content-Type: application/json",
                    "--data-binary", json.dumps({"name": "Jackett-fixture", "pad": "x" * 2048}),
                    f"{url}/api/v3/indexer")
        cls.fx.curl("-sS", f"{url}/api/v3/indexer?apikey={SECRET}")
        cls.fx.curl("-sS", f"{url}/api/v3/qualityprofile/1")
        cls.fx.curl("-sSL", f"{url}/api/v3/legacy/{LONG_SEGMENT}")
        cls.failed_call = cls.fx.curl("-sf", f"{url}/api/v3/missing")
        cls.fx.curl("-sS", f"{url}/api/v3/downloadclient")
        cls.fx.curl("-sS", f"{url}/api/v3/notification/7")
        cls.finished = time.time_ns()
        cls.report = json.loads(cls.fx.reduce(cls.fx.events((cls.started - 1, CANDIDATE))))
        cls.sonarr = cls.report["entries"]["sonarr"]

    @classmethod
    def tearDownClass(cls):
        cls.fx.close()
        cls.tmp.cleanup()

    def test_output_file_style_keeps_curl_output_and_records_reads(self):
        # Given a GET made with -o and -w '%{http_code}' through the shim.
        call = self.write_out

        # When observe.py reduces the trace.
        entry = self.sonarr["quality-profile-list"]

        # Then curl still printed the status and wrote the body.
        self.assertEqual(call.stdout, "200")
        self.assertEqual(json.loads(self.out_file), PROFILES)
        # And the entry shows one candidate 200 and every declared read.
        self.assertEqual(entry["candidate"], {"200": 1})
        self.assertEqual(entry["reads"], sorted(["id", "name", "cutoff", "upgradeAllowed",
                         "items[].quality.id", "items[].allowed", "formatItems[].score"]))

    def test_config_on_stdin_style_is_matched(self):
        # Given a GET whose URL and API key reach curl only through -K - on stdin.
        # When observe.py reduces the trace.
        entry = self.sonarr["root-folder-list"]

        # Then the request is matched to its entry with its reads.
        self.assertEqual(entry["candidate"], {"200": 1})
        self.assertEqual(entry["reads"], ["id", "path"])

    def test_body_on_stdin_style_is_matched(self):
        # Given a POST whose body reaches curl through --data-binary @-.
        # When observe.py reduces the trace.
        entry = self.sonarr["root-folder-create"]

        # Then the server received the body from stdin.
        self.assertEqual(json.loads(Sonarr.bodies["/api/v3/rootfolder"]), {"path": "/data/tv-fixture"})
        # And the entry shows the 201 and its reads.
        self.assertEqual(entry["candidate"], {"201": 1})
        self.assertEqual(entry["reads"], ["id", "path"])

    def test_chunked_response_is_dechunked_for_reads(self):
        # Given a GET whose JSON response arrives in two chunks.
        # When observe.py reduces the trace.
        entry = self.sonarr["custom-format-list"]

        # Then the reads are found in the joined body.
        self.assertEqual(entry["reads"], ["id", "name"])

    def test_continue_post_counts_the_final_status(self):
        # Given a POST that sends Expect: 100-continue and gets 100 before 201.
        # When observe.py reduces the trace.
        entry = self.sonarr["indexer-create"]

        # Then only the final 201 is counted, and its reads are seen.
        self.assertEqual(entry["candidate"], {"201": 1})
        self.assertEqual(entry["reads"], ["id", "name"])

    def test_empty_list_shows_no_reads(self):
        # Given a GET whose response is an empty JSON list.
        # When observe.py reduces the trace.
        entry = self.sonarr["indexer-list"]

        # Then the call is counted but no declared read is seen.
        self.assertEqual(entry["candidate"], {"200": 1})
        self.assertEqual(entry["reads"], [])

    def test_path_through_an_empty_nested_array_is_not_a_read(self):
        # Given a quality profile whose formatItems array is empty.
        # When observe.py reduces the trace.
        entry = self.sonarr["quality-profile-get"]

        # Then its other reads are seen but formatItems[].score is not.
        self.assertEqual(entry["candidate"], {"200": 1})
        self.assertEqual(entry["reads"], ["id", "name"])

    def test_redirect_counts_each_hop_and_redacts_the_unlisted_one(self):
        # Given a -L GET to an unlisted route that redirects with 302 to a listed one.
        # When observe.py reduces the trace.
        unmatched = self.report["unmatched"]

        # Then the target hop is matched with its reads.
        self.assertEqual(self.sonarr["config-naming-get"]["candidate"], {"200": 1})
        self.assertEqual(self.sonarr["config-naming-get"]["reads"],
                         ["multiEpisodeStyle", "renameEpisodes", "replaceIllegalCharacters"])
        # And the first hop is reported as unlisted with its long segment redacted.
        self.assertEqual(unmatched["sonarr GET /api/v3/legacy/{redacted}"],
                         {"candidate": 1, "other": 0})

    def test_shim_keeps_the_exit_code(self):
        # Given a -f GET that the fixture answers with 404.
        # When the call runs through the shim.
        call = self.failed_call

        # Then curl's own exit code 22 reaches the caller.
        self.assertEqual(call.returncode, 22)

    def test_report_holds_no_values_headers_or_bodies(self):
        # Given traffic that carries an API key header and distinctive body values.
        # When observe.py reduces the traces.
        text = json.dumps(self.report)

        # Then the report names entries and reads but none of those values.
        for value in (SECRET, "X-Api-Key", "HD-fixture", "/data/tv-fixture", "x265-fixture",
                      "Jackett-fixture", LONG_SEGMENT):
            self.assertNotIn(value, text)

    def test_request_before_the_candidate_started_binds_to_other(self):
        # Given the accepted image started first and the candidate only after the traffic.
        events = self.fx.events((self.started - 1, ACCEPTED), (self.finished + 1, CANDIDATE))

        # When observe.py reduces the same traces against those events.
        report = json.loads(self.fx.reduce(events))

        # Then every call counts for the other image and none for the candidate.
        entry = report["entries"]["sonarr"]["quality-profile-list"]
        self.assertEqual(entry, {"candidate": {}, "other": {"200": 1}, "reads": []})

    def test_query_string_is_not_part_of_the_route(self):
        # Given a GET whose URL carries an apikey query string.
        # When observe.py reduces the trace.
        unmatched = [call for call in self.report["unmatched"] if "/indexer" in call]

        # Then the call is matched to its entry, not reported as unlisted.
        self.assertEqual(self.sonarr["indexer-list"]["candidate"], {"200": 1})
        self.assertEqual(unmatched, [])

    def test_request_without_response_counts_as_000(self):
        # Given a GET that the fixture answers by closing the connection.
        # When observe.py reduces the trace.
        entry = self.sonarr["download-client-list"]

        # Then the call counts as status 000, not as a success.
        self.assertEqual(entry["candidate"], {"000": 1})

    def test_reads_come_only_from_accepted_statuses(self):
        # Given a GET answered 404 with a body that holds every declared read.
        # When observe.py reduces the trace.
        entry = self.sonarr["notification-get"]

        # Then the 404 is counted and no read is taken from its body.
        self.assertEqual(entry, {"candidate": {"404": 1}, "other": {}, "reads": []})

    def test_report_counts_requests_and_names_the_candidates(self):
        # Given eleven curls, one of which follows a redirect.
        # When observe.py reduces the traces.
        report = self.report

        # Then all twelve requests are counted and each was parsed.
        self.assertEqual((report["requests"], report["unparsed"]), (12, 0))
        # And the report names the candidate ref it bound requests to.
        self.assertEqual(report["candidates"], {"sonarr": CANDIDATE})

    def test_unset_trace_directory_records_nothing(self):
        # Given the shim on PATH without MS_CONTRACT_TRACE.
        env = {k: v for k, v in self.fx.env.items() if k != "MS_CONTRACT_TRACE"}
        before = sorted(self.fx.traces.iterdir())

        # When a curl runs through it.
        call = self.fx.curl("-sS", "-o", os.devnull, "-w", "%{http_code}",
                            f"{self.fx.url}/api/v3/indexer", env=env)

        # Then the call works and no trace file is written.
        self.assertEqual(call.stdout, "200")
        self.assertEqual(sorted(self.fx.traces.iterdir()), before)
        # And curl got no trace option: one it cannot open would dump the trace to stderr.
        self.assertEqual(call.stderr, "")


class HostAttribution(unittest.TestCase):
    """Sonarr and Radarr fixtures, plus a stray server that no service owns."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.fx = Fixture(pathlib.Path(cls.tmp.name), ("sonarr", "radarr", "stray"))
        sonarr, radarr = cls.fx.url_of("sonarr"), cls.fx.url_of("radarr")
        Sonarr.redirects.update({"/api/v3/hopa": f"{radarr}/api/v3/hopb",
                                 "/api/v3/hopb": f"{sonarr}/api/v3/config/naming"})
        started = time.time_ns()
        cls.fx.curl("-sSL", f"{sonarr}/api/v3/hopa")
        cls.fx.curl("-sS", f"{sonarr}/api/v3/qualityprofile", f"{radarr}/api/v3/rootfolder",
                    f"{sonarr}/api/v3/customformat")
        cls.fx.curl("-sS", f"{cls.fx.url_of('stray')}/api/v3/indexer")
        events = cls.fx.events((started - 1, CANDIDATE), (started - 1, ACCEPTED, "radarr"))
        cls.report = json.loads(cls.fx.reduce(events, mapped=("sonarr", "radarr")))

    @classmethod
    def tearDownClass(cls):
        cls.fx.close()
        cls.tmp.cleanup()

    def test_redirect_back_to_the_first_server_is_attributed_to_it(self):
        # Given a -L GET from Sonarr to Radarr and back to Sonarr on the reused connection.
        # When observe.py reduces the trace.
        entries, unmatched = self.report["entries"], self.report["unmatched"]

        # Then the last hop counts for Sonarr and not for Radarr.
        self.assertEqual(entries["sonarr"]["config-naming-get"]["candidate"], {"200": 1})
        self.assertNotIn("config-naming-get", entries["radarr"])
        # And each unlisted hop is reported for its own service.
        self.assertEqual(unmatched["sonarr GET /api/v3/hopa"], {"candidate": 1, "other": 0})
        self.assertEqual(unmatched["radarr GET /api/v3/hopb"], {"candidate": 0, "other": 1})

    def test_reused_connection_is_attributed_by_host(self):
        # Given one curl that fetches Sonarr, then Radarr, then Sonarr again.
        # When observe.py reduces the trace.
        sonarr, radarr = self.report["entries"]["sonarr"], self.report["entries"]["radarr"]

        # Then each request counts for the service it was sent to.
        self.assertEqual(sonarr["quality-profile-list"]["candidate"], {"200": 1})
        self.assertEqual(radarr["root-folder-list"]["other"], {"200": 1})
        self.assertEqual(sonarr["custom-format-list"]["candidate"], {"200": 1})
        self.assertNotIn("custom-format-list", radarr)

    def test_request_to_a_local_port_no_service_owns_is_unparsed(self):
        # Given a GET to a local server whose port is not in the service port map.
        # When observe.py reduces the trace.
        report = self.report

        # Then it counts as unparsed among the seven requests.
        self.assertEqual((report["requests"], report["unparsed"]), (7, 1))


class Lines(unittest.TestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        print(f"PASS\t{test.id().rsplit('.', 1)[-1]}")

    def _bad(self, test, err):
        print(f"FAIL\t{getattr(test, 'id', lambda: str(test))().rsplit('.', 1)[-1]}")
        print(self._exc_info_to_string(err, test), file=sys.stderr)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._bad(test, err)

    def addError(self, test, err):
        super().addError(test, err)
        self._bad(test, err)


result = Lines()
unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
sys.exit(0 if result.wasSuccessful() and result.testsRun else 1)
PY
)
CURL_IMAGE="ms-contracts-curl:bookworm"
CURL_DOCKERFILE='FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*'

# Records one suite run's results under a label: the curl that ran it.
record_suite() {
    local label="$1" results="$2" rc="$3" status name
    while IFS=$'\t' read -r status name; do
        case "$status" in
            PASS) pass "$label: $name" ;;
            FAIL) fail "$label: $name" ;;
        esac
    done <<<"$results"
    [[ "$results" == *PASS* ]] || fail "$label: contract observe cases ran" "no case reported a result"
    ((rc == 0)) || fail "$label: contract observe suite exits cleanly" "python exited $rc"
}

results=$(python3 -I - "$REPO_ROOT" <<<"$SUITE")
record_suite "host curl" "$results" "$?"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "curl 7.88: the suite in a bookworm-slim container" "Docker not available"
elif ! docker build -q -t "$CURL_IMAGE" - <<<"$CURL_DOCKERFILE" >/dev/null 2>&1; then
    skip "curl 7.88: the suite in a bookworm-slim container" "image build failed (offline?)"
else
    # The DinD image's curl, whose trace observe.py must parse once PR 2 records in DinD.
    results=$(docker run --rm -i --network none -v "$REPO_ROOT:/repo:ro" "$CURL_IMAGE" \
        python3 -I - /repo <<<"$SUITE")
    record_suite "curl 7.88" "$results" "$?"
fi

scenario_end "$CURRENT_SCENARIO"
summary

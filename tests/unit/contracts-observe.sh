#!/usr/bin/env bash
# tests/unit/contracts-observe.sh
#
# Proves the contract trace path end to end without images: real /usr/bin/curl
# runs through tests/lib/contract-trace-curl.sh against a stdlib http.server
# fixture that answers as Sonarr, in each call style the product uses (-o with
# -w, -K - config on stdin, --data-binary @-, a chunked response, a 100
# Continue POST, and -L through a 302). tests/contracts/observe.py then reduces
# the traces, and the assertions read its contracts.json. No stored traces, no
# Docker and no network beyond 127.0.0.1.

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

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
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


class Sonarr(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    bodies: dict[str, bytes] = {}

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

    def do_GET(self):
        if self.path == f"/api/v3/legacy/{LONG_SEGMENT}":
            self.send_response(302)
            self.send_header("Location", "/api/v3/config/naming")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/api/v3/customformat":
            self._send(200, [{"id": 5, "name": "x265-fixture"}], chunked=True)
        elif self.path in GETS:
            self._send(200, GETS[self.path])
        else:
            self._send(404, {"message": "NotFound"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Sonarr.bodies[self.path] = body
        self._send(201, {"id": 9, **json.loads(body)})

    def log_message(self, *_args):
        pass


class Fixture:
    """One recorded session: the fixture server, the shim on PATH, and the traces."""

    def __init__(self, folder):
        self.folder = folder
        self.traces = folder / "traces"
        self.traces.mkdir()
        shim_bin = folder / "bin"
        shim_bin.mkdir()
        (shim_bin / "curl").symlink_to(ROOT / "tests/lib/contract-trace-curl.sh")
        self.env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
        self.env.update(PATH=f"{shim_bin}:{os.environ['PATH']}", NO_PROXY="127.0.0.1",
                        MS_CONTRACT_TRACE=str(self.traces))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sonarr)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def curl(self, *args, stdin="", env=None):
        return subprocess.run(["curl", *args], input=stdin, capture_output=True, text=True,
                              env=env or self.env, timeout=30)

    def events(self, *starts):
        lines = [json.dumps({"Type": "container", "Action": "start", "timeNano": t,
                             "Actor": {"ID": f"id{t}", "Attributes": {
                                 "com.docker.compose.service": "sonarr", "image": image}}})
                 for t, image in starts]
        path = self.folder / f"events-{len(lines)}-{starts[-1][0]}.jsonl"
        path.write_text("\n".join(lines) + "\n")
        return path

    def reduce(self, events):
        out = subprocess.run(
            [sys.executable, "-I", str(ROOT / "tests/contracts/observe.py"),
             "--traces", str(self.traces), "--events", str(events),
             "--ports", json.dumps({"sonarr": self.server.server_port}),
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
        cls.fx.curl("-sS", f"{url}/api/v3/indexer")
        cls.fx.curl("-sS", f"{url}/api/v3/qualityprofile/1")
        cls.fx.curl("-sSL", f"{url}/api/v3/legacy/{LONG_SEGMENT}")
        cls.failed_call = cls.fx.curl("-sf", f"{url}/api/v3/missing")
        cls.finished = time.time_ns()
        cls.report = json.loads(cls.fx.reduce(cls.fx.events((cls.started - 1, CANDIDATE))))
        cls.sonarr = cls.report["entries"]["sonarr"]

    @classmethod
    def tearDownClass(cls):
        cls.fx.server.shutdown()
        cls.fx.server.server_close()
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
unittest.defaultTestLoader.loadTestsFromTestCase(ObserveContract).run(result)
sys.exit(0 if result.wasSuccessful() and result.testsRun else 1)
PY
)
rc=$?

while IFS=$'\t' read -r status name; do
    case "$status" in
        PASS) pass "$name" ;;
        FAIL) fail "$name" ;;
    esac
done <<<"$results"
[[ "$results" == *PASS* ]] || fail "contract observe cases ran" "no case reported a result"
((rc == 0)) || fail "contract observe suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/unit/contracts-observe-rules.sh
#
# Proves the reducer rules in tests/contracts/observe.py that real curl on
# 127.0.0.1 cannot reach: a request to a public address is ignored, an
# unlisted path keeps only route-like segments, and a request at exactly a
# container's start time binds to that container's image. The end-to-end
# trace path is proved by tests/unit/contracts-observe.sh. Pure python3, no
# Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-observe-rules"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import pathlib
import sys
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "tests/contracts"))
import inventory  # noqa: E402
import observe  # noqa: E402

CANDIDATE = "lscr.io/linuxserver/sonarr@sha256:" + "c" * 64
ACCEPTED = "lscr.io/linuxserver/sonarr@sha256:" + "a" * 64


class ReducerRules(unittest.TestCase):
    found = inventory.load_endpoints()

    def test_external_target_is_ignored(self):
        # Given a request to a public address on a port that Sonarr owns locally.
        request = observe.Request(1, ("", 0), {("example.com", 8989): "93.184.216.34"},
                                  bytearray(b"GET /api/v3/indexer HTTP/1.1\r\n"
                                            b"Host: example.com:8989\r\n\r\n"))

        # When the request is tallied.
        result = observe.tally([request], self.found, {8989: "sonarr"},
                               observe.Binder({}, {}))

        # Then it is counted as a request but not as Sonarr traffic or as unparsed.
        self.assertEqual((result.requests, result.unparsed), (1, 0))
        self.assertEqual((result.entries, result.unmatched), ({}, {}))

    def test_unmatched_path_keeps_only_route_like_segments(self):
        # Given an unlisted path with a short mixed-case token, a plain word and a number.
        path = "/api/v3/Ab3xYz9/status/42"

        # When the path is redacted.
        redacted = observe.redact(path, observe.route_literals(self.found))

        # Then only the token is hidden.
        self.assertEqual(redacted, "/api/v3/{redacted}/status/42")

    def test_request_at_the_start_time_binds_to_the_started_image(self):
        # Given the accepted image started at 100 and the candidate at 200.
        binder = observe.Binder({"sonarr": [(100, ACCEPTED), (200, CANDIDATE)]},
                                {"sonarr": CANDIDATE})

        # When a request that started at exactly 200 is bound.
        side = binder.side("sonarr", 200)

        # Then it binds to the candidate.
        self.assertEqual(side, "candidate")


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
unittest.defaultTestLoader.loadTestsFromTestCase(ReducerRules).run(result)
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
[[ "$results" == *PASS* ]] || fail "contract reducer rule cases ran" "no case reported a result"
((rc == 0)) || fail "contract reducer rule suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary

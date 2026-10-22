#!/usr/bin/env bash
# Unit test - autoheal's compose stanza gives one in-flight heal time to finish on stop.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="autoheal-compose"
scenario_begin "$CURRENT_SCENARIO"

# Given docker-compose.yml
# When the autoheal service block is read
# Then stop_grace_period is at least 30s: SIGINT waits for the in-flight
# `docker restart` (10 s stop timeout plus start), and the 10 s default killed
# autoheal mid-heal with exit 137
block=$(awk '/^  autoheal:/{f=1;next} f&&/^  [a-z-]+:/{exit} f' "$REPO_ROOT/docker-compose.yml")
grace=$(sed -n 's/^    stop_grace_period: *\([0-9]*\)s *$/\1/p' <<<"$block")
if [[ -n "$grace" && "$grace" -ge 30 ]]; then
    pass "autoheal: stop_grace_period covers one heal (${grace}s)"
else
    fail "autoheal: stop_grace_period covers one heal" "found '${grace:-none}'"
fi

scenario_end "$CURRENT_SCENARIO"
summary

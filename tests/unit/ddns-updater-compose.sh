#!/usr/bin/env bash
# Unit test - ddns-updater compose stanza allows a slow provider response.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ddns-updater-compose"
scenario_begin "$CURRENT_SCENARIO"

# Given docker-compose.yml
# When the ddns-updater service block is read
# Then HTTP_TIMEOUT is at least 45s, covering Dynu's observed 36s response
# without approaching the 5m update period.
block=$(awk '/^  ddns-updater:/{found=1; next} found && /^  [a-z-]+:/{exit} found' "$REPO_ROOT/docker-compose.yml")
timeout=$(sed -n 's/^      - HTTP_TIMEOUT=\([0-9][0-9]*\)s *$/\1/p' <<<"$block")
if [[ -n "$timeout" && "$timeout" -ge 45 ]]; then
    pass "ddns-updater: HTTP_TIMEOUT covers slow provider responses (${timeout}s)"
else
    fail "ddns-updater: HTTP_TIMEOUT covers slow provider responses" "found '${timeout:-none}'"
fi

scenario_end "$CURRENT_SCENARIO"
summary

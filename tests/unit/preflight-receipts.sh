#!/usr/bin/env bash
# tests/unit/preflight-receipts.sh
#
# Unit test - tests/lib/receipts.sh: an image preflight receipt row exists only when
# that scenario passed on its own AND its container events show the service ran from
# the candidate digest, and every row names the source commit, run and host it came
# from. A fake `docker` on PATH stands in for DinD: `exec` runs the command against
# local files, so the event log, offsets and barrier are the real code. A fake `git`
# stands in for the host checkout, so the real repository is never read.
#
# Thin entry point: the fixture and the cases are split by topic into
# tests/unit/preflight-receipts/ - each file sourced in sequence below, in the
# same shell, so a later topic sees the helpers an earlier one defined.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="preflight-receipts"
scenario_begin "$CURRENT_SCENARIO"

TOPIC_DIR="$SCRIPT_DIR/preflight-receipts"

# shellcheck source=tests/unit/preflight-receipts/lib.sh
source "$TOPIC_DIR/lib.sh"
# shellcheck source=tests/unit/preflight-receipts/evidence.sh
source "$TOPIC_DIR/evidence.sh"
# shellcheck source=tests/unit/preflight-receipts/provenance.sh
source "$TOPIC_DIR/provenance.sh"

summary

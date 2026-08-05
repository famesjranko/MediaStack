#!/usr/bin/env bash
# tests/unit/repository-safety.sh
#
# Fixture proof for tests/lib/repo_guard.py, the repository publication-safety
# guard: forbidden private artifacts, tracked host artifacts, secret files and
# credential patterns, and config/workflow YAML validity.
# Pure bash + python3 + git — no Docker, no network.
#
# Every rule gets one clean and one targeted bad fixture built in a temp git
# repo, so no fixture touches the real tree. The real-tree check always scans
# REPO_ROOT and takes no override — a redirectable scan root is a channel for
# masking the one check that covers what actually ships.
#
# Every entry of every rule list is exercised by its own probe path and pinned
# by an EXPECTED_* set assertion, so deleting one turns this suite red.
#
# Thin entry point: shared fixture builders and the checks themselves are
# split by topic into tests/unit/repository-safety/ - each file sourced in
# sequence below, in the same shell, so the state a later topic depends on
# (EXERCISED, the probe arrays, the fixture directories) is exactly what an
# earlier one left behind.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="repository-safety"
scenario_begin "$CURRENT_SCENARIO"

TOPIC_DIR="$SCRIPT_DIR/repository-safety"

# shellcheck source=tests/unit/repository-safety/lib.sh
source "$TOPIC_DIR/lib.sh"
# shellcheck source=tests/unit/repository-safety/core-rules.sh
source "$TOPIC_DIR/core-rules.sh"
# shellcheck source=tests/unit/repository-safety/list-coverage.sh
source "$TOPIC_DIR/list-coverage.sh"
# shellcheck source=tests/unit/repository-safety/pattern-parity.sh
source "$TOPIC_DIR/pattern-parity.sh"
# shellcheck source=tests/unit/repository-safety/closing.sh
source "$TOPIC_DIR/closing.sh"

scenario_end "$CURRENT_SCENARIO"
summary

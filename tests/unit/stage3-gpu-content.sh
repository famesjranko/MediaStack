#!/usr/bin/env bash
# Owns: the stage3 GPU Compose-content unit-suite entry point and setup.
# Sources: tests/unit/gpu/compose.sh and scripts/setup/gpu/compose.sh via setup.sh.
# tests/unit/stage3-gpu-content.sh
#
# Cross-branch exclusivity tests for `generate_override` GPU output. For each
# GPU type (none, nvidia, intel, amd), assert the jellyfin: block contains
# ONLY the directives expected for that type — no leakage from other branches.
#
# Why this exists: tests/unit/resource-limits.sh covers "what should be
# present" per type but doesn't catch cross-contamination (e.g., a regression
# that adds `runtime: nvidia` to the `none` path). tests/unit/stage3-flow.sh
# stubs generate_override entirely. So if a future edit accidentally moves
# `runtime: nvidia` outside the `nvidia)` case arm, only this file would
# catch it.
#
# Pure-bash; no DinD/Docker/network. Same shim pattern as resource-limits.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="stage3-gpu-content"
echo -e "${CYAN}${BOLD}▶ scenario: stage3-gpu-content${NC}"

# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

set +e
set +u

log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

TMPDIR_WORK=$(mktemp -d)
SCRIPT_DIR="$TMPDIR_WORK"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
HOST_MEMORY_MB=4096
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
IMAGE_CHANNEL=latest

# shellcheck source=gpu/compose.sh
source "$REPO_ROOT/tests/unit/gpu/compose.sh"

summary

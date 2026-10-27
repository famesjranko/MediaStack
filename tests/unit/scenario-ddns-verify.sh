#!/usr/bin/env bash
# tests/unit/scenario-ddns-verify.sh
#
# tests/scenarios/ddns-verify.sh starts ddns-updater outside Compose. The
# preflight receipts (tests/lib/receipts.sh) attribute container events to a
# service by the Compose service label, so every container the scenario starts
# must carry com.docker.compose.service=ddns-updater or a passing run can never
# earn a receipt. Drives the scenario's own launcher against a recording
# `dind_exec` and checks the launch text. Pure bash; no Docker, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="scenario-ddns-verify"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
LAUNCH_LOG="$TMP_DIR/launches.log"
: >"$LAUNCH_LOG"

cd "$REPO_ROOT" || exit 1
# shellcheck source=/dev/null
source tests/scenarios/ddns-verify.sh

# Stubs: the render step runs `docker exec ... bash -c` directly and must
# succeed; every dind_exec call is recorded, and `docker port` answers nothing
# so the launcher takes its NO-PORT exit after starting the container.
docker() { [[ "$1" == exec ]]; }
dind_exec() {
    printf '%s\n' "$*" >>"$LAUNCH_LOG"
    case "$*" in
        *"docker port"*) printf '' ;;
        *) : ;;
    esac
}
# Read by the sourced scenario functions, not by this file.
# shellcheck disable=SC2034
DV_GW=172.17.0.1
# shellcheck disable=SC2034
DIND_NAME=fake-dind
DV_IMAGE=qmcgaw/ddns-updater:latest@sha256:0000000000000000000000000000000000000000000000000000000000000000

# Given the scenario's one-shot verify launcher
# When it starts a ddns-updater container
result=$(_ddns_verify_run good dynu verify.test '[password]=p')

# Then the container carries the Compose service label the receipts need
launch=$(grep -A4 'docker run -d --name dv-verify' "$LAUNCH_LOG")
assert_contains "$launch" "--label com.docker.compose.service=ddns-updater" "ddns-verify: the one-shot verify container carries the compose service label"
assert_contains "$launch" "$DV_IMAGE" "ddns-verify: the one-shot verify container runs the candidate image"
assert_eq "NO-PORT 0" "$result" "ddns-verify: the launcher took the stubbed no-port exit"

# Given every container launch in the scenario file (the infra probe and the
# real-helper shim included)
runs=$(grep -cE '^\s*(command )?docker run ' tests/scenarios/ddns-verify.sh)
labels=$(grep -c -- '--label com.docker.compose.service=ddns-updater' tests/scenarios/ddns-verify.sh)

# When the launches are counted against the labels
# Then each launch carries the label
assert_eq "3" "$runs" "ddns-verify: the scenario has three container launch sites"
assert_eq "$runs" "$labels" "ddns-verify: every launch site carries the compose service label"

summary

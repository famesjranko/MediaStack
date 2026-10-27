#!/usr/bin/env bash
# The full battery checks accepted-image management without inventing receipts.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
source tests/lib/assert.sh
source tests/scenarios/upgrade-path.sh
scenario_begin upgrade-baseline
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dind_exec() { return 0; }
dind_write_file() { cat >/dev/null; }
dind_override_images() { printf '%s' "$MS_TEST_IMAGE_OVERRIDES" >"$tmp/pin"; }
fresh_install_run() {
    touch "$tmp/fresh"
    return 1
}

# Given the ordinary battery supplies neither a candidate nor stripped services.
MS_TEST_IMAGE_OVERRIDES=""
MS_TEST_STRIP_SERVICES=""

# When the real scenario prepares its baseline and reaches fresh installation.
run_scenario >"$tmp/log" 2>&1 || true

# Then Update/Revert has an exact accepted target and caller overrides stay empty.
assert_eq true "$(test -f "$tmp/fresh" && echo true)" 'baseline management reaches accepted-image setup'
accepted=$(awk -F '\t' '$1 == "qbittorrent" { print $1 "=" $2 "@" $3 }' docs/operations/image-digests.lock)
assert_eq "$accepted" "$(cat "$tmp/pin")" 'baseline management pins the accepted qBittorrent image'
assert_eq '' "$MS_TEST_IMAGE_OVERRIDES" 'baseline pin does not leak into later battery scenarios'
assert_contains "$(cat "$tmp/log")" 'no candidate evidence' 'baseline management does not claim migration evidence'

# Given an explicit candidate whose lock is identical to the accepted lock.
rm "$tmp/fresh"
MS_TEST_IMAGE_OVERRIDES="$accepted"

# When the same scenario compares the candidate and accepted locks.
(run_scenario) >"$tmp/log" 2>&1 || true

# Then the unchanged candidate is refused before installation can qualify it.
assert_eq false "$(test -f "$tmp/fresh" && echo true || echo false)" 'unchanged explicit candidate never reaches setup'
assert_contains "$(cat "$tmp/log")" 'requires a changed candidate digest' 'unchanged explicit candidate is reported as a failure'
summary

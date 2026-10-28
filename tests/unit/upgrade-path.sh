#!/usr/bin/env bash
# The real upgrade scenario must record a failed or mismatched image inspection.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
source tests/lib/assert.sh
source tests/scenarios/upgrade-path.sh
scenario_begin upgrade-path
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Isolate container operations while retaining the scenario and its assertions.
dind_exec() {
    case "$1" in
        'cmp -s '*) return 1 ;;
        'docker inspect '*wireguard) return 1 ;;
        'docker inspect '*)
            case "$inspection" in
                matching) printf '%s\n' "$candidate" ;;
                wrong) printf '%s\n' 'ghcr.io/gethomepage/homepage:latest' ;;
                missing) return 1 ;;
            esac
            ;;
        *) return 0 ;;
    esac
}
dind_write_file() { cat >/dev/null; }
fresh_install_run() { return 0; }
env_set() { return 0; }
env_get() { printf '%s\n' fixture; }
upgrade_launcher() { return 0; }
wait_healthy() { return 0; }
assert_qbittorrent_configured() { return 0; }
assert_jackett_configured() { return 0; }
assert_sonarr_configured() { return 0; }
assert_radarr_configured() { return 0; }
assert_seerr_configured() { return 0; }
upgrade_state() {
    case "$1" in
        flip) flipped=$((1 - flipped)) ;;
        check) ((flipped == 0)) ;;
        *) return 0 ;;
    esac
}
probe() (
    PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0
    FAILED_TESTS=()
    scenario_begin candidate-inspection
    flipped=0
    run_scenario
    summary
)

# Given a selected non-core service runs the exact requested candidate image.
candidate="ghcr.io/gethomepage/homepage:latest@sha256:$(printf '%064d' 1)"
MS_TEST_IMAGE_OVERRIDES="homepage=$candidate"
MS_TEST_STRIP_SERVICES=""
inspection=matching

# When the real upgrade scenario inspects the running image.
run_cmd probe

# Then successful image evidence allows the scenario to pass.
assert_rc 0 'upgrade-path accepts the exact requested image'

# Given an earlier caller case has already recorded failed assertions.
OUT=$(
    PASS_COUNT=4 FAIL_COUNT=2 SKIP_COUNT=1
    FAILED_TESTS=('previous case failed')

    # When an otherwise passing probe starts its own scenario.
    probe
)
RC=$?

# Then the probe result does not inherit the caller's counts or failure list.
assert_rc 0 'upgrade-path probes isolate earlier caller failures'
assert_not_contains "$OUT" 'previous case failed' 'upgrade-path probes isolate earlier failure details'

# Given the selected service runs a floating tag instead of the candidate.
inspection=wrong

# When the same scenario inspects that container.
run_cmd probe

# Then a mismatched image blocks the scenario.
assert_rc 1 'upgrade-path rejects the wrong running image'
assert_contains "$OUT" '[FAIL] upgrade-path: homepage actually runs the requested image' 'wrong image has an explicit assertion failure'

# Given the selected container cannot be inspected.
inspection=missing

# When the scenario attempts to verify its requested image.
run_cmd probe

# Then missing runtime evidence blocks the scenario with a useful failure.
assert_rc 1 'upgrade-path rejects a missing container'
assert_contains "$OUT" '[FAIL] upgrade-path: homepage image inspection failed' 'missing container has an explicit assertion failure'

# Given a plan also pins an unchanged companion in a disabled profile.
inspection=matching
accepted=$(awk -F '\t' '$1 == "wireguard" { print $2 "@" $3 }' docs/operations/image-digests.lock)
MS_TEST_IMAGE_OVERRIDES="homepage=$candidate,wireguard=$accepted"

# When the scenario checks only its active profiles.
run_cmd probe

# Then the accepted optional companion does not require a running container.
assert_rc 0 'upgrade-path permits unchanged companions outside active profiles'

# Given a candidate changes an image in that disabled profile instead.
MS_TEST_IMAGE_OVERRIDES="wireguard=$candidate"

# When the same upgrade scenario attempts to qualify it.
run_cmd probe

# Then the absent profile cannot earn candidate compatibility evidence.
assert_rc 1 'upgrade-path rejects candidates outside active profiles'
assert_contains "$OUT" 'wireguard candidate is outside active profiles' 'unsupported candidate has an explicit assertion failure'
summary

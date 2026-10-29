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
        'docker compose up -d --force-recreate '*) : >"$tmp/baseline-recreated" ;;
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
upgrade_interrupted_revert() { return 0; }
wait_healthy() { return 0; }
assert_qbittorrent_configured() { return 0; }
assert_jackett_configured() { return 0; }
assert_sonarr_configured() { return 0; }
assert_radarr_configured() { return 0; }
assert_seerr_configured() { return 0; }
fresh_install_assert_product_probes() { echo "product probes: ${1:-}"; }
# A stand-in for the state comparison. drop_report says how it reports a lost
# Seerr user and a removed Jellyfin API key: both (correct), one name only,
# both names with rc 0, or none (a blind comparison).
upgrade_state() {
    case "$1" in
        flip) flipped=$((1 - flipped)) ;;
        drop) dropped=1 ;;
        restore) dropped=0 ;;
        check)
            if ((dropped)); then
                case "$drop_report" in
                    both) echo 'persistent state changed: jellyfin/api-keys, seerr/users' && return 1 ;;
                    one) echo 'persistent state changed: seerr/users' && return 1 ;;
                    rc0) echo 'persistent state changed: jellyfin/api-keys, seerr/users' && return 0 ;;
                esac
            fi
            ((flipped == 0))
            ;;
        *) return 0 ;;
    esac
}
probe() (
    PASS_COUNT=0 FAIL_COUNT=0 SKIP_COUNT=0
    FAILED_TESTS=()
    scenario_begin candidate-inspection
    flipped=0 dropped=0
    run_scenario
    summary
)

# Given a selected non-core service runs the exact requested candidate image.
candidate="ghcr.io/gethomepage/homepage:latest@sha256:$(printf '%064d' 1)"
MS_TEST_IMAGE_OVERRIDES="homepage=$candidate"
MS_TEST_STRIP_SERVICES=""
inspection=matching
drop_report=both

beszel_failure=""
beszel_upgrade_state() {
    printf '%s\n' "$1" >>"$tmp/beszel-calls"
    [[ "$1" != "$beszel_failure" ]]
}

# Given each Beszel migration phase can fail independently.
for beszel_failure in seed save check prepare-recovery; do
    # When the real scenario encounters that failed phase.
    run_cmd probe

    # Then failed Beszel evidence makes the scenario fail.
    assert_rc 1 "upgrade-path rejects failed Beszel $beszel_failure"
done
beszel_failure=""

# When the real upgrade scenario inspects the running image.
run_cmd probe

# Then successful image evidence allows the scenario to pass.
assert_rc 0 'upgrade-path accepts the exact requested image'
# And the product probes run again with the candidate label.
assert_contains "$OUT" 'product probes: upgrade-path candidate: ' 'upgrade-path re-runs the labelled product probes on the candidate'

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

# Given each way a state comparison can report the lost Seerr user and Jellyfin
# API key incompletely: not at all, one name only, or both names with rc 0.
for drop_report in none one rc0; do
    # When the scenario runs its self-test before trusting that comparison.
    run_cmd probe

    # Then the incomplete report blocks the scenario with an explicit failure.
    assert_rc 1 "upgrade-path rejects a comparison that reports lost records as '$drop_report'"
    assert_contains "$OUT" '[FAIL] upgrade-path detects a lost Seerr user and a removed Jellyfin API key' \
        "comparison report '$drop_report' has an explicit assertion failure"
done

# Given the scenario source.
scenario=tests/scenarios/upgrade-path.sh

# When the order of the update, the state checks, reconfiguration and the
# candidate probes is read.
line_of() { grep -nF -- "$1" "$scenario" | head -1 | cut -d: -f1; }
update_line=$(line_of './scripts/update.sh')
check_line=$(line_of "if upgrade_state check; then")
configure_line=$(line_of './scripts/configure.sh --only')
beszel_check_line=$(line_of 'if beszel_upgrade_state check; then')
beszel_repair_line=$(line_of 'if beszel_upgrade_state prepare-recovery')
probes_line=$(line_of "fresh_install_assert_product_probes 'upgrade-path candidate: '")

# Then state is compared after the update and before configure.sh re-applies
# values such as Seerr's default quotas.
if ((update_line && update_line < check_line && check_line < configure_line)); then
    pass 'upgrade-path compares state after the update and before reconfiguration'
else
    fail 'upgrade-path compares state after the update and before reconfiguration' \
        "update=$update_line check=$check_line configure=$configure_line"
fi
# And Beszel's migration comparison precedes any candidate credential repair.
if ((update_line < beszel_check_line && beszel_check_line < beszel_repair_line && beszel_repair_line < configure_line)); then
    pass 'upgrade-path compares Beszel state before candidate recovery and reconfiguration'
else
    fail 'upgrade-path compares Beszel state before candidate recovery and reconfiguration'
fi
# And the labelled candidate probes run after the update.
if ((update_line && probes_line > update_line)); then
    pass 'upgrade-path calls the labelled candidate probes after the update'
else
    fail 'upgrade-path calls the labelled candidate probes after the update' "update=$update_line probes=$probes_line"
fi

# Given the selected service runs a floating tag instead of the candidate.
drop_report=both
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

# Given the battery has no candidate and Compose would keep identical images running.
MS_TEST_IMAGE_OVERRIDES=""
candidate=$(awk -F '\t' '$1 == "qbittorrent" {print $2 "@" $3}' docs/operations/image-digests.lock)
dind_override_images() { return 0; }

# When the accepted-image management scenario runs.
run_cmd probe

# Then every data-owning service is recreated to reload its stored state.
assert_rc 0 'upgrade-path baseline succeeds without claiming candidate evidence'
assert_eq yes "$([[ -f "$tmp/baseline-recreated" ]] && echo yes || echo no)" 'upgrade-path baseline reloads state from disk'
assert_contains "$OUT" 'no candidate evidence' 'baseline replacement is labelled explicitly'
summary

# tests/unit/assertions/arr.sh — sourced by tests/unit/assertions.sh.
# Sonarr/Radarr indexer evidence: expectations from the DinD fixture, every
# read fail-closed, an empty fixture an explicit SKIP.

# shellcheck source=/dev/null
source tests/assertions/sonarr.sh
# shellcheck source=/dev/null
source tests/assertions/radarr.sh

ARR_LOG="$TMP_DIR/configure.log"
: >"$ARR_LOG"

# Fixture and live state the stubs serve. STUB_FIXTURE is what the DinD
# config.yml reader prints (an integer or ERR:...); STUB_INDEXER_BODY is the
# GET /indexer body and STUB_INDEXER_RC its curl exit status.
STUB_FIXTURE="2"
STUB_INDEXER_BODY="[]"
STUB_INDEXER_RC=0
# STUB_TEST is the verdict of the in-DinD connection test (arr_indexer_test_all),
# which is the only dind_python call that receives an API base URL.
STUB_TEST="OK|2 tested"

dind_python() {
    case "${1:-}" in
        http*) printf '%s\n' "$STUB_TEST" ;;
        *) printf '%s\n' "$STUB_FIXTURE" ;;
    esac
}

# Any other API read answers with an empty object/list so the unrelated checks
# in assert_<app>_configured run to completion without hanging.
dind_exec() {
    local cmd="$*"
    case "$cmd" in
        *"/api/v3/indexer"*)
            ((STUB_INDEXER_RC == 0)) || return "$STUB_INDEXER_RC"
            printf '%s' "$STUB_INDEXER_BODY"
            ;;
        *"/api/v3/qualityprofile"* | *"/customformat"* | *"/notification"* | *"/downloadclient"* | *"/rootfolder"* | *"/qualitydefinition"*)
            printf '[]'
            ;;
        *) printf '{}' ;;
    esac
}

arr_seeded() { # arr_seeded <seedRatio> <seedTime> <seasonPackSeedTime>
    printf '[{"name":"a","fields":[{"name":"seedCriteria.seedRatio","value":%s},{"name":"seedCriteria.seedTime","value":%s},{"name":"seedCriteria.seasonPackSeedTime","value":%s}]},{"name":"b","fields":[{"name":"seedCriteria.seedRatio","value":%s},{"name":"seedCriteria.seedTime","value":%s},{"name":"seedCriteria.seasonPackSeedTime","value":%s}]}]' \
        "$1" "$2" "$3" "$1" "$2" "$3"
}

# Given a fixture with two Sonarr indexers and a GET /indexer that fails
STUB_FIXTURE="2"
STUB_INDEXER_RC=22

# When the Sonarr evidence assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the failed read is a FAIL and no indexer count is reported as passing
assert_eq "1" "$(verdict_count "$out" FAIL "GET /indexer answers")" "arr: a failed GET /indexer is a FAIL, not a zero count"
assert_eq "0" "$(verdict_count "$out" PASS "indexers configured")" "arr: a failed GET /indexer never passes the indexer count"

# Given the same failed read for Radarr
# When the Radarr evidence assertion runs
out=$(verdicts assert_radarr_configured "$ARR_LOG")

# Then it is a FAIL there too (shared helper wired into both apps)
assert_eq "1" "$(verdict_count "$out" FAIL "GET /indexer answers")" "arr: Radarr fails closed on a failed GET /indexer"

# Given the fixture config.yml cannot be read in DinD
STUB_FIXTURE="ERR:config.yml unreadable: [Errno 2] No such file"
STUB_INDEXER_RC=0
STUB_INDEXER_BODY="[]"

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the unreadable fixture is a FAIL, not an empty expectation
assert_eq "1" "$(verdict_count "$out" FAIL "indexer fixture (config.yml in DinD) readable")" "arr: an unreadable fixture is a FAIL"
assert_eq "0" "$(verdict_count "$out" SKIP "indexer")" "arr: an unreadable fixture is not reported as an empty fixture"

# Given a fixture that lists no indexers and a live app with none
STUB_FIXTURE="0"

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the registration check is an explicit SKIP naming the empty fixture
assert_eq "1" "$(verdict_count "$out" SKIP "indexer registration")" "arr: an empty fixture is an explicit SKIP"
assert_eq "0" "$(verdict_count "$out" FAIL "indexer")" "arr: an empty fixture with no live indexers fails nothing"

# Given an empty fixture but a live app that has indexers anyway
STUB_INDEXER_BODY=$(arr_seeded 1.0 1440 2880)

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the unexpected population is a FAIL
assert_eq "1" "$(verdict_count "$out" FAIL "no indexers expected from an empty fixture")" "arr: live indexers with an empty fixture fail"

# Given a two-indexer fixture, both registered with the seed criteria MediaStack writes
STUB_FIXTURE="2"

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the count, the connection test and the seed criteria pass
assert_eq "1" "$(verdict_count "$out" PASS "2/2 indexers configured")" "arr: matching fixture and live counts pass"
assert_eq "1" "$(verdict_count "$out" PASS "every registered indexer passes the app's connection test")" "arr: a passing connection test passes"
assert_eq "1" "$(verdict_count "$out" PASS "indexer seed criteria")" "arr: correct seed criteria pass"

# Given the app's own connection test rejects one registered indexer
STUB_TEST="FAIL|b: HTTP 400 Unable to connect to indexer"

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the failed connection test is a FAIL naming the indexer
assert_eq "1" "$(verdict_count "$out" FAIL "every registered indexer passes the app's connection test")" "arr: a failed connection test is a FAIL"
assert_contains "$out" "b: HTTP 400 Unable to connect to indexer" "arr: the failed indexer and status are named"
STUB_TEST="OK|2 tested"

# Given the live indexers carry a wrong seed ratio
STUB_INDEXER_BODY=$(arr_seeded 0.5 1440 2880)

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the seed criteria check fails and names the wrong value
assert_eq "1" "$(verdict_count "$out" FAIL "indexer seed criteria")" "arr: a wrong seed ratio fails the seed criteria"
assert_contains "$out" "seedRatio=0.5 want 1.0" "arr: the seed criteria failure names the wrong value"

# Given a GET /indexer body that is not a list of indexer objects
STUB_INDEXER_BODY='{"error":"unauthorized"}'

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the malformed response is a FAIL
assert_eq "1" "$(verdict_count "$out" FAIL "GET /indexer returns an indexer list")" "arr: a malformed GET /indexer body is a FAIL"

# Given every eligible fixture indexer was reported unavailable by configure.sh
STUB_INDEXER_BODY="[]"
printf 'Indexer unavailable, skipped: a -> Sonarr\nIndexer unavailable, skipped: b -> Sonarr\n' >"$ARR_LOG"

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then a floor of zero is a FAIL, not a pass over an empty population
assert_eq "1" "$(verdict_count "$out" FAIL "at least one fixture indexer registers")" "arr: all fixture indexers unavailable is a FAIL"
assert_eq "0" "$(verdict_count "$out" PASS "indexers configured")" "arr: a zero floor never passes the count"

# Given one of two fixture indexers was unavailable and the other registered
printf 'Indexer unavailable, skipped: b -> Sonarr\n' >"$ARR_LOG"
STUB_INDEXER_BODY='[{"name":"a","fields":[{"name":"seedCriteria.seedRatio","value":1.0},{"name":"seedCriteria.seedTime","value":1440},{"name":"seedCriteria.seasonPackSeedTime","value":2880}]}]'

# When the assertion runs
out=$(verdicts assert_sonarr_configured "$ARR_LOG")

# Then the lowered floor passes and the detail names the blocked count
assert_eq "1" "$(verdict_count "$out" PASS "1/2 indexers configured (1 upstream-blocked, floor=1)")" "arr: an upstream-blocked indexer lowers the floor"
: >"$ARR_LOG"

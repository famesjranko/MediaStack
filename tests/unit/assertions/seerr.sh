# tests/unit/assertions/seerr.sh — sourced by tests/unit/assertions.sh.
# Seerr evidence: a Sonarr/Radarr entry must carry the intended wiring and the
# stored credentials must pass Seerr's own connection test; object presence
# alone never passes.

# shellcheck source=/dev/null
source tests/assertions/seerr.sh

dind_python() { printf '/data/media/%s|1080p Balanced\n' "$([[ "$1" == sonarr ]] && echo tv || echo movies)"; }

STUB_SR_AUTH="200"
STUB_SR_SONARR=""
STUB_SR_RADARR=""
STUB_SR_TEST_CODE="200"
STUB_SR_TEST_BODY=""
dind_exec() {
    local cmd="$*"
    case "$cmd" in
        *"settings/public"*) printf '{"initialized":true}' ;;
        *"auth/jellyfin"*) printf '%s' "$STUB_SR_AUTH" ;;
        *"python3 -c"*) printf '{}' ;;
        *"settings/sonarr/test"* | *"settings/radarr/test"*) printf '%s' "$STUB_SR_TEST_CODE" ;;
        *"cat /tmp/seerr-"*) printf '%s' "$STUB_SR_TEST_BODY" ;;
        *"settings/sonarr"*)
            [[ -n "$STUB_SR_SONARR" ]] || return 22
            printf '%s' "$STUB_SR_SONARR"
            ;;
        *"settings/radarr"*)
            [[ -n "$STUB_SR_RADARR" ]] || return 22
            printf '%s' "$STUB_SR_RADARR"
            ;;
        *"settings/jellyfin"*) printf '{"libraries":[{"name":"Movies","enabled":true},{"name":"TV Shows","enabled":true}]}' ;;
        *"settings/network"*) printf '{"trustProxy":true}' ;;
        *) return 1 ;;
    esac
}

good_entry() { # good_entry <app> <port> <root>
    printf '[{"id":0,"name":"%s","hostname":"%s","port":%s,"apiKey":"KEY-%s","useSsl":false,"baseUrl":"","activeProfileId":6,"activeProfileName":"1080p Balanced","activeDirectory":"%s","is4k":false,"isDefault":true,"syncEnabled":true,"preventSearch":false}]' \
        "${1^}" "$1" "$2" "$1" "$3"
}
GOOD_TEST='{"profiles":[{"id":6,"name":"1080p Balanced"}],"rootFolders":[{"id":1,"path":"/data/media/tv"},{"id":2,"path":"/data/media/movies"}]}'

# Given Seerr answers GET /settings/sonarr with a bare, empty server object
STUB_SR_SONARR='[{}]'
STUB_SR_RADARR=$(good_entry radarr 7878 /data/media/movies)
STUB_SR_TEST_BODY="$GOOD_TEST"

# When the Seerr evidence assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then Sonarr is not reported connected, and Radarr (correctly wired) is
assert_eq "1" "$(verdict_count "$out" FAIL "Sonarr connected")" "seerr: an empty server object is not a connection"
assert_eq "0" "$(verdict_count "$out" PASS "Sonarr connected")" "seerr: an empty server object never passes"
assert_eq "1" "$(verdict_count "$out" PASS "Radarr connected")" "seerr: a correctly wired entry passes"

# Given a Sonarr entry whose stored key differs from the app's config.xml key
STUB_SR_SONARR=$(good_entry sonarr 8989 /data/media/tv)
STUB_SR_SONARR="${STUB_SR_SONARR//KEY-sonarr/stale-key}"

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then the mismatch is a FAIL that does not print the key
assert_eq "1" "$(verdict_count "$out" FAIL "Sonarr connected")" "seerr: a stale stored API key fails"
assert_contains "$out" "apiKey differs from the config.xml key of the app" "seerr: the key mismatch is named"
assert_not_contains "$out" "stale-key" "seerr: the stored key value is never printed"

# Given a Sonarr entry pointing at the wrong root folder
STUB_SR_SONARR=$(good_entry sonarr 8989 /wrong/path)

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then the wrong wiring is a FAIL naming the field
assert_contains "$out" "activeDirectory='/wrong/path' want '/data/media/tv'" "seerr: a wrong root folder is named"

# Given a correct Sonarr entry whose connection test does not offer the configured profile
STUB_SR_SONARR=$(good_entry sonarr 8989 /data/media/tv)
STUB_SR_TEST_BODY='{"profiles":[{"id":1,"name":"Any"}],"rootFolders":[{"id":1,"path":"/data/media/tv"},{"id":2,"path":"/data/media/movies"}]}'

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then the entry passes but the live connection check fails
assert_eq "1" "$(verdict_count "$out" PASS "Sonarr connected")" "seerr: the stored entry passes on its own"
assert_eq "1" "$(verdict_count "$out" FAIL "Sonarr reachable with stored credentials")" "seerr: a connection test without the profile fails"
assert_contains "$out" "profile '1080p Balanced' not offered" "seerr: the missing profile is named"

# Given the connection test answers a non-200 status
STUB_SR_TEST_CODE="500"

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then the unreachable app is a FAIL carrying the status
assert_contains "$out" "POST /settings/sonarr/test returned HTTP 500" "seerr: a failed connection test is a FAIL with its status"

# Given both entries are correct and both connection tests succeed
STUB_SR_TEST_CODE="200"
STUB_SR_TEST_BODY="$GOOD_TEST"

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then both apps pass the entry and the reachability checks
assert_eq "2" "$(verdict_count "$out" PASS "connected (host=")" "seerr: both correct entries pass"
assert_eq "2" "$(verdict_count "$out" PASS "reachable with stored credentials")" "seerr: both connection tests pass"
assert_eq "0" "$(verdict_count "$out" FAIL "")" "seerr: the happy path has no failures"

# Given GET /settings/sonarr fails
STUB_SR_SONARR=""

# When the assertion runs
out=$(verdicts assert_seerr_configured pw)

# Then the failed read is a FAIL, not an empty list
assert_contains "$out" "GET /settings/sonarr failed" "seerr: a failed settings read is a FAIL"

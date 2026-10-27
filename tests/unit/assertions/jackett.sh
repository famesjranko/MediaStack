# tests/unit/assertions/jackett.sh — sourced by tests/unit/assertions.sh.
# Jackett evidence: the fixture read is fail-closed, an empty fixture is an
# explicit SKIP, and every configured indexer must serve caps with categories.

# shellcheck source=/dev/null
source tests/assertions/jackett.sh

api_get_jackett_key() { printf 'jackett-api-key-0123456789'; }

# STUB_JK_IDS is what the DinD fixture reader prints; STUB_JK_CAPS[<id>] is the
# caps document for that indexer (unset = request fails).
STUB_JK_IDS="NONE"
declare -A STUB_JK_CAPS=()
dind_python() { printf '%s\n' "$STUB_JK_IDS"; }
dind_exec() {
    local cmd="$*" idx
    [[ "$cmd" == *"/indexers/"* ]] || return 1
    idx="${cmd#*/indexers/}"
    idx="${idx%%/*}"
    [[ -n "${STUB_JK_CAPS[$idx]:-}" ]] || return 22
    printf '%s' "${STUB_JK_CAPS[$idx]}"
}

CAPS_WITH_CATEGORIES='<?xml version="1.0"?><caps><categories><category id="5000" name="TV"/></categories></caps>'
CAPS_NO_CATEGORIES='<?xml version="1.0"?><caps><categories></categories></caps>'

# Given the DinD fixture config.yml cannot be read
STUB_JK_IDS="ERR:config.yml unreadable: [Errno 2] No such file"

# When the Jackett evidence assertion runs
out=$(verdicts assert_jackett_configured)

# Then the unreadable fixture is a FAIL and nothing is skipped as "no indexers"
assert_eq "1" "$(verdict_count "$out" FAIL "indexer fixture (config.yml in DinD) readable")" "jackett: an unreadable fixture is a FAIL"
assert_eq "0" "$(verdict_count "$out" SKIP "indexer caps")" "jackett: an unreadable fixture is not an empty fixture"

# Given a fixture that lists no indexers
STUB_JK_IDS="NONE"

# When the assertion runs
out=$(verdicts assert_jackett_configured)

# Then the caps checks are an explicit SKIP
assert_eq "1" "$(verdict_count "$out" SKIP "indexer caps checks")" "jackett: an empty fixture is an explicit SKIP"

# Given two fixture indexers where one serves caps without any category
STUB_JK_IDS="alpha beta"
STUB_JK_CAPS[alpha]="$CAPS_WITH_CATEGORIES"
STUB_JK_CAPS[beta]="$CAPS_NO_CATEGORIES"

# When the assertion runs
out=$(verdicts assert_jackett_configured)

# Then the category-less indexer fails the caps check by name
assert_eq "1" "$(verdict_count "$out" FAIL "all indexers serve Torznab caps with categories")" "jackett: caps without categories fail"
assert_contains "$out" "beta (no-categories)" "jackett: the failing indexer and reason are named"

# Given the second indexer's caps request fails outright
unset 'STUB_JK_CAPS[beta]'

# When the assertion runs
out=$(verdicts assert_jackett_configured)

# Then the failed request is a FAIL naming the indexer
assert_contains "$out" "beta (request-failed)" "jackett: a failed caps request fails by name"

# Given both indexers serve caps with categories
STUB_JK_CAPS[beta]="$CAPS_WITH_CATEGORIES"

# When the assertion runs
out=$(verdicts assert_jackett_configured)

# Then the caps check passes for both
assert_eq "1" "$(verdict_count "$out" PASS "all 2 indexers serve Torznab caps with categories")" "jackett: caps with categories pass"

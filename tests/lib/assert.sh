# tests/lib/assert.sh — pass/fail/skip helpers + counters
# Sourced by run.sh and scenarios. No side effects at source time.

: "${PASS_COUNT:=0}"
: "${FAIL_COUNT:=0}"
: "${SKIP_COUNT:=0}"
: "${CURRENT_SCENARIO:=}"
FAILED_TESTS=()

# TTY-aware colours (empty when piped to tee / CI).
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    # Part of the palette; consumed by other test modules.
    # shellcheck disable=SC2034
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1${2:+  ← $2}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("${CURRENT_SCENARIO}:$1")
}

skip() {
    echo -e "  ${YELLOW}[SKIP]${NC} $1${2:+  ($2)}"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "'$needle' not found" ;;
    esac
}

# Hits a URL and asserts response code. Runs curl via the caller's env
# (e.g. via dind_exec). Args: <url> <expected_http_code> <name>.
assert_http() {
    local url="$1" expected="$2" name="$3"
    local got
    got=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$got" == "$expected" ]]; then
        pass "$name (HTTP $got)"
    else
        fail "$name" "expected HTTP $expected, got $got for $url"
    fi
}

scenario_begin() {
    CURRENT_SCENARIO="$1"
    SCENARIO_START=$SECONDS
    echo ""
    echo -e "${CYAN}${BOLD}▶ scenario: $1${NC}"
}

scenario_end() {
    local elapsed=$((SECONDS - SCENARIO_START))
    echo -e "${CYAN}◀ $1 done in ${elapsed}s${NC}"
    CURRENT_SCENARIO=""
}

summary() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────${NC}"
    if ((FAIL_COUNT == 0)); then
        echo -e "${GREEN}${BOLD}  ${PASS_COUNT} passed, ${SKIP_COUNT} skipped (total ${total}) in ${SECONDS}s${NC}"
    else
        echo -e "${RED}${BOLD}  ${PASS_COUNT} passed, ${FAIL_COUNT} FAILED, ${SKIP_COUNT} skipped (total ${total}) in ${SECONDS}s${NC}"
        echo ""
        echo -e "${RED}  failed:${NC}"
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "${RED}    - $t${NC}"
        done
    fi
    echo -e "${BOLD}──────────────────────────────────────────${NC}"
    return $((FAIL_COUNT > 0))
}

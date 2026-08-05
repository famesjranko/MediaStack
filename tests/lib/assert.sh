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

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "'$needle' found" ;;
        *) pass "$name" ;;
    esac
}

# File-content counterparts to assert_contains/assert_not_contains: read the
# file instead of taking it as an already-captured string, for a case that
# needs a fixture file's bytes rather than a command's captured output.
assert_file_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_file_not_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file"; then
        fail "$name"
    else
        pass "$name"
    fi
}

# A caller that must prove a file was never written (a blocked accept, a
# refused write) rather than that a written file lacks some content.
assert_file_absent() {
    local file="$1" name="$2"
    if [[ -f "$file" ]]; then
        fail "$name" "$(basename "$file") exists"
    else
        pass "$name"
    fi
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

# run_cmd CMD... — runs a probed command and captures its output/exit code
# for assert_rc. RC/OUT are globals: a command substitution would run the
# probed command in a subshell and leave the caller reading a stale exit
# code. A caller with its own invocation shape (e.g. a `cd` into a fixture
# first) sets RC/OUT itself instead of calling run_cmd.
: "${RC:=0}"
: "${OUT:=}"
run_cmd() {
    OUT=$("$@" 2>&1)
    RC=$?
}

assert_rc() {
    local expected="$1" name="$2"
    if [[ "$RC" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected rc $expected, got $RC: $OUT"
    fi
}

# export_fixture_tree REPO_ROOT DEST — exports HEAD into DEST via `git
# archive`, for a gate whose population comes from `git ls-files` and needs a
# real, throwaway repository copy of the tree; the real tree is never written
# to. Fails the scenario and exits 1 if the export fails, since nothing after
# it has a tree to run the gate against.
export_fixture_tree() {
    local repo_root="$1" dest="$2"
    git -C "$repo_root" archive HEAD | tar -x -C "$dest" || {
        fail "fixture tree is exported" "git archive failed"
        summary
        exit 1
    }
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

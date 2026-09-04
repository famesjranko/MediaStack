# tests/unit/repository-safety/closing.sh
# Owns: fail-closed guard-error cases, the emptied-rule-list raise, and
# final registry/list coverage assertions (including the total check count).
# Sourced by: tests/unit/repository-safety.sh, after pattern-parity.sh.

# --- fail-closed ------------------------------------------------------------

# rc 2, not rc 1: these are guard failures, not findings.
fail_closed() {
    local name="$1"
    shift
    local out rc
    out=$(run_guard "$@")
    rc=$?
    if ((rc == 2)) && grep -q "^GUARD-ERROR${TAB}" <<<"$out"; then
        pass "fail-closed: $name"
    else
        fail "fail-closed: $name" "rc=$rc :: $out"
    fi
}

fail_closed "empty root argument" ""
fail_closed "missing root" "$FIXTURE_ROOT/absent"
mkdir -p "$FIXTURE_ROOT/not-a-repo"
printf 'x\n' >"$FIXTURE_ROOT/not-a-repo/file.txt"
fail_closed "root is not a git repository" "$FIXTURE_ROOT/not-a-repo"
mkdir -p "$FIXTURE_ROOT/empty-index"
git -C "$FIXTURE_ROOT/empty-index" init -q >/dev/null 2>&1
printf 'x\n' >"$FIXTURE_ROOT/empty-index/file.txt"
fail_closed "empty tracked population" "$FIXTURE_ROOT/empty-index"

if ((EUID == 0)); then
    skip "fail-closed: unreadable tracked file" "running as root"
else
    unread_dir="$FIXTURE_ROOT/unreadable"
    make_clean_fixture "$unread_dir"
    chmod 000 "$unread_dir/.gitignore"
    fail_closed "unreadable tracked file" "$unread_dir"
    chmod 644 "$unread_dir/.gitignore"
fi

# --- an emptied rule list raises --------------------------------------------
# require_nonempty is the difference between a narrowed pattern list and a rule
# that iterates zero times and reports success.

empty_pat_guard="$FIXTURE_ROOT/empty-patterns.py"
awk '/^SECRET_PATTERNS = \[$/ { print "SECRET_PATTERNS = []"; drop = 1; next }
     drop && /^\]$/ { drop = 0; next }
     !drop { print }' "$GUARD" >"$empty_pat_guard"
empty_pat_out=$(python3 "$empty_pat_guard" "$REPO_ROOT" 2>&1)
empty_pat_rc=$?
if ((empty_pat_rc == 2)) \
    && grep -qF "GUARD-ERROR${TAB}-${TAB}empty rule input: SECRET_PATTERNS" <<<"$empty_pat_out"; then
    pass "an emptied rule list raises rather than passes"
else
    fail "an emptied rule list raises rather than passes" \
        "rc=$empty_pat_rc :: $empty_pat_out"
fi

# --- registry coverage ------------------------------------------------------
# A rule that stops being registered, or is registered without a fixture, is
# how these gates die quietly.

EXPECTED_RULE_IDS="AGENT-PRIVATE-DIR
ANALYZER-CACHE
FORBIDDEN-TRACKED-PATH
HOST-ARTIFACT
KNOWLEDGE-GRAPH
PRIVATE-DOC-DIR
REAL-LOG
SECRET-FILE
SECRET-PATTERN
YAML-CONFIG
YAML-WORKFLOW"

EXPECTED_PATTERN_NAMES="aws-access-key-id
aws-session-key-id
azure-account-key
client-secret-assignment
dockerhub-token
github-token
gitlab-token
google-api-key
google-oauth-token
npm-token
private-key-assignment
private-key-header
private-key-header-generic
sendgrid-key
slack-token"

mapfile -t registry < <(run_guard --list-rules)
registry_sorted=$(printf '%s\n' "${registry[@]}" | sort)
exercised_sorted=$(printf '%s\n' "${EXERCISED[@]+"${EXERCISED[@]}"}" | sort -u)
if ((${#registry[@]} > 0)) && [[ "$registry_sorted" == "$exercised_sorted" ]]; then
    pass "every registered rule has a targeted bad fixture (${#registry[@]} rules)"
else
    fail "every registered rule has a targeted bad fixture" \
        "registry=$(tr '\n' ' ' <<<"$registry_sorted") exercised=$(tr '\n' ' ' <<<"$exercised_sorted")"
fi

assert_eq "$EXPECTED_RULE_IDS" "$registry_sorted" "rule registry matches the expected rule set"
# shellcheck disable=SC2154 # assigned in pattern-parity.sh, sourced before this file
assert_eq "$EXPECTED_PATTERN_NAMES" "$(printf '%s\n' "${pattern_names[@]+"${pattern_names[@]}"}" | sort)" \
    "credential pattern set matches the ported and extended list"

# The probe loops above kill a deleted entry; these set assertions also kill a
# silently added or edited one.

EXPECTED_HOST_ARTIFACTS='^config\.yml$
^docker-compose\.override\.yml$
^\.setup-result$
^\.nvidia-finalize-pending$
^\.nvidia-nvenc-unpatched$
^\.nvidia-(patch|tmp)/
^backups/
^config/(jellyfin|sonarr|radarr|seerr|unpackerr|homepage|jackett|qbittorrent|fail2ban|npm|state|wireguard|ddns-updater|bazarr|uptime-kuma|beszel)/
^tests/\.dind-state$
^tests/\.image-override-applied$
^tests/\.image-preflight-passed\.tsv$
(^|/)__pycache__/
\.pyc$'

EXPECTED_WORKTREE_PATTERNS='AGENT-PRIVATE-DIR (^|/)\.scratch/
AGENT-PRIVATE-DIR ^docs/agents/
AGENT-PRIVATE-DIR ^evidence/
AGENT-PRIVATE-DIR (^|/)\.(cursor|windsurf|codex|gemini|aider|agents|continue)/
AGENT-PRIVATE-DIR (^|/)\.aider\.
AGENT-PRIVATE-DIR ^\.claude/(skills|agents|commands|projects)/
AGENT-PRIVATE-DIR ^\.claude/settings\.local\.json$
AGENT-PRIVATE-DIR ^\.github/workflows-private/
ANALYZER-CACHE (^|/)\.ua/
ANALYZER-CACHE (^|/)\.understand-anything/
ANALYZER-CACHE (^|/)\.ua$
ANALYZER-CACHE (^|/)\.understand-anything$
KNOWLEDGE-GRAPH (^|/)knowledge[-_]graph
KNOWLEDGE-GRAPH \.kg\.json$
KNOWLEDGE-GRAPH (^|/)codebase-graph
KNOWLEDGE-GRAPH (^|/)repo-map\.json$
KNOWLEDGE-GRAPH (^|/)code-?graph\.(json|db|sqlite3?)$
PRIVATE-DOC-DIR (^|/)docs/private/
PRIVATE-DOC-DIR (^|/)\.planning/
PRIVATE-DOC-DIR (^|/)docs/plans/
REAL-LOG \.log$
REAL-LOG \.log\.[0-9]+$
REAL-LOG (^|/)logs/'

sorted_expect() { printf '%s\n' "$1" | sort; }

assert_eq "$(sorted_expect "$EXPECTED_HOST_ARTIFACTS")" "$(guard_list HOST_ARTIFACTS | sort)" \
    "host artifact list matches the expected set"
assert_eq "$(sorted_expect "$EXPECTED_WORKTREE_PATTERNS")" "$(guard_list WORKTREE_RULE_PATTERNS | sort)" \
    "worktree pattern lists match the expected set"
# shellcheck disable=SC2154 # assigned in list-coverage.sh, sourced before this file
assert_eq "$(printf '%s\n' "${secret_file_probes[@]#*|}" | sort -u)" \
    "$(guard_list SECRET_FILE_GLOBS | sort -u)" \
    "secret file glob list matches the probed set"

# One term per section, in file order, so a section that stops asserting is
# visible here rather than absorbed by a tuned constant.
# shellcheck disable=SC2154 # probe/name arrays assigned in list-coverage.sh and pattern-parity.sh, sourced before this file
expected=$((1 + 1 + ${#registry[@]} + 1 + 1 + 2 + 1 + 1 + 1 + \
    ${#host_probes[@]} + ${#secret_file_probes[@]} + ${#worktree_probes[@]} + \
    ${#pattern_names[@]} + 1 + ${#forbidden_alts[@]} + 2 + 5 + 1 + 6))
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

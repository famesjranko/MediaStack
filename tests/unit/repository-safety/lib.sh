# tests/unit/repository-safety/lib.sh
# Owns: shared fixture builders for the repository-safety suite - the guard
# invocation wrapper, rule-list reader, secret-line generator, minimal clean
# tree, and the per-rule defect injector.
# Sourced by: tests/unit/repository-safety.sh, after tests/lib/assert.sh.

GUARD="$REPO_ROOT/tests/lib/repo_guard.py"
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

# shellcheck disable=SC2034 # appended to by every sibling topic file, sourced after this one
EXERCISED=()
# shellcheck disable=SC2034 # used by core-rules.sh and list-coverage.sh, sourced after this one
TAB=$'\t'

run_guard() { python3 "$GUARD" "$@" 2>&1; }

# Rule lists are read back out of the guard module, so an EXPECTED_* mismatch
# means the guard changed rather than the reader.
guard_list() {
    python3 - "$GUARD" "$1" <<'PYEOF'
import runpy, sys
value = runpy.run_path(sys.argv[1])[sys.argv[2]]
if isinstance(value, dict):
    for key in sorted(value):
        for item in value[key]:
            print("%s %s" % (key, item))
else:
    for item in value:
        print(item if isinstance(item, str) else item[0])
PYEOF
}

# Fixture secrets are assembled from adjacent quoted halves so this file never
# contains a literal its own SECRET-PATTERN rule would match.
secret_line() {
    case "$1" in
        private-key-header) printf -- '%s RSA PRIVATE KEY-----' "-----BEGIN" ;;
        google-api-key) printf 'key=%s%s' "AIza" "EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE" ;;
        google-oauth-token) printf 'tok=%s%s' "ya29." "EXAMPLE-NOT-A-REAL-TOKEN" ;;
        aws-access-key-id) printf 'id=%s%s' "AKIA" "EXAMPLEEXAMPLE00" ;;
        github-token) printf 'tok=%s%s' "ghp_" "EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE" ;;
        slack-token) printf 'tok=%s%s' "xoxb-" "0000-EXAMPLE-NOT-REAL" ;;
        client-secret-assignment) printf '%s: %s' "client_secret" "EXAMPLE-NOT-REAL" ;;
        private-key-assignment) printf '%s: %s' "private_key" "EXAMPLE-NOT-REAL" ;;
        private-key-header-generic) printf -- '%s PGP PRIVATE KEY BLOCK-----' "-----BEGIN" ;;
        aws-session-key-id) printf 'id=%s%s' "ASIA" "EXAMPLEEXAMPLE00" ;;
        gitlab-token) printf 'tok=%s%s' "glpat-" "EXAMPLEEXAMPLEEXAMPLE" ;;
        azure-account-key) printf 'k=%s%s' "AccountKey=" "EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE" ;;
        sendgrid-key) printf 'k=%s%s' "SG." "EXAMPLEEXAMPLEEXAMPLE.EXAMPLEEXAMPLEEXAMPLE" ;;
        dockerhub-token) printf 'tok=%s%s' "dckr_pat_" "EXAMPLEEXAMPLEEXAMPLE" ;;
        npm-token) printf 'tok=%s%s' "npm_" "EXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEX" ;;
        *) return 1 ;;
    esac
}

# The minimum tree that satisfies every custody and YAML rule; each bad
# fixture is this plus exactly one defect.
make_clean_fixture() {
    local dir="$1"
    mkdir -p "$dir/config/examples" "$dir/.github/workflows" "$dir/tests"
    printf '# fixture repo\n' >"$dir/README.md"
    printf 'MIT placeholder\n' >"$dir/LICENSE"
    printf '.env\ndocker-compose.override.yml\n/config.yml\nbackups/\nconfig/state/\n.tmp/\n__pycache__/\n' \
        >"$dir/.gitignore"
    printf 'services: {}\n' >"$dir/docker-compose.yml"
    printf 'PUID=1000\n' >"$dir/.env.example"
    printf 'general:\n  timezone: UTC\n' >"$dir/config/examples/config.yml"
    printf 'name: ci\non: [push]\n' >"$dir/.github/workflows/ci.yml"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" add README.md LICENSE .gitignore docker-compose.yml .env.example \
        config/examples/config.yml .github/workflows/ci.yml \
        >/dev/null 2>&1
}

apply_defect() {
    local rule="$1" dir="$2"
    case "$rule" in
        FORBIDDEN-TRACKED-PATH)
            printf 'notes\n' >"$dir/CONTEXT.md"
            git -C "$dir" add CONTEXT.md >/dev/null 2>&1
            ;;
        HOST-ARTIFACT)
            printf 'services: {}\n' >"$dir/docker-compose.override.yml"
            git -C "$dir" add -f docker-compose.override.yml >/dev/null 2>&1
            ;;
        SECRET-FILE)
            mkdir -p "$dir/certs"
            printf 'placeholder\n' >"$dir/certs/server.key"
            git -C "$dir" add certs/server.key >/dev/null 2>&1
            ;;
        SECRET-PATTERN)
            mkdir -p "$dir/notes"
            {
                secret_line aws-access-key-id
                printf '\n'
            } >"$dir/notes/sample.txt"
            git -C "$dir" add notes/sample.txt >/dev/null 2>&1
            ;;
        PRIVATE-DOC-DIR)
            mkdir -p "$dir/docs/private"
            printf 'internal\n' >"$dir/docs/private/notes.md"
            ;;
        ANALYZER-CACHE)
            printf '.ua/\n' >>"$dir/.gitignore"
            mkdir -p "$dir/.ua"
            printf '{}\n' >"$dir/.ua/index.json"
            ;;
        KNOWLEDGE-GRAPH)
            mkdir -p "$dir/docs"
            printf '{}\n' >"$dir/docs/knowledge-graph.json"
            ;;
        AGENT-PRIVATE-DIR)
            mkdir -p "$dir/.scratch"
            printf 'plan\n' >"$dir/.scratch/plan.md"
            ;;
        REAL-LOG)
            printf 'boot\n' >"$dir/install.log"
            ;;
        YAML-CONFIG)
            printf 'general: [unclosed\n' >"$dir/config/examples/config.yml"
            ;;
        YAML-WORKFLOW)
            printf 'name: [unclosed\n' >"$dir/.github/workflows/ci.yml"
            ;;
        *) return 1 ;;
    esac
}

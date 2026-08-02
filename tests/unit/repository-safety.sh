#!/usr/bin/env bash
# tests/unit/repository-safety.sh
#
# Fixture proof for tests/lib/repo_guard.py, the repository publication-safety
# guard: forbidden private artifacts, tracked host artifacts, secret files and
# credential patterns, and config/workflow YAML validity.
# Pure bash + python3 + git — no Docker, no network.
#
# Every rule gets one clean and one targeted bad fixture built in a temp git
# repo, so no fixture touches the real tree. The real-tree check always scans
# REPO_ROOT and takes no override — a redirectable scan root is a channel for
# masking the one check that covers what actually ships.
#
# Every entry of every rule list is exercised by its own probe path and pinned
# by an EXPECTED_* set assertion, so deleting one turns this suite red.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="repository-safety"
scenario_begin "$CURRENT_SCENARIO"

GUARD="$REPO_ROOT/tests/lib/repo_guard.py"
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

EXERCISED=()
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

# --- the real tree ----------------------------------------------------------

real_out=$(run_guard "$REPO_ROOT")
real_rc=$?
if ((real_rc == 0)) && [[ -z "$real_out" ]]; then
    pass "sanitized tree passes every rule"
else
    fail "sanitized tree passes every rule" "rc=$real_rc :: $real_out"
fi

# --- clean fixture ----------------------------------------------------------

make_clean_fixture "$FIXTURE_ROOT/clean"
clean_out=$(run_guard "$FIXTURE_ROOT/clean")
clean_rc=$?
if ((clean_rc == 0)) && [[ -z "$clean_out" ]]; then
    pass "clean fixture passes every rule"
else
    fail "clean fixture passes every rule" "rc=$clean_rc :: $clean_out"
fi

# --- one targeted bad fixture per rule --------------------------------------

check_rule() {
    local rule="$1" dir="$FIXTURE_ROOT/bad-$1"
    make_clean_fixture "$dir"
    apply_defect "$rule" "$dir" || {
        fail "$rule: fixture builds" "no defect recipe"
        return
    }
    # Recorded only on a wired defect recipe, so a registered rule left
    # without a case in apply_defect drops out of exercised_sorted below.
    EXERCISED+=("$rule")

    local out rc others
    out=$(run_guard "$dir")
    rc=$?
    if ((rc != 1)); then
        fail "$rule: bad fixture exits 1" "rc=$rc :: $out"
        return
    fi
    if ! grep -q "^$rule${TAB}" <<<"$out"; then
        fail "$rule: bad fixture fails for its own rule" "$out"
        return
    fi
    others=$(cut -f1 <<<"$out" | sort -u | grep -vx "$rule")
    if [[ -n "$others" ]]; then
        fail "$rule: bad fixture is targeted" "also tripped: $others"
        return
    fi
    pass "$rule: bad fixture exits 1 for its own rule only"
}

while read -r rule; do
    [[ -n "$rule" ]] && check_rule "$rule"
done < <(run_guard --list-rules)

# --- gitignored + untracked analyzer cache ----------------------------------
# git ls-files cannot see it, so this is the rule that proves the guard reads
# the working tree and not just the index.

ua_dir="$FIXTURE_ROOT/bad-ANALYZER-CACHE"
if [[ -d "$ua_dir/.ua" ]]; then
    ua_tracked=$(git -C "$ua_dir" ls-files | grep -c '^\.ua/')
    ua_ignored=$(git -C "$ua_dir" check-ignore .ua/index.json 2>/dev/null)
    ua_out=$(run_guard "$ua_dir")
    if [[ "$ua_tracked" == "0" && -n "$ua_ignored" ]] && grep -q "^ANALYZER-CACHE${TAB}\.ua/index\.json" <<<"$ua_out"; then
        pass "gitignored and untracked .ua/ is rejected"
    else
        fail "gitignored and untracked .ua/ is rejected" "tracked=$ua_tracked ignored=$ua_ignored :: $ua_out"
    fi
else
    fail "gitignored and untracked .ua/ is rejected" "fixture missing"
fi

# --- bare-file analyzer cache -----------------------------------------------
# ANALYZER-CACHE also matches the non-directory shape: os.walk only trailing-
# slashes entries it puts in dirnames, so a regular file (or symlink-to-file)
# named .ua needs its own pattern, not just the directory one.

bare_ua_dir="$FIXTURE_ROOT/bare-ua-file"
make_clean_fixture "$bare_ua_dir"
printf 'hi\n' >"$bare_ua_dir/.ua"
bare_ua_out=$(run_guard "$bare_ua_dir")
bare_ua_rc=$?
if ((bare_ua_rc == 1)) && grep -qF "ANALYZER-CACHE${TAB}.ua${TAB}rule=analyzer-cache" <<<"$bare_ua_out"; then
    pass "a regular file named .ua is rejected"
else
    fail "a regular file named .ua is rejected" "rc=$bare_ua_rc :: $bare_ua_out"
fi

# --- symlinked private directories ------------------------------------------
# os.walk never descends a symlinked directory, so a rule that only tests
# filenames misses a .ua pointed at an external cache — the obvious way to
# keep a multi-megabyte analyzer cache out of the tree's disk usage.

sym_dir="$FIXTURE_ROOT/symlink"
sym_target="$FIXTURE_ROOT/symlink-target"
make_clean_fixture "$sym_dir"
mkdir -p "$sym_target/ua" "$sym_target/private" "$sym_dir/docs"
printf '{}\n' >"$sym_target/ua/index.json"
printf 'internal\n' >"$sym_target/private/notes.md"
ln -s "$sym_target/ua" "$sym_dir/.ua"
ln -s "$sym_target/private" "$sym_dir/docs/private"
sym_out=$(run_guard "$sym_dir")
for probe in "ANALYZER-CACHE|.ua/" "PRIVATE-DOC-DIR|docs/private/"; do
    rule="${probe%%|*}"
    path="${probe#*|}"
    if grep -qF "${rule}${TAB}${path}${TAB}rule=" <<<"$sym_out"; then
        pass "symlinked private directory is rejected: $path"
    else
        fail "symlinked private directory is rejected: $path" "$sym_out"
    fi
done

# --- a live install is not a finding ----------------------------------------
# MediaStack installs in-place in its own clone: setup writes fail2ban
# placeholder logs and TLS material into the gitignored config/<svc>/ dirs and
# clones nvidia-patch into the tree. None of that may fire a rule.

live_dir="$FIXTURE_ROOT/live-install"
make_clean_fixture "$live_dir"
mkdir -p "$live_dir/config/jellyfin/log" "$live_dir/config/npm/data/logs" \
    "$live_dir/config/npm/letsencrypt/live/example" "$live_dir/config/seerr/logs" \
    "$live_dir/.nvidia-patch/.git/logs" "$live_dir/vendor/dep/.git/logs"
: >"$live_dir/config/jellyfin/log/log_.log"
: >"$live_dir/config/npm/data/logs/default-host_.log"
: >"$live_dir/config/npm/data/logs/proxy-host-___.log"
: >"$live_dir/config/seerr/logs/seerr-.log"
printf 'placeholder\n' >"$live_dir/config/npm/letsencrypt/live/example/privkey.pem"
printf 'ref\n' >"$live_dir/.nvidia-patch/.git/logs/HEAD"
printf 'ref\n' >"$live_dir/vendor/dep/.git/logs/HEAD"
printf 'ok\n' >"$live_dir/.setup-result"
printf 'general: {}\n' >"$live_dir/config.yml"
live_out=$(run_guard "$live_dir")
live_rc=$?
if ((live_rc == 0)) && [[ -z "$live_out" ]]; then
    pass "simulated live install produces no findings"
else
    fail "simulated live install produces no findings" "rc=$live_rc :: $live_out"
fi

# --- an untracked private key is still a finding ----------------------------

untracked_dir="$FIXTURE_ROOT/untracked-key"
make_clean_fixture "$untracked_dir"
printf 'placeholder\n' >"$untracked_dir/id_rsa"
untracked_out=$(run_guard "$untracked_dir")
untracked_rc=$?
if ((untracked_rc == 1)) && grep -qF "SECRET-FILE${TAB}id_rsa${TAB}class=id_rsa*" <<<"$untracked_out"; then
    pass "untracked private key is rejected"
else
    fail "untracked private key is rejected" "rc=$untracked_rc :: $untracked_out"
fi

# --- per-entry proof: HOST_ARTIFACTS ----------------------------------------
# One tracked probe per list entry, and per alternative inside an entry, so
# deleting any of them drops a line the loop below demands.

host_probes=(
    "config.yml" "docker-compose.override.yml" ".setup-result"
    ".nvidia-finalize-pending" ".nvidia-nvenc-unpatched"
    ".nvidia-patch/probe.txt" ".nvidia-tmp/probe.txt" "backups/probe.txt"
    "config/jellyfin/probe.txt" "config/sonarr/probe.txt" "config/radarr/probe.txt"
    "config/seerr/probe.txt" "config/unpackerr/probe.txt" "config/homepage/probe.txt"
    "config/jackett/probe.txt" "config/qbittorrent/probe.txt"
    "config/fail2ban/probe.txt" "config/npm/probe.txt" "config/state/probe.txt"
    "config/wireguard/probe.txt" "config/ddns-updater/probe.txt"
    "config/bazarr/probe.txt" "config/uptime-kuma/probe.txt"
    "config/beszel/probe.txt"
    "tests/.dind-state" "tests/.image-override-applied"
    "tests/.image-preflight-passed.tsv" "pkg/__pycache__/probe.txt" "mod.pyc"
)
host_dir="$FIXTURE_ROOT/list-host-artifacts"
make_clean_fixture "$host_dir"
for rel in "${host_probes[@]}"; do
    mkdir -p "$host_dir/$(dirname "$rel")"
    printf 'x\n' >"$host_dir/$rel"
    git -C "$host_dir" add -f "$rel" >/dev/null 2>&1
done
host_out=$(run_guard "$host_dir")
for rel in "${host_probes[@]}"; do
    if grep -qF "HOST-ARTIFACT${TAB}${rel}${TAB}" <<<"$host_out"; then
        pass "host artifact entry is rejected: $rel"
    else
        fail "host artifact entry is rejected: $rel" "$host_out"
    fi
done

# --- per-entry proof: SECRET_FILE_GLOBS -------------------------------------
# Left untracked on purpose: the file-class rule reads the worktree.

secret_file_probes=(
    "sample.pem|*.pem" "sample.key|*.key" "sample.p12|*.p12" "sample.pfx|*.pfx"
    "sample.jks|*.jks" "sample.keystore|*.keystore" "sample.kdbx|*.kdbx"
    "sample.ovpn|*.ovpn" "sample.kubeconfig|*.kubeconfig" "sample.gpg|*.gpg"
    "sample.asc|*.asc" "sample.ppk|*.ppk"
    "id_rsa|id_rsa*" "id_dsa|id_dsa*" "id_ecdsa|id_ecdsa*" "id_ed25519|id_ed25519*"
    "secring.sample|*secring*"
    ".netrc|.netrc" ".npmrc|.npmrc" ".pypirc|.pypirc" ".htpasswd|.htpasswd"
    "authorized_keys|authorized_keys"
    "svc-service-account.json|*service-account*.json"
    "svc-service_account.json|*service_account*.json"
    "app-credentials.json|*credentials*.json"
    "app-client_secret.json|*client_secret*.json"
)
sf_dir="$FIXTURE_ROOT/list-secret-files"
make_clean_fixture "$sf_dir"
mkdir -p "$sf_dir/keys"
for probe in "${secret_file_probes[@]}"; do
    printf 'placeholder\n' >"$sf_dir/keys/${probe%%|*}"
done
sf_out=$(run_guard "$sf_dir")
for probe in "${secret_file_probes[@]}"; do
    name="${probe%%|*}"
    glob="${probe#*|}"
    if grep -qF "SECRET-FILE${TAB}keys/${name}${TAB}class=${glob}" <<<"$sf_out"; then
        pass "secret file class is rejected untracked: $glob"
    else
        fail "secret file class is rejected untracked: $glob" "$sf_out"
    fi
done

# --- per-entry proof: WORKTREE_RULE_PATTERNS --------------------------------

worktree_probes=(
    "PRIVATE-DOC-DIR|docs/private/a.md" "PRIVATE-DOC-DIR|.planning/a.md"
    "PRIVATE-DOC-DIR|public-overlay/a.md" "PRIVATE-DOC-DIR|docs/plans/a.md"
    "PRIVATE-DOC-DIR|nested/docs/private/a.md"
    "PRIVATE-DOC-DIR|nested/public-overlay/a.md"
    "PRIVATE-DOC-DIR|nested/docs/plans/a.md"
    "ANALYZER-CACHE|.ua/a.json" "ANALYZER-CACHE|.understand-anything/a.json"
    "KNOWLEDGE-GRAPH|docs/knowledge-graph.txt" "KNOWLEDGE-GRAPH|docs/knowledge_graph.txt"
    "KNOWLEDGE-GRAPH|a.kg.json" "KNOWLEDGE-GRAPH|codebase-graph.txt"
    "KNOWLEDGE-GRAPH|repo-map.json" "KNOWLEDGE-GRAPH|code-graph.json"
    "KNOWLEDGE-GRAPH|codegraph.json" "KNOWLEDGE-GRAPH|code-graph.db"
    "KNOWLEDGE-GRAPH|code-graph.sqlite" "KNOWLEDGE-GRAPH|code-graph.sqlite3"
    "AGENT-PRIVATE-DIR|.scratch/a.md" "AGENT-PRIVATE-DIR|docs/agents/a.md"
    "AGENT-PRIVATE-DIR|evidence/a.md"
    "AGENT-PRIVATE-DIR|.cursor/a.md" "AGENT-PRIVATE-DIR|.windsurf/a.md"
    "AGENT-PRIVATE-DIR|.codex/a.md" "AGENT-PRIVATE-DIR|.gemini/a.md"
    "AGENT-PRIVATE-DIR|.aider/a.md" "AGENT-PRIVATE-DIR|.agents/a.md"
    "AGENT-PRIVATE-DIR|.continue/a.md" "AGENT-PRIVATE-DIR|.aider.chat.md"
    "AGENT-PRIVATE-DIR|.claude/skills/a.md" "AGENT-PRIVATE-DIR|.claude/agents/a.md"
    "AGENT-PRIVATE-DIR|.claude/commands/a.md" "AGENT-PRIVATE-DIR|.claude/projects/a.md"
    "AGENT-PRIVATE-DIR|.claude/settings.local.json"
    "AGENT-PRIVATE-DIR|.github/workflows-private/a.yml"
    "REAL-LOG|install.log" "REAL-LOG|install.log.1" "REAL-LOG|logs/a.txt"
)
wt_dir="$FIXTURE_ROOT/list-worktree"
make_clean_fixture "$wt_dir"
for probe in "${worktree_probes[@]}"; do
    rel="${probe#*|}"
    mkdir -p "$wt_dir/$(dirname "$rel")"
    printf 'x\n' >"$wt_dir/$rel"
done
wt_out=$(run_guard "$wt_dir")
for probe in "${worktree_probes[@]}"; do
    rule="${probe%%|*}"
    rel="${probe#*|}"
    if grep -qF "${rule}${TAB}${rel}${TAB}rule=" <<<"$wt_out"; then
        pass "worktree pattern is rejected: $rule $rel"
    else
        fail "worktree pattern is rejected: $rule $rel" "$wt_out"
    fi
done

# --- every ported credential pattern still fires ----------------------------

pattern_dir="$FIXTURE_ROOT/patterns"
mapfile -t pattern_names < <(guard_list SECRET_PATTERNS)
((${#pattern_names[@]} > 0)) || fail "credential pattern list is non-empty" "SECRET_PATTERNS is empty"
for name in "${pattern_names[@]+"${pattern_names[@]}"}"; do
    dir="$pattern_dir/$name"
    make_clean_fixture "$dir"
    mkdir -p "$dir/notes"
    {
        secret_line "$name"
        printf '\n'
    } >"$dir/notes/sample.txt"
    git -C "$dir" add notes/sample.txt >/dev/null 2>&1
    out=$(run_guard "$dir")
    rc=$?
    if ((rc == 1)) && grep -q "^SECRET-PATTERN${TAB}notes/sample.txt${TAB}pattern=$name " <<<"$out"; then
        pass "credential pattern fires: $name"
    else
        fail "credential pattern fires: $name" "rc=$rc :: $out"
    fi
done

# --- the secret itself never reaches the output -----------------------------

leak_dir="$FIXTURE_ROOT/leak"
make_clean_fixture "$leak_dir"
mkdir -p "$leak_dir/notes"
leak_secret=$(secret_line aws-access-key-id)
printf '%s\n' "$leak_secret" >"$leak_dir/notes/sample.txt"
git -C "$leak_dir" add notes/sample.txt >/dev/null 2>&1
leak_out=$(run_guard "$leak_dir")
leak_value="${leak_secret#id=}"
if [[ "$leak_out" != *"$leak_value"* ]] && [[ "$leak_out" == *"notes/sample.txt"* ]]; then
    pass "secret-bearing fixture is reported without echoing the secret"
else
    fail "secret-bearing fixture is reported without echoing the secret" "$leak_out"
fi

# --- parity with the ci.yml forbidden-path regex ----------------------------
# One fixture per alternative in the ported regex, so dropping an alternative
# stops being a silent narrowing of the gate.

forbidden_alts=(
    ".env" ".envrc" "tests/.env.gcp" "private/notes.md" "docs/plans/p.md"
    ".planning/p.md" ".tmp/scratch" "CONTEXT.md" "tests/feature-plan.md"
)
for rel in "${forbidden_alts[@]}"; do
    dir="$FIXTURE_ROOT/alt-$(tr '/.' '__' <<<"$rel")"
    make_clean_fixture "$dir"
    mkdir -p "$dir/$(dirname "$rel")"
    printf 'x\n' >"$dir/$rel"
    git -C "$dir" add -f "$rel" >/dev/null 2>&1
    out=$(run_guard "$dir")
    rc=$?
    if ((rc == 1)) && grep -qF "FORBIDDEN-TRACKED-PATH${TAB}${rel}${TAB}" <<<"$out"; then
        pass "ported forbidden path is rejected: $rel"
    else
        fail "ported forbidden path is rejected: $rel" "rc=$rc :: $out"
    fi
done

# --- ported allowlists ------------------------------------------------------

allow_dir="$FIXTURE_ROOT/allow-path"
make_clean_fixture "$allow_dir"
printf 'GCP_PROJECT=example\n' >"$allow_dir/tests/.env.gcp.example"
git -C "$allow_dir" add -f tests/.env.gcp.example >/dev/null 2>&1
allow_out=$(run_guard "$allow_dir")
allow_rc=$?
if ((allow_rc == 0)) && [[ -z "$allow_out" ]]; then
    pass "ported path allowlist keeps tests/.env.gcp.example"
else
    fail "ported path allowlist keeps tests/.env.gcp.example" "rc=$allow_rc :: $allow_out"
fi

content_dir="$FIXTURE_ROOT/allow-content"
make_clean_fixture "$content_dir"
{
    secret_line aws-access-key-id
    printf '\n'
} >>"$content_dir/.env.example"
git -C "$content_dir" add .env.example >/dev/null 2>&1
content_out=$(run_guard "$content_dir")
content_rc=$?
if ((content_rc == 0)) && [[ -z "$content_out" ]]; then
    pass "ported content allowlist keeps .env.example"
else
    fail "ported content allowlist keeps .env.example" "rc=$content_rc :: $content_out"
fi

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
PRIVATE-DOC-DIR (^|/)public-overlay/
PRIVATE-DOC-DIR (^|/)docs/plans/
REAL-LOG \.log$
REAL-LOG \.log\.[0-9]+$
REAL-LOG (^|/)logs/'

sorted_expect() { printf '%s\n' "$1" | sort; }

assert_eq "$(sorted_expect "$EXPECTED_HOST_ARTIFACTS")" "$(guard_list HOST_ARTIFACTS | sort)" \
    "host artifact list matches the expected set"
assert_eq "$(sorted_expect "$EXPECTED_WORKTREE_PATTERNS")" "$(guard_list WORKTREE_RULE_PATTERNS | sort)" \
    "worktree pattern lists match the expected set"
assert_eq "$(printf '%s\n' "${secret_file_probes[@]#*|}" | sort -u)" \
    "$(guard_list SECRET_FILE_GLOBS | sort -u)" \
    "secret file glob list matches the probed set"

# One term per section, in file order, so a section that stops asserting is
# visible here rather than absorbed by a tuned constant.
expected=$((1 + 1 + ${#registry[@]} + 1 + 1 + 2 + 1 + 1 + \
    ${#host_probes[@]} + ${#secret_file_probes[@]} + ${#worktree_probes[@]} + \
    ${#pattern_names[@]} + 1 + ${#forbidden_alts[@]} + 2 + 5 + 1 + 6))
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

scenario_end "$CURRENT_SCENARIO"
summary

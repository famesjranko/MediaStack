# tests/unit/repository-safety/list-coverage.sh
# Owns: one tracked/untracked probe per HOST_ARTIFACTS, SECRET_FILE_GLOBS
# and WORKTREE_RULE_PATTERNS entry, so deleting a list entry drops a probe.
# Sourced by: tests/unit/repository-safety.sh, after core-rules.sh.

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
    "PRIVATE-DOC-DIR|docs/plans/a.md"
    "PRIVATE-DOC-DIR|nested/docs/private/a.md"
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

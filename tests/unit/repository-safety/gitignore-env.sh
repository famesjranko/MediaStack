# tests/unit/repository-safety/gitignore-env.sh
# Owns: the real .gitignore keeps every .env variant out of git while the
# committed *.example templates stay trackable.
# Sourced by: tests/unit/repository-safety.sh, before closing.sh.

# --no-index: judge the ignore rules alone, not whether a path is tracked.
env_ignored() { git -C "$REPO_ROOT" check-ignore --no-index -q -- "$1"; }

env_ignored_paths=(.env .env.bak .env.local .env.old tests/.env.gcp tests/.env.foo config/sonarr/.env.bak)
env_template_paths=(.env.example tests/.env.gcp.example tests/.env.lan-host.example)

# Given the repository's .gitignore
# When each secret-bearing .env variant path is checked
# Then every one is ignored
for path in "${env_ignored_paths[@]}"; do
    if env_ignored "$path"; then
        pass "gitignore ignores $path"
    else
        fail "gitignore ignores $path" "not ignored"
    fi
done

# Given the repository's .gitignore
# When each committed .env template path is checked
# Then none is ignored
for path in "${env_template_paths[@]}"; do
    if env_ignored "$path"; then
        fail "gitignore keeps $path trackable" "ignored"
    else
        pass "gitignore keeps $path trackable"
    fi
done

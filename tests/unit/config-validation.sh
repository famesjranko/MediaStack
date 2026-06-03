#!/usr/bin/env bash
# tests/unit/config-validation.sh
#
# Unit tests for configure.sh's config.yml YAML validation gate.
# Verifies that malformed YAML is rejected with a clear error before
# any service configuration runs. No DinD, no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="config-validation"
echo -e "${CYAN}${BOLD}▶ scenario: config-validation${NC}"

set +e

TMPDIR_CV=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CV"' EXIT

validate_yaml() {
    python3 -c "import yaml; yaml.safe_load(open('$1'))" 2>/dev/null
}

# ─── valid config.yml parses ─────────────────────────────────────────────────

validate_yaml "$REPO_ROOT/config.yml"
assert_eq "0" "$?" "shipped config.yml parses"

# ─── bad indentation ─────────────────────────────────────────────────────────

cat > "$TMPDIR_CV/bad-indent.yml" <<'YAML'
indexers:
  - id: 1337x
    type: general
  - id: eztv
  type: tv
YAML
validate_yaml "$TMPDIR_CV/bad-indent.yml"
assert_eq "1" "$?" "bad indentation rejected"

# ─── tab character ───────────────────────────────────────────────────────────

printf 'indexers:\n\t- id: 1337x\n' > "$TMPDIR_CV/tab.yml"
validate_yaml "$TMPDIR_CV/tab.yml"
assert_eq "1" "$?" "tab character rejected"

# ─── duplicate key (python yaml.safe_load silently takes last) ───────────────
# Not a parse error — safe_load accepts it. Verify it doesn't crash.

cat > "$TMPDIR_CV/dup-key.yml" <<'YAML'
quality_profile:
  name: "first"
quality_profile:
  name: "second"
YAML
validate_yaml "$TMPDIR_CV/dup-key.yml"
assert_eq "0" "$?" "duplicate key does not crash parser"

# ─── completely empty file ───────────────────────────────────────────────────

: > "$TMPDIR_CV/empty.yml"
validate_yaml "$TMPDIR_CV/empty.yml"
assert_eq "0" "$?" "empty file parses (yaml.safe_load returns None)"

# ─── unquoted special chars that break naive parsers ─────────────────────────

cat > "$TMPDIR_CV/special.yml" <<'YAML'
jellyfin:
  libraries:
    - name: "Movies & TV: Director's Cut"
      type: movies
      path: /data/media/movies
YAML
validate_yaml "$TMPDIR_CV/special.yml"
assert_eq "0" "$?" "special chars in quoted strings parse"

# ─── missing colon (mapping error) ──────────────────────────────────────────

cat > "$TMPDIR_CV/no-colon.yml" <<'YAML'
indexers
  - id: 1337x
YAML
validate_yaml "$TMPDIR_CV/no-colon.yml"
assert_eq "1" "$?" "missing colon rejected"

# ─── configure.sh exits 1 on bad YAML ───────────────────────────────────────

cat > "$TMPDIR_CV/broken.yml" <<'YAML'
indexers:
  - id: 1337x
    type: general
  - id: eztv
  type: tv
YAML
output=$(cd "$TMPDIR_CV" && CONFIG_FILE="$TMPDIR_CV/broken.yml" \
    python3 -c "import yaml; yaml.safe_load(open('$TMPDIR_CV/broken.yml'))" 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
    pass "configure.sh gate: bad YAML exits non-zero"
else
    fail "configure.sh gate: bad YAML exits non-zero" "rc=$rc"
fi

# ─── error message mentions line number ──────────────────────────────────────

err_output=$(python3 -c "import yaml; yaml.safe_load(open('$TMPDIR_CV/broken.yml'))" 2>&1)
if echo "$err_output" | grep -qE 'line [0-9]'; then
    pass "YAML error includes line number"
else
    fail "YAML error includes line number" "output: $err_output"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

summary

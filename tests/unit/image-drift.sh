#!/usr/bin/env bash
# Unit test - scripts/image-drift.py snapshot and accept flow.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="image-drift"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/previous.tsv" <<'EOF'
# MediaStack tested image digest record v1
# Update only after the matching local DinD preflight has passed.
service	image	digest	tested_at_utc	preflight
jellyfin	jellyfin/jellyfin:latest	sha256:1111111111111111111111111111111111111111111111111111111111111111	2026-01-01T00:00:00Z	scenario:fresh-install
EOF

cat > "$TMP_DIR/current.tsv" <<'EOF'
# MediaStack tested image digest record v1
# Update only after the matching local DinD preflight has passed.
service	image	digest	tested_at_utc	preflight
jellyfin	jellyfin/jellyfin:latest	sha256:2222222222222222222222222222222222222222222222222222222222222222		scenario:fresh-install
EOF

cat > "$TMP_DIR/upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint | ADR |
|---|---|---|---|---|---|
| jellyfin | latest | stable | scenario:fresh-install | test | ADR-24 |
<!-- upgrades-manifest:end -->
EOF

badges=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --readme-badges 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift README badges render exits zero"
assert_contains "$badges" "Images: Stable default" "image-drift README badges include Stable default badge"
assert_contains "$badges" "Stable refs: 1 pinned" "image-drift README badges include lock row count"
assert_contains "$badges" "Accepted: 2026-01-01" "image-drift README badges include accepted date"

cat > "$TMP_DIR/README.md" <<'EOF'
# Example

<!-- stable-image-badges:start -->
stale badges
<!-- stable-image-badges:end -->
EOF

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --write-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?
readme_text=$(cat "$TMP_DIR/README.md")

assert_eq "0" "$rc" "image-drift README badge write exits zero"
assert_contains "$output" "updated" "image-drift README badge write reports update"
assert_contains "$readme_text" "Stable refs: 1 pinned" "image-drift README badge write replaces marked block"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --check-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift README badge check exits zero when current"
assert_contains "$output" "current" "image-drift README badge check reports current"

sed -i 's/1%20pinned/2%20pinned/' "$TMP_DIR/README.md"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --check-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?

assert_eq "1" "$rc" "image-drift README badge check fails when stale"
assert_contains "$output" "out of date" "image-drift README badge check explains stale block"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --current-file "$TMP_DIR/current.tsv" \
    --snapshot-current "$TMP_DIR/snapshot.tsv" 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift snapshot exits zero with current-file"
assert_contains "$output" "snapshot written" "image-drift snapshot reports output path"
if grep -q 'sha256:2222222222222222222222222222222222222222222222222222222222222222' "$TMP_DIR/snapshot.tsv"; then
    pass "image-drift snapshot writes exact current digest"
else
    fail "image-drift snapshot writes exact current digest"
fi

accepted="$TMP_DIR/accepted.tsv"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --current-file "$TMP_DIR/snapshot.tsv" \
    --write-current "$accepted" \
    --accept-current \
    --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift accept exits zero with current-file"
assert_contains "$output" "Image drift accepted" "image-drift accept reports accepted baseline"
if grep -q $'jellyfin\tjellyfin/jellyfin:latest\tsha256:2222222222222222222222222222222222222222222222222222222222222222\t2026-06-01T00:00:00Z\tscenario:fresh-install' "$accepted"; then
    pass "image-drift accept writes exact preflighted snapshot"
else
    fail "image-drift accept writes exact preflighted snapshot"
fi

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --write-current "$TMP_DIR/unsafe.tsv" \
    --accept-current 2>&1)
rc=$?

assert_eq "1" "$rc" "image-drift accept rejects live re-resolution"
assert_contains "$output" "--accept-current requires --current-file" "image-drift accept explains current-file requirement"

scenario_end "$CURRENT_SCENARIO"
summary

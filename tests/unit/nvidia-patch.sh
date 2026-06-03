#!/usr/bin/env bash
# tests/unit/nvidia-patch.sh
#
# Pure-bash unit tests for the shared nvidia-patch pinning and verification
# helper. No network, no Docker, and no NVIDIA hardware required.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="nvidia-patch"
scenario_begin "$CURRENT_SCENARIO"

# shellcheck source=../../scripts/lib/nvidia_patch.sh
source "$REPO_ROOT/scripts/lib/nvidia_patch.sh"

set +e
set +u

log_ok()    { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_patch_repo() {
    local repo="$1"

    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.invalid"
    git -C "$repo" config user.name "MediaStack Test"
    cat > "$repo/patch.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
    printf 'compat:%s\n' "${2:-}"
    exit 0
fi
printf 'patch-run\n'
SH
    cat > "$repo/patch-fbc.sh" <<'SH'
#!/usr/bin/env bash
printf 'fbc-run\n'
SH
    printf '{"drivers":[]}\n' > "$repo/drivers.json"
    git -C "$repo" add patch.sh patch-fbc.sh drivers.json
    git -C "$repo" commit -q -m "seed nvidia patch fixture"
    git -C "$repo" remote add origin "$NVIDIA_PATCH_REPO_URL"
    git -C "$repo" rev-parse HEAD
}

repo="$TMP_ROOT/pinned"
first_commit=$(make_patch_repo "$repo")
printf 'moving branch content\n' > "$repo/moving.txt"
git -C "$repo" add moving.txt
git -C "$repo" commit -q -m "advance branch"
second_commit=$(git -C "$repo" rev-parse HEAD)
NVIDIA_PATCH_REPO_COMMIT="$first_commit"

if nvidia_patch_prepare_repo "$repo"; then
    assert_eq "$first_commit" "$(git -C "$repo" rev-parse HEAD)" "nvidia_patch_prepare_repo: checks out pinned commit"
else
    fail "nvidia_patch_prepare_repo: checks out pinned commit" "prepare failed"
fi
if [[ "$first_commit" != "$second_commit" ]]; then
    pass "nvidia_patch_prepare_repo: fixture has a moving branch to pin away from"
else
    fail "nvidia_patch_prepare_repo: fixture has a moving branch to pin away from"
fi

run_dir=$(nvidia_patch_export_run_tree "$repo")
if [[ -n "$run_dir" && -f "$run_dir/patch.sh" && -f "$run_dir/patch-fbc.sh" ]]; then
    pass "nvidia_patch_export_run_tree: exports reviewed scripts"
else
    fail "nvidia_patch_export_run_tree: exports reviewed scripts"
fi
assert_eq "compat:535.154.05" "$(bash "$run_dir/patch.sh" -c 535.154.05)" "nvidia_patch_export_run_tree: exported patch.sh is executable"
rm -rf "$run_dir"

repo="$TMP_ROOT/dirty"
dirty_commit=$(make_patch_repo "$repo")
NVIDIA_PATCH_REPO_COMMIT="$dirty_commit"
printf 'local edit\n' > "$repo/local-untracked.txt"
if nvidia_patch_prepare_repo "$repo"; then
    fail "nvidia_patch_prepare_repo: rejects dirty tree" "prepare succeeded with untracked file"
else
    pass "nvidia_patch_prepare_repo: rejects dirty tree"
fi

repo="$TMP_ROOT/wrong-origin"
origin_commit=$(make_patch_repo "$repo")
NVIDIA_PATCH_REPO_COMMIT="$origin_commit"
git -C "$repo" remote set-url origin "https://example.invalid/not-keylase.git"
if nvidia_patch_prepare_repo "$repo"; then
    fail "nvidia_patch_prepare_repo: rejects unexpected origin" "prepare succeeded with wrong origin"
else
    pass "nvidia_patch_prepare_repo: rejects unexpected origin"
fi

repo="$TMP_ROOT/wrong-head"
base_commit=$(make_patch_repo "$repo")
printf 'new content\n' > "$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit -q -m "different head"
NVIDIA_PATCH_REPO_COMMIT="$base_commit"
if nvidia_patch_export_run_tree "$repo" >/dev/null 2>&1; then
    fail "nvidia_patch_export_run_tree: rejects unverified HEAD" "export succeeded before pinned checkout"
else
    pass "nvidia_patch_export_run_tree: rejects unverified HEAD"
fi

readme_url=$(nvidia_patch_readme_url)
assert_contains "$readme_url" "$NVIDIA_PATCH_REPO_COMMIT" "nvidia_patch_readme_url: uses pinned commit"

gpu_source=$(cat "$REPO_ROOT/scripts/setup/gpu.sh")
repatch_source=$(cat "$REPO_ROOT/scripts/nvidia-repatch.sh")
assert_contains "$gpu_source" "nvidia_patch_prepare_repo" "setup GPU path uses shared verifier"
assert_contains "$repatch_source" "nvidia_patch_prepare_repo" "day-2 repatch path uses shared verifier"
if printf '%s\n%s\n' "$gpu_source" "$repatch_source" | grep -Eq 'git[[:space:]].*pull'; then
    fail "nvidia patch callers: no git pull from moving upstream"
else
    pass "nvidia patch callers: no git pull from moving upstream"
fi

scenario_end "$CURRENT_SCENARIO"
summary

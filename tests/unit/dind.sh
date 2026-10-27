#!/usr/bin/env bash
# tests/unit/dind.sh
#
# tests/lib/dind.sh: the repo copy that lands in DinD is the pristine source
# tree (tracked files plus untracked files git does not ignore) and never the
# gitignored runtime state of a live install or an earlier run, so a "fresh"
# scenario cannot inherit a completed setup. A fake `docker` on PATH extracts
# the tar stream into a scratch root; the git listing, the filter and the tar
# pipe are the real code. Pure bash + git + tar; no Docker, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="dind"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_ROOT="$TMP_DIR/dind-fs"
mkdir -p "$TMP_DIR/bin" "$FAKE_ROOT"

# --- fake docker: `docker exec [-i] [-w DIR] NAME CMD...` against FAKE_ROOT ---
cat >"$TMP_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "exec" ]] || exit 64
shift
workdir=""
while [[ "$1" == -* ]]; do
    case "$1" in
        -i) shift ;;
        -w)
            workdir="$2"
            shift 2
            ;;
        *) exit 64 ;;
    esac
done
shift # container name
case "$1 $2" in
    "mkdir -p") mkdir -p "$FAKE_ROOT$3" ;;
    "tar -xf") mkdir -p "$FAKE_ROOT$5" && tar -xf - -C "$FAKE_ROOT$5" ;;
    "test -f") test -f "$FAKE_ROOT$workdir/$3" ;;
    *) exit 64 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH" FAKE_ROOT
DIND_NAME=fake-dind

# --- fixture checkout: a throwaway repository with the real .gitignore ---
SRC="$TMP_DIR/src"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" config user.email test@example.invalid
git -C "$SRC" config user.name test
cp "$REPO_ROOT/.gitignore" "$SRC/.gitignore"
mkdir -p "$SRC/config/examples/defaults/jackett/Jackett" "$SRC/scripts" "$SRC/tests/scenarios"
printf 'services: {}\n' >"$SRC/docker-compose.yml"
printf '{}\n' >"$SRC/config/examples/defaults/jackett/Jackett/ServerConfig.json"
printf 'indexers: []\n' >"$SRC/config/examples/config.yml"
printf '# deleted later\n' >"$SRC/scripts/gone.sh"
git -C "$SRC" add -A
git -C "$SRC" commit -qm fixture
# Runtime state a live install or an earlier run leaves behind (all gitignored).
mkdir -p "$SRC/config/jellyfin/data" "$SRC/config/jackett/Jackett" "$SRC/config/state" "$SRC/tests"
printf 'JELLYFIN_API_KEY=live\n' >"$SRC/.env"
printf 'indexers: [{id: live}]\n' >"$SRC/config.yml"
printf 'services: {}\n' >"$SRC/docker-compose.override.yml"
printf 'sqlite\n' >"$SRC/config/jellyfin/data/jellyfin.db"
printf '{"APIKey":"live"}\n' >"$SRC/config/jackett/Jackett/ServerConfig.json"
printf 'svc\tpolicy\n' >"$SRC/config/state/image-policy.tsv"
printf 'row\n' >"$SRC/tests/.image-preflight-passed.tsv"
printf 'svc\told\tnew\n' >"$SRC/tests/.image-override-applied"
printf 'stage3\n' >"$SRC/.setup-result"
# An uncommitted new scenario file must travel; a deleted tracked file must not break the copy.
printf 'run_scenario() { :; }\n' >"$SRC/tests/scenarios/new-scenario.sh"
rm "$SRC/scripts/gone.sh"

# Given a checkout holding tracked sources, an uncommitted new file, a deleted
# tracked file and the gitignored runtime state of a live install
REPO_ROOT="$SRC"
# shellcheck source=tests/lib/dind.sh
source "$SCRIPT_DIR/../lib/dind.sh"
REPO_ROOT="$SRC"

# When the repo is copied into DinD
copy_out=$(dind_copy_repo 2>&1)
copy_rc=$?

# Then the copy succeeds and holds the source tree plus the new untracked file
DEST="$FAKE_ROOT/root/MediaStack"
assert_eq "0" "$copy_rc" "dind copy: succeeds on a checkout with runtime state present"
assert_eq "1" "$([[ -f "$DEST/docker-compose.yml" ]] && echo 1 || echo 0)" "dind copy: tracked docker-compose.yml is copied"
assert_eq "1" "$([[ -f "$DEST/config/examples/defaults/jackett/Jackett/ServerConfig.json" ]] && echo 1 || echo 0)" "dind copy: tracked pre-seed templates are copied"
assert_eq "1" "$([[ -f "$DEST/tests/scenarios/new-scenario.sh" ]] && echo 1 || echo 0)" "dind copy: an uncommitted new scenario file is copied"
assert_eq "0" "$([[ -e "$DEST/scripts/gone.sh" ]] && echo 1 || echo 0)" "dind copy: a tracked file deleted from the working tree is skipped"
assert_contains "$copy_out" "copied 5 source files" "dind copy: reports the copied population"

# And none of the gitignored runtime state reaches DinD
for leak in .env config.yml docker-compose.override.yml config/jellyfin/data/jellyfin.db \
    config/jackett/Jackett/ServerConfig.json config/state/image-policy.tsv \
    tests/.image-preflight-passed.tsv tests/.image-override-applied .setup-result; do
    assert_eq "0" "$([[ -e "$DEST/$leak" ]] && echo 1 || echo 0)" "dind copy: runtime state $leak is not copied"
done
assert_eq "0" "$([[ -e "$DEST/.git" ]] && echo 1 || echo 0)" "dind copy: .git is not copied"

# Given a directory that is not a git checkout
NOGIT="$TMP_DIR/nogit"
mkdir -p "$NOGIT"
printf 'services: {}\n' >"$NOGIT/docker-compose.yml"
rm -rf "$FAKE_ROOT"
mkdir -p "$FAKE_ROOT"
REPO_ROOT="$NOGIT"

# When the repo copy runs there
copy_out=$(cd "$TMP_DIR" && dind_copy_repo 2>&1)
copy_rc=$?

# Then it fails closed instead of copying an unknown population
assert_eq "1" "$copy_rc" "dind copy: a non-git directory is refused"
assert_contains "$copy_out" "git ls-files failed" "dind copy: the refusal names the cause"
assert_eq "0" "$([[ -e "$FAKE_ROOT/root/MediaStack/docker-compose.yml" ]] && echo 1 || echo 0)" "dind copy: nothing is copied from a non-git directory"

summary

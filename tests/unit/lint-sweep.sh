#!/usr/bin/env bash
# tests/unit/lint-sweep.sh — bounded roots, complete coverage and failure reporting.
# Stubbed engine calls prove the runner contract; real-engine fixtures prove
# dispatcher imports stay bounded while helper defects remain visible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="lint-sweep"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
FIXTURE_ROOT="$TMP_DIR/runner"
mkdir -p "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/tests"
git init -q "$FIXTURE_ROOT"
cp "$REPO_ROOT/tests/lint.sh" "$FIXTURE_ROOT/tests/lint.sh"
cp "$REPO_ROOT/tools.toml" "$FIXTURE_ROOT/tools.toml"
sc_version=$(awk -F' *= *' '
    /^\[/ { in_section = ($0 == "[shellcheck]"); next }
    in_section && $1 == "version" { gsub(/"/, "", $2); print $2; exit }
' "$REPO_ROOT/tools.toml")
export SWEEP_LOG="$TMP_DIR/sweep.log" SC_FIXTURE_VERSION="$sc_version"
cat >"$FIXTURE_ROOT/bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'version: %s\n' "$SC_FIXTURE_VERSION"
    exit 0
fi
printf 'CALL\n' >>"$SWEEP_LOG"
files=()
end_of_options=false
for arg in "$@"; do
    if [[ "$end_of_options" == "false" && "$arg" == "--" ]]; then
        end_of_options=true
        printf 'END-OF-OPTIONS\n' >>"$SWEEP_LOG"
    elif [[ "$end_of_options" == "false" && "$arg" == -* ]]; then
        printf 'FLAG:%s\n' "$arg" >>"$SWEEP_LOG"
    else
        files+=("$arg")
        printf 'FILE:%s\n' "$arg" >>"$SWEEP_LOG"
    fi
done
# Multiple roots must not share an engine's growing source-analysis heap.
if ((${#files[@]} != 1)); then
    echo "unbounded root set: ${#files[@]}"
    exit 2
fi
case "${files[0]}" in
    bad1.sh) echo 'finding in bad1.sh'; exit 1 ;;
    -bad.sh) echo 'finding in -bad.sh'; exit 1 ;;
    engine-error.sh) echo 'engine failed'; exit 2 ;;
esac
STUB
chmod +x "$FIXTURE_ROOT/bin/shellcheck"

run_fixture() {
    : >"$SWEEP_LOG"
    OUT=$(cd "$FIXTURE_ROOT" && PATH="$FIXTURE_ROOT/bin:$PATH" MS_TOOL_CACHE="$TMP_DIR/empty-cache" bash tests/lint.sh "$@" 2>&1)
    RC=$?
}

# Given a tracked finding precedes two clean files, including a spaced name.
for file in bad1.sh ok2.sh 'ok 3.sh'; do
    printf '#!/usr/bin/env bash\ntrue\n' >"$FIXTURE_ROOT/$file"
done
git -C "$FIXTURE_ROOT" add -- bad1.sh ok2.sh 'ok 3.sh'

# When the runner discovers the whole tracked shell population.
run_fixture

# Then each file is analysed once in isolation and findings do not skip later files.
assert_rc 1 "findings fail the complete sweep"
assert_contains "$OUT" 'finding in bad1.sh' "finding output is preserved"
assert_eq 3 "$(grep -c '^CALL$' "$SWEEP_LOG")" "each file gets its own analysis"
expected=$(printf 'FILE:%s\n' bad1.sh 'ok 3.sh' ok2.sh)
assert_eq "$expected" "$(grep '^FILE:' "$SWEEP_LOG")" "every tracked file is checked once with its name intact"
assert_eq 3 "$(grep -c '^FLAG:--severity=info$' "$SWEEP_LOG")" "every analysis retains info severity"

# Given tracked dash-prefixed shell files, including a name that resembles a flag.
for file in -bad.sh -clean.sh --severity=error.sh; do
    printf '#!/usr/bin/env bash\ntrue\n' >"$FIXTURE_ROOT/$file"
done
git -C "$FIXTURE_ROOT" add -- -bad.sh -clean.sh --severity=error.sh

# When discovery supplies those files to the engine.
run_fixture

# Then each dash-prefixed name is passed after an end-of-options marker.
assert_rc 1 "a dash-prefixed finding fails the complete sweep"
assert_contains "$OUT" 'finding in -bad.sh' "dash-prefixed finding output is preserved"
assert_eq 6 "$(grep -c '^END-OF-OPTIONS$' "$SWEEP_LOG")" "each discovered file follows end-of-options"
assert_contains "$(cat "$SWEEP_LOG")" 'FILE:-clean.sh' "a dash-prefixed clean file is linted"
assert_contains "$(cat "$SWEEP_LOG")" 'FILE:--severity=error.sh' "a flag-like filename is linted"

# Given a separate fixture with dash-prefixed files for the real pinned engine.
DASH_FIXTURE="$TMP_DIR/dash-fixture"
mkdir -p "$DASH_FIXTURE/tests"
git init -q "$DASH_FIXTURE"
cp "$REPO_ROOT/tests/lint.sh" "$DASH_FIXTURE/tests/lint.sh"
cp "$REPO_ROOT/tools.toml" "$REPO_ROOT/.shellcheckrc" "$DASH_FIXTURE/"
printf 'if\n' >"$DASH_FIXTURE/-bad.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$DASH_FIXTURE/-clean.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$DASH_FIXTURE/--severity=error.sh"
git -C "$DASH_FIXTURE" add -- -bad.sh -clean.sh --severity=error.sh

# When the complete fixture is linted by the real engine.
OUT=$(cd "$DASH_FIXTURE" && bash tests/lint.sh 2>&1)
RC=$?

# Then the finding reports its dash-prefixed filename rather than an option error.
assert_rc 1 "real engine reports a dash-prefixed finding"
assert_contains "$OUT" '-bad.sh' "real engine finding names the dash-prefixed file"

# Given the same repository contains both clean and failing files.
# When a caller selects only the spaced name and overrides severity.
run_fixture --severity=warning 'ok 3.sh'

# Then the runner checks only that file with the caller's flags.
assert_rc 0 "a clean targeted check passes"
assert_eq 'FILE:ok 3.sh' "$(grep '^FILE:' "$SWEEP_LOG")" "explicit selection keeps spaces and excludes other files"
assert_contains "$(cat "$SWEEP_LOG")" 'FLAG:--severity=warning' "severity override reaches the engine"
assert_not_contains "$(cat "$SWEEP_LOG")" 'FLAG:--severity=info' "the default severity does not override the caller"

# Given the engine cannot analyse a selected file.
printf '#!/usr/bin/env bash\ntrue\n' >"$FIXTURE_ROOT/engine-error.sh"

# When that error precedes another selected file.
run_fixture engine-error.sh 'ok 3.sh'

# Then an engine error is preserved and stops further analysis.
assert_rc 2 "engine errors retain their exit status"
assert_contains "$OUT" 'engine failed' "engine error output is preserved"
assert_eq 1 "$(grep -c '^CALL$' "$SWEEP_LOG")" "an engine error stops the sweep"

for root in mediastack setup.sh; do
    # Given a real dispatcher imports a tracked helper with a syntax error.
    ROOT_FIXTURE="$TMP_DIR/$root-fixture"
    mkdir -p "$ROOT_FIXTURE/tests" "$ROOT_FIXTURE/scripts/lib"
    git init -q "$ROOT_FIXTURE"
    cp "$REPO_ROOT/tests/lint.sh" "$ROOT_FIXTURE/tests/lint.sh"
    cp "$REPO_ROOT/tools.toml" "$REPO_ROOT/.shellcheckrc" "$REPO_ROOT/$root" "$ROOT_FIXTURE/"
    printf 'if\n' >"$ROOT_FIXTURE/scripts/lib/apt.sh"
    git -C "$ROOT_FIXTURE" add -- "$root" scripts/lib/apt.sh

    # When the dispatcher alone is analysed by the real pinned engine.
    OUT=$(cd "$ROOT_FIXTURE" && bash tests/lint.sh "$root" 2>&1)
    RC=$?

    # Then its whole-project imports are not expanded.
    assert_rc 0 "$root does not expand its imported tree"

    # Given that helper is part of the tracked shell population.
    # When the complete fixture is linted by the real pinned engine.
    OUT=$(cd "$ROOT_FIXTURE" && bash tests/lint.sh 2>&1)
    RC=$?

    # Then the helper's defect is still diagnosed directly.
    assert_rc 1 "$root helper defects fail the complete lint gate"
    assert_contains "$OUT" 'scripts/lib/apt.sh' "$root helper diagnostic names its file"
done

# Given an ordinary module imports a helper with a syntax error.
MODULE_FIXTURE="$TMP_DIR/module-fixture"
mkdir -p "$MODULE_FIXTURE/tests"
cp "$REPO_ROOT/tests/lint.sh" "$MODULE_FIXTURE/tests/lint.sh"
cp "$REPO_ROOT/tools.toml" "$REPO_ROOT/.shellcheckrc" "$MODULE_FIXTURE/"
printf 'source ./helper.sh\n' >"$MODULE_FIXTURE/module.sh"
printf 'if\n' >"$MODULE_FIXTURE/helper.sh"

# When only that module is analysed by the real pinned engine.
OUT=$(cd "$MODULE_FIXTURE" && bash tests/lint.sh module.sh 2>&1)
RC=$?

# Then source following still detects the broken dependency in module context.
assert_rc 1 "ordinary modules retain source analysis"
assert_contains "$OUT" 'SC1094' "ordinary modules report a broken sourced helper"

scenario_end "$CURRENT_SCENARIO"
summary

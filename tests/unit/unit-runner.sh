#!/usr/bin/env bash
# Prove missing commands cannot be hidden by a passing assertion summary.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin unit-runner
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Given a disposable repository with the real runner and two passing suites.
mkdir -p "$TMP_ROOT/tests/unit" "$TMP_ROOT/tests/lib" "$TMP_ROOT/bin"
cp "$REPO_ROOT/tests/unit.sh" "$TMP_ROOT/tests/unit.sh"
cp "$REPO_ROOT/tests/lib/assert.sh" "$TMP_ROOT/tests/lib/assert.sh"
cp "$REPO_ROOT/tools.toml" "$TMP_ROOT/tools.toml"
: >"$TMP_ROOT/.env.example"
printf 'pass\n' >"$TMP_ROOT/probe.py"
cat >"$TMP_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
[[ "$1:$2" == compose:--env-file ]]
SH
chmod +x "$TMP_ROOT/bin/docker"
cat >"$TMP_ROOT/tests/unit/probe.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source tests/lib/assert.sh
case "$UNIT_MISSING_MODE" in
    direct) ms_unit_fixture_missing_command || true ;;
    subshell) (ms_unit_fixture_missing_command) 2>/dev/null || true ;;
    substitution) ignored=$(ms_unit_fixture_missing_command 2>/dev/null) || true ;;
    pipeline) ms_unit_fixture_missing_command 2>/dev/null | cat; true ;;
    child) bash -c 'ms_unit_fixture_missing_command || true' 2>/dev/null ;;
    stub)
        ms_unit_fixture_missing_command() { return 127; }
        ms_unit_fixture_missing_command || true
        ;;
esac
pass 'the assertions still pass'
summary
SH
cat >"$TMP_ROOT/tests/unit/zz-following.sh" <<'SH'
#!/usr/bin/env bash
source tests/lib/assert.sh
pass 'the following suite still runs'
summary
SH
git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" add -- tests/unit.sh tests/lib/assert.sh tests/unit/probe.sh \
    tests/unit/zz-following.sh tools.toml .env.example probe.py

for mode in clean stub direct subshell substitution pipeline child; do
    # Given a successful suite, a deliberate failing stub, or a swallowed missing command.
    # When the complete host runner checks that suite with expensive tiers excluded.
    run_cmd env MS_UNIT_SKIP_SHELLCHECK=1 MS_UNIT_SKIP_MYPY=1 UNIT_MISSING_MODE="$mode" \
        PATH="$TMP_ROOT/bin:$PATH" bash "$TMP_ROOT/tests/unit.sh"

    # Then only an actual missing command fails the runner and every suite still runs.
    case "$mode" in
        clean | stub) assert_rc 0 "unit runner accepts $mode" ;;
        *)
            assert_rc 1 "unit runner rejects a missing command in $mode"
            assert_contains "$OUT" 'ms_unit_fixture_missing_command' "unit runner names the missing command in $mode"
            assert_contains "$OUT" 'stub the dependency' "unit runner explains the repair in $mode"
            ;;
    esac
    assert_contains "$OUT" 'the following suite still runs' "unit runner continues after $mode"
done

summary

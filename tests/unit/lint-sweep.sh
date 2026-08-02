#!/usr/bin/env bash
# tests/unit/lint-sweep.sh
#
# Single-sweep contract for tests/lint.sh: ShellCheck is invoked exactly once
# over the whole discovered file list, and a non-zero result still propagates.
# ShellCheck 0.11.0 analyses each root once however many share an invocation,
# so batching buys no peak-memory reduction — only per-process startup cost,
# which is the whole reason the sweep is one call.
#
# Runs against a fixture repo with a stub shellcheck. Pure bash + git, no
# Docker and no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="lint-sweep"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_ROOT="$TMP_DIR/lint-fixture"
mkdir -p "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/tests"
git init -q "$FIXTURE_ROOT"
for f in bad1.sh ok2.sh ok3.sh; do
    printf '#!/usr/bin/env bash\ntrue\n' >"$FIXTURE_ROOT/$f"
done
git -C "$FIXTURE_ROOT" add bad1.sh ok2.sh ok3.sh
cp "$REPO_ROOT/tests/lint.sh" "$FIXTURE_ROOT/tests/lint.sh"
chmod +x "$FIXTURE_ROOT/tests/lint.sh"

sc_version="$(sed -n 's/^SC_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/tests/lint.sh")"
SWEEP_LOG="$FIXTURE_ROOT/sweep.log"
export SWEEP_LOG
: >"$SWEEP_LOG"
cat >"$FIXTURE_ROOT/bin/shellcheck" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { printf 'version: %s\n' "$sc_version"; exit 0; }
echo "\$*" >>"\$SWEEP_LOG"
case " \$* " in
    *" bad1.sh "*) echo "FAIL:bad1.sh"; exit 1 ;;
    *) echo "OK:\$*"; exit 0 ;;
esac
STUB
chmod +x "$FIXTURE_ROOT/bin/shellcheck"

# The stub shellcheck shadows the real one via PATH order; every other tool
# (git, bash itself, coreutils) still resolves from the real PATH behind it.
fixture_out=$(cd "$FIXTURE_ROOT" && PATH="$FIXTURE_ROOT/bin:$PATH" SWEEP_LOG="$SWEEP_LOG" bash tests/lint.sh --severity=warning 2>&1)
fixture_rc=$?
if ((fixture_rc != 0)); then
    pass "a failing sweep propagates non-zero"
else
    fail "a failing sweep propagates non-zero" "exit 0; output: $fixture_out"
fi
assert_contains "$fixture_out" "FAIL:bad1.sh" "the sweep's own failure output is present"

sweep_calls=$(wc -l <"$SWEEP_LOG")
if ((sweep_calls == 1)); then
    pass "shellcheck is invoked exactly once over the whole file list"
else
    fail "shellcheck is invoked exactly once over the whole file list" \
        "invoked $sweep_calls times: $(cat "$SWEEP_LOG")"
fi
sweep_args=$(cat "$SWEEP_LOG")
assert_contains "$sweep_args" "bad1.sh" "the single sweep covers bad1.sh"
assert_contains "$sweep_args" "ok2.sh" "the single sweep covers ok2.sh"
assert_contains "$sweep_args" "ok3.sh" "the single sweep covers ok3.sh"

scenario_end "$CURRENT_SCENARIO"
summary

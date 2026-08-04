#!/usr/bin/env bash
# tests/unit/check-wrapper.sh
#
# Interface-level coverage for the canonical check wrapper's Python selectors.
# A stub uv records the exact tool argv, so these fixtures prove discovery and
# config guards without downloading tools or testing private shell functions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="check-wrapper"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

make_fixture() {
    local name="$1" config_mode="${2:-valid}"
    FIXTURE_ROOT="$TMP_DIR/$name"
    mkdir -p "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/tests"
    cp "$REPO_ROOT/tests/check.sh" "$FIXTURE_ROOT/tests/check.sh"
    chmod +x "$FIXTURE_ROOT/tests/check.sh"
    git init -q "$FIXTURE_ROOT"

    case "$config_mode" in
        valid)
            printf '%s\n' \
                '[tool.mypy]' \
                'python_version = "3.9"' \
                'check_untyped_defs = true' \
                'disallow_untyped_defs = true' >"$FIXTURE_ROOT/pyproject.toml"
            ;;
        missing-check-untyped)
            printf '%s\n' \
                '[tool.mypy]' \
                'python_version = "3.9"' >"$FIXTURE_ROOT/pyproject.toml"
            ;;
        missing-disallow-untyped)
            printf '%s\n' \
                '[tool.mypy]' \
                'python_version = "3.9"' \
                'check_untyped_defs = true' >"$FIXTURE_ROOT/pyproject.toml"
            ;;
        weakened-disallow-untyped)
            printf '%s\n' \
                '[tool.mypy]' \
                'python_version = "3.9"' \
                'check_untyped_defs = true' \
                'disallow_untyped_defs = false' >"$FIXTURE_ROOT/pyproject.toml"
            ;;
    esac

    printf '%s\n' \
        '[mypy]' \
        'version = "1.20.2"' \
        'types_pyyaml_version = "6.0.12.20260724"' \
        '[ruff]' \
        'version = "0.15.22"' >"$FIXTURE_ROOT/tools.toml"

    UV_LOG="$FIXTURE_ROOT/uv.log"
    : >"$UV_LOG"
    export UV_LOG
    cat >"$FIXTURE_ROOT/bin/uv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UV_LOG"
exit 0
STUB
    chmod +x "$FIXTURE_ROOT/bin/uv"
    git -C "$FIXTURE_ROOT" add tests/check.sh pyproject.toml tools.toml
}

add_python_file() {
    printf '%s\n' 'value = 1' >"$FIXTURE_ROOT/sample.py"
    git -C "$FIXTURE_ROOT" add sample.py
}

run_selector() {
    local selector="$1"
    SELECTOR_OUT=$(cd "$FIXTURE_ROOT" && PATH="$FIXTURE_ROOT/bin:$PATH" bash tests/check.sh "$selector" 2>&1)
    SELECTOR_RC=$?
}

make_fixture valid-ruff
add_python_file
run_selector ruff
if ((SELECTOR_RC == 0)); then
    pass "ruff selector accepts a non-empty tracked Python population"
else
    fail "ruff selector accepts a non-empty tracked Python population" "exit $SELECTOR_RC: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "== [ruff] python: ruff ==" "ruff keeps its public stage label"
mapfile -t uv_calls <"$UV_LOG"
assert_eq "2" "${#uv_calls[@]}" "ruff runs lint then format exactly once"
assert_eq "tool run ruff@0.15.22 check sample.py" "${uv_calls[0]:-}" "ruff lint receives the tracked file list"
assert_eq "tool run ruff@0.15.22 format --check sample.py" "${uv_calls[1]:-}" "ruff format receives the same tracked file list"

make_fixture valid-mypy
add_python_file
run_selector mypy
if ((SELECTOR_RC == 0)); then
    pass "mypy selector accepts the required config and tracked population"
else
    fail "mypy selector accepts the required config and tracked population" "exit $SELECTOR_RC: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "== [mypy] type: mypy ==" "mypy keeps its public stage label"
mypy_call=$(cat "$UV_LOG")
assert_contains "$mypy_call" "mypy --python-version 3.9 sample.py" "mypy explicitly enforces the Python 3.9 floor over tracked files"

for selector in ruff mypy; do
    make_fixture "empty-$selector"
    run_selector "$selector"
    if ((SELECTOR_RC != 0)); then
        pass "$selector rejects an empty tracked Python population"
    else
        fail "$selector rejects an empty tracked Python population" "exit 0: $SELECTOR_OUT"
    fi
    assert_contains "$SELECTOR_OUT" "python population empty" "$selector explains the empty-population failure"
    assert_eq "" "$(cat "$UV_LOG")" "$selector rejects emptiness before invoking uv"
done

make_fixture missing-mypy-config missing-check-untyped
add_python_file
run_selector mypy
if ((SELECTOR_RC != 0)); then
    pass "mypy rejects removal of check_untyped_defs"
else
    fail "mypy rejects removal of check_untyped_defs" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "config missing check_untyped_defs" "mypy explains the config-contract failure"
assert_eq "" "$(cat "$UV_LOG")" "mypy rejects weakened config before invoking uv"

for config_mode in missing-disallow-untyped weakened-disallow-untyped; do
    make_fixture "$config_mode" "$config_mode"
    add_python_file
    run_selector mypy
    if ((SELECTOR_RC != 0)); then
        pass "mypy rejects $config_mode"
    else
        fail "mypy rejects $config_mode" "exit 0: $SELECTOR_OUT"
    fi
    assert_contains "$SELECTOR_OUT" "config missing disallow_untyped_defs" "$config_mode explains the strict config-contract failure"
    assert_eq "" "$(cat "$UV_LOG")" "$config_mode never reaches uv"
done

make_fixture missing-pin
add_python_file
printf '%s\n' '[mypy]' 'version = "1.20.2"' >"$FIXTURE_ROOT/tools.toml"
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "ruff fails closed when tools.toml lacks its pin"
else
    fail "ruff fails closed when tools.toml lacks its pin" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "pin 'version' missing from tools.toml [ruff]" "the missing pin is named"
assert_eq "" "$(cat "$UV_LOG")" "a missing pin never reaches uv"

make_fixture failed-discovery
add_python_file
real_git=$(command -v git)
cat >"$FIXTURE_ROOT/bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-files" ]]; then
    printf 'sample.py\\0'
    printf 'synthetic discovery failure\\n' >&2
    exit 42
fi
exec "$real_git" "\$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/git"
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "ruff rejects a partial listing from failed discovery"
else
    fail "ruff rejects a partial listing from failed discovery" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "python file discovery failed" "discovery failure is distinct from an empty population"
assert_contains "$SELECTOR_OUT" "synthetic discovery failure" "discovery stderr is preserved"
assert_eq "" "$(cat "$UV_LOG")" "failed discovery never reaches uv"

scenario_end "$CURRENT_SCENARIO"
summary

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
    mkdir -p "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/tests/lib"
    cp "$REPO_ROOT/tests/check.sh" "$FIXTURE_ROOT/tests/check.sh"
    cp "$REPO_ROOT/tests/python-complexity.sh" "$FIXTURE_ROOT/tests/python-complexity.sh"
    cp "$REPO_ROOT/tests/lib/ratchet.sh" "$FIXTURE_ROOT/tests/lib/ratchet.sh"
    chmod +x "$FIXTURE_ROOT/tests/check.sh" "$FIXTURE_ROOT/tests/python-complexity.sh"
    # -b trunk: deterministic default-branch name, independent of the host's
    # init.defaultBranch, so a scenario that also creates a local "main" ref
    # (the two-commit-smuggle probe below) is never accidentally on it.
    git init -q -b trunk "$FIXTURE_ROOT"

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
    UV_FINDINGS=""
    export UV_LOG UV_FINDINGS
    # The stub replays a canned ruff findings file on the lint invocation only,
    # so the C901 reconcile can be driven without running ruff.
    cat >"$FIXTURE_ROOT/bin/uv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UV_LOG"
if [[ "$*" == *" check "* && -n "${UV_FINDINGS:-}" && -r "$UV_FINDINGS" ]]; then
    cat "$UV_FINDINGS"
fi
exit 0
STUB
    chmod +x "$FIXTURE_ROOT/bin/uv"
    git -C "$FIXTURE_ROOT" add tests/check.sh tests/python-complexity.sh tests/lib/ratchet.sh \
        pyproject.toml tools.toml
}

# One C901 finding in ruff's concise format, for the given function/complexity.
set_findings() {
    UV_FINDINGS="$FIXTURE_ROOT/ruff-findings"
    printf '%s\n' "$@" >"$UV_FINDINGS"
    export UV_FINDINGS
}

set_allowlist() {
    printf '%s\n' "$@" >"$FIXTURE_ROOT/tests/python-complexity.allowlist"
}

# Two commits so the ratchet's baseline (tests/lib/ratchet.sh) resolves to
# real content: no origin/main or local main exists in this throwaway repo, so
# it falls back to HEAD^.
commit_fixture() {
    git -C "$FIXTURE_ROOT" add -A
    git -C "$FIXTURE_ROOT" -c user.email=gate@example.invalid -c user.name=gate \
        commit -qm baseline
    git -C "$FIXTURE_ROOT" -c user.email=gate@example.invalid -c user.name=gate \
        commit -q --allow-empty -m head
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
assert_eq "tool run ruff@0.15.22 check --output-format=concise sample.py" "${uv_calls[0]:-}" "ruff lint receives the tracked file list"
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

# --- C901 complexity reconcile ------------------------------------------------
#
# The reconcile owns the failure text, so these fixtures assert the steering
# paragraph and its doc pointer, not just the exit code.

STEER_HINT="complexity is a symptom, diagnose it before you decompose"
DOC_HINT="docs/conventions.md 'Complexity cap'"
RUFF_C901="sample.py:1:5: C901 \`grown\` is too complex (11 > 10)"

make_fixture c901-new-offender
add_python_file
set_findings "$RUFF_C901" "Found 1 error."
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "ruff fails on a C901 finding that is not allowlisted"
else
    fail "ruff fails on a C901 finding that is not allowlisted" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "$RUFF_C901" "ruff's own C901 message survives the reconcile"
assert_contains "$SELECTOR_OUT" "$STEER_HINT" "the steering paragraph is appended"
assert_contains "$SELECTOR_OUT" "too many responsibilities" "the steering paragraph names the three causes"
assert_contains "$SELECTOR_OUT" "$DOC_HINT" "the steering paragraph points at the conventions section"

make_fixture c901-grandfathered
add_python_file
set_findings "$RUFF_C901"
set_allowlist "$(printf 'sample.py\tgrown\t11')"
run_selector ruff
if ((SELECTOR_RC == 0)); then
    pass "an allowlisted function at its recorded complexity passes"
else
    fail "an allowlisted function at its recorded complexity passes" "exit $SELECTOR_RC: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "1 grandfathered functions" "the reconcile reports the grandfathered count"

make_fixture c901-all-clean
add_python_file
set_findings "All checks passed!"
run_selector ruff
if ((SELECTOR_RC == 0)); then
    pass "a fully clean tree with no allowlist passes the reconcile"
else
    fail "a fully clean tree with no allowlist passes the reconcile" "exit $SELECTOR_RC: $SELECTOR_OUT"
fi

make_fixture c901-grown
add_python_file
set_findings "sample.py:1:5: C901 \`grown\` is too complex (12 > 10)"
set_allowlist "$(printf 'sample.py\tgrown\t11')"
commit_fixture
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "a grandfathered function that grew past its recorded value fails"
else
    fail "a grandfathered function that grew past its recorded value fails" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "$STEER_HINT" "growth past the recorded value gets the steering paragraph"

make_fixture c901-stale-entry
add_python_file
set_allowlist "$(printf 'sample.py\tgone\t11')"
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "an allowlist entry whose function now conforms is stale and fails"
else
    fail "an allowlist entry whose function now conforms is stale and fails" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "stale allowlist entry" "the stale entry is named"

make_fixture c901-new-entry
add_python_file
set_allowlist "$(printf 'sample.py\tgrown\t11')"
set_findings "$RUFF_C901"
commit_fixture
set_allowlist "$(printf 'sample.py\tgrown\t11')" "$(printf 'sample.py\tfresh\t11')"
set_findings "$RUFF_C901" "sample.py:9:5: C901 \`fresh\` is too complex (11 > 10)"
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "a new allowlist entry against a tracked baseline is refused"
else
    fail "a new allowlist entry against a tracked baseline is refused" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "new allowlist entry is not permitted" "the refused entry is named"

make_fixture c901-suppression
printf '%s\n' 'def wide():  # noqa: C901' '    return 1' >"$FIXTURE_ROOT/sample.py"
git -C "$FIXTURE_ROOT" add sample.py
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "a C901 suppression in tracked python is refused"
else
    fail "a C901 suppression in tracked python is refused" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "carries a C901 suppression; suppression is not the fix" "the suppression refusal says suppression is not the fix"
assert_contains "$SELECTOR_OUT" "$DOC_HINT" "the suppression refusal points at the conventions section"

make_fixture c901-bare-noqa
printf '%s\n' 'import os  # noqa' 'value = os' >"$FIXTURE_ROOT/sample.py"
git -C "$FIXTURE_ROOT" add sample.py
run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "a bare un-scoped noqa in tracked python is refused"
else
    fail "a bare un-scoped noqa in tracked python is refused" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "carries a bare un-scoped noqa" "the bare-noqa refusal names what it found"

make_fixture c901-scoped-noqa
printf '%s\n' 'import os  # noqa: E402  (legitimate, scoped)' 'value = os' >"$FIXTURE_ROOT/sample.py"
git -C "$FIXTURE_ROOT" add sample.py
run_selector ruff
if ((SELECTOR_RC == 0)); then
    pass "a scoped suppression of another rule still passes"
else
    fail "a scoped suppression of another rule still passes" "exit $SELECTOR_RC: $SELECTOR_OUT"
fi

# --- ratchet baseline is the merge-base with main, not HEAD^ -----------------
#
# A new allowlist entry smuggled in across two commits must still be caught:
# comparing only against HEAD^ (the second of the two smuggle commits) would
# see the entry already present there and wave it through. The merge-base
# with a real "main" ref catches it regardless of how many commits it took.

make_fixture c901-two-commit-smuggle
add_python_file
# An allowlist must already exist at the baseline for "no new entries" to be
# the rule being tested — an allowlist created for the first time is a
# separate, legitimate case (recorded value must just match current).
: >"$FIXTURE_ROOT/tests/python-complexity.allowlist"
git -C "$FIXTURE_ROOT" add tests/python-complexity.allowlist
commit_fixture
# "main" is the trunk the smuggle branches from — the two commits below run
# on top of it without ever moving this ref.
git -C "$FIXTURE_ROOT" branch main HEAD

set_allowlist "$(printf 'sample.py\tgrown\t11')"
set_findings "$RUFF_C901"
git -C "$FIXTURE_ROOT" add -A
git -C "$FIXTURE_ROOT" -c user.email=gate@example.invalid -c user.name=gate \
    commit -qm "smuggle step 1: the new allowlist entry"

printf '%s\n' 'value = 2' >>"$FIXTURE_ROOT/sample.py"
git -C "$FIXTURE_ROOT" add -A
git -C "$FIXTURE_ROOT" -c user.email=gate@example.invalid -c user.name=gate \
    commit -qm "smuggle step 2: an unrelated follow-up commit"

run_selector ruff
if ((SELECTOR_RC != 0)); then
    pass "a new entry smuggled across two commits still fails"
else
    fail "a new entry smuggled across two commits still fails" "exit 0: $SELECTOR_OUT"
fi
assert_contains "$SELECTOR_OUT" "new allowlist entry is not permitted" \
    "the smuggled entry is refused, not just the second commit's diff"

scenario_end "$CURRENT_SCENARIO"
summary

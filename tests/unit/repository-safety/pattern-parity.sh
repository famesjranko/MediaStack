# tests/unit/repository-safety/pattern-parity.sh
# Owns: every credential SECRET_PATTERNS entry firing, the secret value
# never leaking into guard output, and parity with the ported ci.yml
# forbidden-path regex and its allowlists.
# Sourced by: tests/unit/repository-safety.sh, after list-coverage.sh.

# --- every ported credential pattern still fires ----------------------------

pattern_dir="$FIXTURE_ROOT/patterns"
mapfile -t pattern_names < <(guard_list SECRET_PATTERNS)
((${#pattern_names[@]} > 0)) || fail "credential pattern list is non-empty" "SECRET_PATTERNS is empty"
for name in "${pattern_names[@]+"${pattern_names[@]}"}"; do
    dir="$pattern_dir/$name"
    make_clean_fixture "$dir"
    mkdir -p "$dir/notes"
    {
        secret_line "$name"
        printf '\n'
    } >"$dir/notes/sample.txt"
    git -C "$dir" add notes/sample.txt >/dev/null 2>&1
    out=$(run_guard "$dir")
    rc=$?
    if ((rc == 1)) && grep -q "^SECRET-PATTERN${TAB}notes/sample.txt${TAB}pattern=$name " <<<"$out"; then
        pass "credential pattern fires: $name"
    else
        fail "credential pattern fires: $name" "rc=$rc :: $out"
    fi
done

# --- the secret itself never reaches the output -----------------------------

leak_dir="$FIXTURE_ROOT/leak"
make_clean_fixture "$leak_dir"
mkdir -p "$leak_dir/notes"
leak_secret=$(secret_line aws-access-key-id)
printf '%s\n' "$leak_secret" >"$leak_dir/notes/sample.txt"
git -C "$leak_dir" add notes/sample.txt >/dev/null 2>&1
leak_out=$(run_guard "$leak_dir")
leak_value="${leak_secret#id=}"
if [[ "$leak_out" != *"$leak_value"* ]] && [[ "$leak_out" == *"notes/sample.txt"* ]]; then
    pass "secret-bearing fixture is reported without echoing the secret"
else
    fail "secret-bearing fixture is reported without echoing the secret" "$leak_out"
fi

# --- parity with the ci.yml forbidden-path regex ----------------------------
# One fixture per alternative in the ported regex, so dropping an alternative
# stops being a silent narrowing of the gate.

forbidden_alts=(
    ".env" ".envrc" "tests/.env.gcp" "private/notes.md" "docs/plans/p.md"
    ".planning/p.md" ".tmp/scratch" "CONTEXT.md" "tests/feature-plan.md"
)
for rel in "${forbidden_alts[@]}"; do
    dir="$FIXTURE_ROOT/alt-$(tr '/.' '__' <<<"$rel")"
    make_clean_fixture "$dir"
    mkdir -p "$dir/$(dirname "$rel")"
    printf 'x\n' >"$dir/$rel"
    git -C "$dir" add -f "$rel" >/dev/null 2>&1
    out=$(run_guard "$dir")
    rc=$?
    if ((rc == 1)) && grep -qF "FORBIDDEN-TRACKED-PATH${TAB}${rel}${TAB}" <<<"$out"; then
        pass "ported forbidden path is rejected: $rel"
    else
        fail "ported forbidden path is rejected: $rel" "rc=$rc :: $out"
    fi
done

# --- ported allowlists ------------------------------------------------------

allow_dir="$FIXTURE_ROOT/allow-path"
make_clean_fixture "$allow_dir"
printf 'GCP_PROJECT=example\n' >"$allow_dir/tests/.env.gcp.example"
printf 'TARGET_HOST=example.invalid\n' >"$allow_dir/tests/.env.lan-host.example"
git -C "$allow_dir" add -f tests/.env.gcp.example tests/.env.lan-host.example >/dev/null 2>&1
allow_out=$(run_guard "$allow_dir")
allow_rc=$?
if ((allow_rc == 0)) && [[ -z "$allow_out" ]]; then
    pass "ported path allowlist keeps live-host env examples"
else
    fail "ported path allowlist keeps live-host env examples" "rc=$allow_rc :: $allow_out"
fi

content_dir="$FIXTURE_ROOT/allow-content"
make_clean_fixture "$content_dir"
{
    secret_line aws-access-key-id
    printf '\n'
} >>"$content_dir/.env.example"
git -C "$content_dir" add .env.example >/dev/null 2>&1
content_out=$(run_guard "$content_dir")
content_rc=$?
if ((content_rc == 0)) && [[ -z "$content_out" ]]; then
    pass "ported content allowlist keeps .env.example"
else
    fail "ported content allowlist keeps .env.example" "rc=$content_rc :: $content_out"
fi

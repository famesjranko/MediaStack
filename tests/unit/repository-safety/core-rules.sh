# tests/unit/repository-safety/core-rules.sh
# Owns: the real tree, the clean fixture, one targeted bad fixture per
# registered rule, and the shape-specific probes (gitignored/bare/symlinked
# private paths, a simulated live install, an untracked private key).
# Sourced by: tests/unit/repository-safety.sh, after lib.sh.

# --- the real tree ----------------------------------------------------------

real_out=$(run_guard "$REPO_ROOT")
real_rc=$?
if ((real_rc == 0)) && [[ -z "$real_out" ]]; then
    pass "sanitized tree passes every rule"
else
    fail "sanitized tree passes every rule" "rc=$real_rc :: $real_out"
fi

# --- clean fixture ----------------------------------------------------------

make_clean_fixture "$FIXTURE_ROOT/clean"
clean_out=$(run_guard "$FIXTURE_ROOT/clean")
clean_rc=$?
if ((clean_rc == 0)) && [[ -z "$clean_out" ]]; then
    pass "clean fixture passes every rule"
else
    fail "clean fixture passes every rule" "rc=$clean_rc :: $clean_out"
fi

# A valid .yaml workflow counts as a workflow even when no .yml workflow is
# present. This protects the no-workflow check from recognizing only one
# supported suffix.
yaml_only_dir="$FIXTURE_ROOT/yaml-only-workflow"
make_clean_fixture "$yaml_only_dir"
rm "$yaml_only_dir/.github/workflows/ci.yml"
printf 'name: yaml-only\non: [push]\n' >"$yaml_only_dir/.github/workflows/dispatch.yaml"
git -C "$yaml_only_dir" add -u .github/workflows/ci.yml >/dev/null 2>&1
git -C "$yaml_only_dir" add .github/workflows/dispatch.yaml >/dev/null 2>&1
yaml_only_out=$(run_guard "$yaml_only_dir")
yaml_only_rc=$?
if ((yaml_only_rc == 0)) && [[ -z "$yaml_only_out" ]]; then
    pass "valid .yaml workflow satisfies workflow population"
else
    fail "valid .yaml workflow satisfies workflow population" "rc=$yaml_only_rc :: $yaml_only_out"
fi

# --- one targeted bad fixture per rule --------------------------------------

check_rule() {
    local rule="$1" dir="$FIXTURE_ROOT/bad-$1"
    make_clean_fixture "$dir"
    apply_defect "$rule" "$dir" || {
        fail "$rule: fixture builds" "no defect recipe"
        return
    }
    # Recorded only on a wired defect recipe, so a registered rule left
    # without a case in apply_defect drops out of exercised_sorted below.
    EXERCISED+=("$rule")

    local out rc others
    out=$(run_guard "$dir")
    rc=$?
    if ((rc != 1)); then
        fail "$rule: bad fixture exits 1" "rc=$rc :: $out"
        return
    fi
    if ! grep -q "^$rule${TAB}" <<<"$out"; then
        fail "$rule: bad fixture fails for its own rule" "$out"
        return
    fi
    others=$(cut -f1 <<<"$out" | sort -u | grep -vx "$rule")
    if [[ -n "$others" ]]; then
        fail "$rule: bad fixture is targeted" "also tripped: $others"
        return
    fi
    pass "$rule: bad fixture exits 1 for its own rule only"
}

while read -r rule; do
    [[ -n "$rule" ]] && check_rule "$rule"
done < <(run_guard --list-rules)

# --- gitignored + untracked analyzer cache ----------------------------------
# git ls-files cannot see it, so this is the rule that proves the guard reads
# the working tree and not just the index.

ua_dir="$FIXTURE_ROOT/bad-ANALYZER-CACHE"
if [[ -d "$ua_dir/.ua" ]]; then
    ua_tracked=$(git -C "$ua_dir" ls-files | grep -c '^\.ua/')
    ua_ignored=$(git -C "$ua_dir" check-ignore .ua/index.json 2>/dev/null)
    ua_out=$(run_guard "$ua_dir")
    if [[ "$ua_tracked" == "0" && -n "$ua_ignored" ]] && grep -q "^ANALYZER-CACHE${TAB}\.ua/index\.json" <<<"$ua_out"; then
        pass "gitignored and untracked .ua/ is rejected"
    else
        fail "gitignored and untracked .ua/ is rejected" "tracked=$ua_tracked ignored=$ua_ignored :: $ua_out"
    fi
else
    fail "gitignored and untracked .ua/ is rejected" "fixture missing"
fi

# --- bare-file analyzer cache -----------------------------------------------
# ANALYZER-CACHE also matches the non-directory shape: os.walk only trailing-
# slashes entries it puts in dirnames, so a regular file (or symlink-to-file)
# named .ua needs its own pattern, not just the directory one.

bare_ua_dir="$FIXTURE_ROOT/bare-ua-file"
make_clean_fixture "$bare_ua_dir"
printf 'hi\n' >"$bare_ua_dir/.ua"
bare_ua_out=$(run_guard "$bare_ua_dir")
bare_ua_rc=$?
if ((bare_ua_rc == 1)) && grep -qF "ANALYZER-CACHE${TAB}.ua${TAB}rule=analyzer-cache" <<<"$bare_ua_out"; then
    pass "a regular file named .ua is rejected"
else
    fail "a regular file named .ua is rejected" "rc=$bare_ua_rc :: $bare_ua_out"
fi

# --- symlinked private directories ------------------------------------------
# os.walk never descends a symlinked directory, so a rule that only tests
# filenames misses a .ua pointed at an external cache — the obvious way to
# keep a multi-megabyte analyzer cache out of the tree's disk usage.

sym_dir="$FIXTURE_ROOT/symlink"
sym_target="$FIXTURE_ROOT/symlink-target"
make_clean_fixture "$sym_dir"
mkdir -p "$sym_target/ua" "$sym_target/private" "$sym_dir/docs"
printf '{}\n' >"$sym_target/ua/index.json"
printf 'internal\n' >"$sym_target/private/notes.md"
ln -s "$sym_target/ua" "$sym_dir/.ua"
ln -s "$sym_target/private" "$sym_dir/docs/private"
sym_out=$(run_guard "$sym_dir")
for probe in "ANALYZER-CACHE|.ua/" "PRIVATE-DOC-DIR|docs/private/"; do
    rule="${probe%%|*}"
    path="${probe#*|}"
    if grep -qF "${rule}${TAB}${path}${TAB}rule=" <<<"$sym_out"; then
        pass "symlinked private directory is rejected: $path"
    else
        fail "symlinked private directory is rejected: $path" "$sym_out"
    fi
done

# --- a live install is not a finding ----------------------------------------
# MediaStack installs in-place in its own clone: setup writes fail2ban
# placeholder logs and TLS material into the gitignored config/<svc>/ dirs and
# clones nvidia-patch into the tree. None of that may fire a rule.

live_dir="$FIXTURE_ROOT/live-install"
make_clean_fixture "$live_dir"
mkdir -p "$live_dir/config/jellyfin/log" "$live_dir/config/npm/data/logs" \
    "$live_dir/config/npm/letsencrypt/live/example" "$live_dir/config/seerr/logs" \
    "$live_dir/.nvidia-patch/.git/logs" "$live_dir/vendor/dep/.git/logs"
: >"$live_dir/config/jellyfin/log/log_.log"
: >"$live_dir/config/npm/data/logs/default-host_.log"
: >"$live_dir/config/npm/data/logs/proxy-host-___.log"
: >"$live_dir/config/seerr/logs/seerr-.log"
printf 'placeholder\n' >"$live_dir/config/npm/letsencrypt/live/example/privkey.pem"
printf 'ref\n' >"$live_dir/.nvidia-patch/.git/logs/HEAD"
printf 'ref\n' >"$live_dir/vendor/dep/.git/logs/HEAD"
printf 'ok\n' >"$live_dir/.setup-result"
printf 'general: {}\n' >"$live_dir/config.yml"
live_out=$(run_guard "$live_dir")
live_rc=$?
if ((live_rc == 0)) && [[ -z "$live_out" ]]; then
    pass "simulated live install produces no findings"
else
    fail "simulated live install produces no findings" "rc=$live_rc :: $live_out"
fi

# --- an untracked private key is still a finding ----------------------------

untracked_dir="$FIXTURE_ROOT/untracked-key"
make_clean_fixture "$untracked_dir"
printf 'placeholder\n' >"$untracked_dir/id_rsa"
untracked_out=$(run_guard "$untracked_dir")
untracked_rc=$?
if ((untracked_rc == 1)) && grep -qF "SECRET-FILE${TAB}id_rsa${TAB}class=id_rsa*" <<<"$untracked_out"; then
    pass "untracked private key is rejected"
else
    fail "untracked private key is rejected" "rc=$untracked_rc :: $untracked_out"
fi

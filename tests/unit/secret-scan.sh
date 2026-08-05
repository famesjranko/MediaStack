#!/usr/bin/env bash
# tests/unit/secret-scan.sh
#
# Regression proof for tests/secret-scan.sh, the formal secret scanner: the
# exit-code contract, both scan modes, and every guard that stands between a
# weakened scan and a confident "clean". Pure bash + python3 + git + the pinned
# gitleaks — no Docker.
#
# Fixtures are temp dirs and temp git repos; the real tree is never scanned and
# never written to. Canary literals are assembled at runtime from split halves
# so this file is not itself a finding, and only rule IDs are ever asserted on.
#
# It fails closed when the scanner is missing rather than skipping: a skipped
# secret scan is the failure mode the scanner exists to prevent. Installing is
# idempotent, but a cold tool cache makes this suite need network once.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="secret-scan"
scenario_begin "$CURRENT_SCENARIO"

SCANNER="$REPO_ROOT/tests/secret-scan.sh"
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

# Verified to clear the default ruleset's entropy and base32 checks; a canary
# that never fires would make every assertion below vacuous.
AWS_CANARY="AKIA""MNBVCXZASDFGH234"
# A distinct second key, for the gate probe that a real secret is still caught
# in a file that already carries a declared false positive.
SECOND_AWS_CANARY="AKIA""ZXCVBNMLKJHG7654"
GENERIC_CANARY="Xq7Vn2ZmT4bK9wLd""Rj5cHs8PyG3uEaMt"

run_scan() { run_cmd "$@"; }

# Overrides the shared tests/lib/assert.sh assert_rc: never echoes $OUT on a
# mismatch, since OUT can carry a scanner finding built from a canary value —
# the point of this suite is that no such value survives into output a
# reviewer might paste.
assert_rc() {
    local expected="$1" name="$2"
    if [[ "$RC" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected rc $expected, got $RC"
    fi
}

# Never echoes the needle: the point of the check is that the value stays out
# of any output a reviewer might paste.
assert_absent() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "canary value appeared in output" ;;
        *) pass "$name" ;;
    esac
}

write_aws_canary() { printf 'aws_access_key_id = %s\n' "$AWS_CANARY" >"$1"; }

new_repo() {
    local dir="$FIXTURE_ROOT/$1"
    mkdir -p "$dir" || return 1
    git -C "$dir" init -q .
    git -C "$dir" config user.email scan@example.invalid
    git -C "$dir" config user.name scan
    printf '%s\n' "$dir"
}

mkdir -p "$FIXTURE_ROOT/clean" "$FIXTURE_ROOT/canary" "$FIXTURE_ROOT/empty"
printf 'nothing to see\n' >"$FIXTURE_ROOT/clean/readme"
write_aws_canary "$FIXTURE_ROOT/canary/creds"
ln -s "$FIXTURE_ROOT/canary" "$FIXTURE_ROOT/canary-link"

# The identity a declaration pins is never transcribed by hand: it hashes
# gitleaks' redacted match text, so it is always harvested from the
# reconciler's own UNEXPECTED output.
declarations_from() {
    awk -F'\t' '$1 == "UNEXPECTED" { print $2 "\t" $3 "\t" $4 }' <<<"$1"
}

# --- reconciliation, direct ------------------------------------------------
# The reconciler is a separate module and needs no scanner: a report and a
# declaration file are the whole input. The steering matrix is proved here in
# milliseconds, which is why the gitleaks-backed gate probes further down
# prove only that the scanner and the gate agree.

RECONCILE="$REPO_ROOT/tests/lib/secret_scan_reconcile.py"
RECON="$FIXTURE_ROOT/reconcile"
mkdir -p "$RECON"

# A gitleaks report carries far more than this; these are exactly the fields
# the identity hashes, so a fixture with any more in it would be scenery.
write_report() {
    local out="$RECON/report.json" first=1 file
    printf '[' >"$out"
    for file in "$@"; do
        ((first)) || printf ',' >>"$out"
        printf '{"RuleID":"generic-api-key","File":"%s","Match":"REDACTED","Entropy":3.5}' \
            "$file" >>"$out"
        first=0
    done
    printf ']\n' >>"$out"
}

run_reconcile() {
    OUT=$(python3 "$RECONCILE" "$RECON/report.json" "$RECON/expected" "$RECON" "$1" 2>&1)
    RC=$?
}

# Harvest the two real identities once; every case below is built from them.
write_report a b
printf 'generic-api-key\tplaceholder\t0000000000000000\n' >"$RECON/expected"
run_reconcile tree
declarations_from "$OUT" >"$RECON/both"
head -1 "$RECON/both" >"$RECON/one"
STALE='generic-api-key	gone	ffffffffffffffff'

assert_steer_tree() {
    assert_contains "$OUT" "remove the secret from the tree" "$1: steers to removal"
    assert_contains "$OUT" "grows only under human review" "$1: refuses a declaration to pass"
    assert_contains "$OUT" "secret-scan section of tests/README.md" "$1: points at the contract"
}

assert_steer_history() {
    assert_contains "$OUT" "cannot be taken back" "$1: names the published commit"
    assert_contains "$OUT" "rotating the credential is the only real remediation" \
        "$1: steers to rotation"
    assert_contains "$OUT" "needs human review" "$1: defers the declaration to a human"
    # Case-folded: the point is that no wording anywhere tells a reader to
    # rewrite published history, and "Rewrite" slips past a literal match.
    assert_absent "$(tr '[:upper:]' '[:lower:]' <<<"$OUT")" "rewrit" \
        "$1: never suggests rewriting history"
}

STALE_LINE="a declaration nothing produced is stale"

# tree x unexpected only
write_report a b
cp "$RECON/one" "$RECON/expected"
run_reconcile tree
assert_rc 1 "tree: an undeclared finding fails"
assert_steer_tree "tree unexpected"
assert_absent "$OUT" "$STALE_LINE" "tree unexpected: no stale-declaration direction"

# tree x absent only
write_report a
{
    cat "$RECON/one"
    printf '%s\n' "$STALE"
} >"$RECON/expected"
run_reconcile tree
assert_rc 1 "tree: a declaration nothing produced fails"
assert_contains "$OUT" "$STALE_LINE" "tree absent: names the stale declaration"
assert_contains "$OUT" "remove its line from" "tree absent: steers to removing the line"
assert_absent "$OUT" "remove the secret from the tree" "tree absent: no removal steering"

# tree x both
write_report a b
printf '%s\n' "$STALE" >"$RECON/expected"
run_reconcile tree
assert_rc 1 "tree: both directions at once fail"
assert_steer_tree "tree both"
assert_contains "$OUT" "$STALE_LINE" "tree both: carries the stale direction too"

# history x unexpected only
cp "$RECON/one" "$RECON/expected"
write_report a b
run_reconcile history
assert_rc 1 "history: an undeclared finding fails"
assert_steer_history "history unexpected"
assert_absent "$OUT" "remove the secret from the tree" \
    "history unexpected: never steers to removing it from the tree"

# history x absent only
write_report a
{
    cat "$RECON/one"
    printf '%s\n' "$STALE"
} >"$RECON/expected"
run_reconcile history
assert_rc 1 "history: a declaration nothing produced fails"
assert_contains "$OUT" "$STALE_LINE" "history absent: names the stale declaration"
assert_absent "$OUT" "cannot be taken back" "history absent: no rotation steering"

# history x both
write_report a b
printf '%s\n' "$STALE" >"$RECON/expected"
run_reconcile history
assert_rc 1 "history: both directions at once fail"
assert_steer_history "history both"
assert_contains "$OUT" "$STALE_LINE" "history both: carries the stale direction too"

# the green path and the two fail-closed paths
write_report a b
cp "$RECON/both" "$RECON/expected"
run_reconcile tree
assert_rc 0 "a fully declared report reconciles clean"
assert_contains "$OUT" "all declared" "the clean run says the findings are declared"
assert_absent "$OUT" "$STALE_LINE" "the clean run prints no steering"

printf '# nothing declared\n' >"$RECON/expected"
run_reconcile tree
assert_rc 2 "a declaration file holding no declarations is an error"
assert_contains "$OUT" "no declarations in" "the empty declaration set names the file"

cp "$RECON/both" "$RECON/expected"
printf 'not json\n' >"$RECON/report.json"
run_reconcile tree
assert_rc 2 "an unreadable report is an error"
assert_contains "$OUT" "unreadable report" "the unreadable report is named"

OUT=$(python3 "$RECONCILE" one two 2>&1)
RC=$?
assert_rc 2 "the reconciler rejects a short argument list"

# --- install + usage -------------------------------------------------------

run_scan "$SCANNER" install
assert_rc 0 "install verifies the pinned binary"
if [[ "$RC" != 0 ]]; then
    fail "scanner is available" "install failed: $OUT"
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit 1
fi

run_scan "$SCANNER" not-a-mode
assert_rc 2 "an unknown mode is a usage error"

run_scan "$SCANNER" tree "$FIXTURE_ROOT/no-such-path"
assert_rc 2 "a missing target is an error"

# --- tree mode -------------------------------------------------------------

run_scan "$SCANNER" tree "$FIXTURE_ROOT/clean"
assert_rc 0 "a clean tree exits 0"

run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary"
assert_rc 1 "a tree canary exits 1"
assert_contains "$OUT" "aws-access-token" "the tree finding names its rule"
assert_absent "$OUT" "$AWS_CANARY" "the tree finding is redacted"

run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary-link"
assert_rc 1 "a symlinked scan root exits 1 like the real path"
assert_contains "$OUT" "aws-access-token" "the symlinked root reports the same rule"

run_scan "$SCANNER" tree "$FIXTURE_ROOT/empty"
assert_rc 2 "an empty tree is an error, not a pass"

mkdir -p "$FIXTURE_ROOT/archive"
write_aws_canary "$FIXTURE_ROOT/archive-src"
if command -v zip >/dev/null 2>&1; then
    (cd "$FIXTURE_ROOT" && zip -q archive/bundle.zip archive-src)
else
    tar -czf "$FIXTURE_ROOT/archive/bundle.tar.gz" -C "$FIXTURE_ROOT" archive-src
fi
rm -f "$FIXTURE_ROOT/archive-src"
run_scan "$SCANNER" tree "$FIXTURE_ROOT/archive"
assert_rc 1 "an archived canary is unpacked and found"

before=$(ls -A "$FIXTURE_ROOT/canary")
run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary"
assert_eq "$before" "$(ls -A "$FIXTURE_ROOT/canary")" "a scan writes nothing into its target"

MS_SCAN_REPORT_DIR="$FIXTURE_ROOT/canary/reports" \
    run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "a report dir inside the target is rejected"

# --- in-band suppression ---------------------------------------------------

# The override may add a report location; it may not reach the ignore root.
mkdir -p "$FIXTURE_ROOT/planted/no-ignore"
printf '%s\n' "$FIXTURE_ROOT/canary/creds:aws-access-token:1" \
    >"$FIXTURE_ROOT/planted/no-ignore/.gitleaksignore"
MS_SCAN_REPORT_DIR="$FIXTURE_ROOT/planted" run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary"
assert_rc 1 "a suppression file planted in the report dir does not weaken the scan"

printf 'creds:aws-access-token:1\n' >"$FIXTURE_ROOT/canary/.gitleaksignore"
run_scan "$SCANNER" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "a .gitleaksignore in the target aborts the scan"
assert_contains "$OUT" "suppression file in the scan target" "the abort names the suppression file"
rm -f "$FIXTURE_ROOT/canary/.gitleaksignore"

# --- tampered pin / ruleset ------------------------------------------------

# A standalone copy of the scanner: it resolves its pin manifest, its config
# and its helper modules from its own location, so a mutated copy exercises
# the guards in isolation. Only the helpers tests/secret-scan.sh actually
# sources are copied — tests/lib/secret-scan-install.sh (the install/self-test
# logic) and tests/lib/secret_scan_reconcile.py (reconciliation) — not
# tests/lib wholesale, which would drag in unrelated helpers this scanner
# never reaches.
fake_root() {
    local dir="$FIXTURE_ROOT/$1"
    mkdir -p "$dir/tests/lib" || return 1
    cp "$REPO_ROOT/tools.toml" "$dir/tools.toml"
    cp "$REPO_ROOT/.gitleaks.toml" "$dir/.gitleaks.toml"
    cp "$SCANNER" "$dir/tests/secret-scan.sh"
    cp "$REPO_ROOT/tests/lib/secret-scan-install.sh" "$dir/tests/lib/secret-scan-install.sh"
    cp "$REPO_ROOT/tests/lib/secret_scan_reconcile.py" "$dir/tests/lib/secret_scan_reconcile.py"
    printf '%s\n' "$dir"
}

gutted=$(fake_root gutted)
: >"$gutted/.gitleaks.toml"
run_scan "$gutted/tests/secret-scan.sh" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "an emptied ruleset fails the self-test"
assert_contains "$OUT" "self-test" "the emptied ruleset is reported as a self-test failure"

allowed=$(fake_root allowed)
printf 'title="x"\n[extend]\nuseDefault = true\n[allowlist]\nregexes = [".*"]\n' \
    >"$allowed/.gitleaks.toml"
run_scan "$allowed/tests/secret-scan.sh" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "a catch-all allowlist fails the self-test"

muted=$(fake_root muted)
printf 'title="x"\n[extend]\nuseDefault = true\ndisabledRules = ["private-key"]\n' \
    >"$muted/.gitleaks.toml"
run_scan "$muted/tests/secret-scan.sh" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "one disabled rule fails the self-test"
assert_contains "$OUT" "private-key" "the self-test names the rule that did not fire"

tampered=$(fake_root tampered)
sed -i 's/^binary_sha256 = ".*"/binary_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$tampered/tools.toml"
run_scan "$tampered/tests/secret-scan.sh" tree "$FIXTURE_ROOT/canary"
assert_rc 2 "a binary that does not match the pinned sha256 is rejected"
assert_contains "$OUT" "sha256" "the rejection names the sha256 mismatch"

# --- history mode ----------------------------------------------------------

removed=$(new_repo removed)
write_aws_canary "$removed/creds"
git -C "$removed" add creds && git -C "$removed" commit -qm "add credentials"
git -C "$removed" rm -q creds && git -C "$removed" commit -qm "drop credentials"
printf 'clean\n' >"$removed/readme"
git -C "$removed" add readme && git -C "$removed" commit -qm "add readme"

run_scan "$SCANNER" tree "$removed"
assert_rc 0 "a removed secret is absent from the tree"

run_scan "$SCANNER" history "$removed" --all
assert_rc 1 "a removed secret is still found in history"
assert_contains "$OUT" "aws-access-token" "the history finding names its rule"
assert_absent "$OUT" "$AWS_CANARY" "the history finding is redacted"

clean_repo=$(new_repo clean-repo)
printf 'clean\n' >"$clean_repo/readme"
git -C "$clean_repo" add readme && git -C "$clean_repo" commit -qm "add readme"
run_scan "$SCANNER" history "$clean_repo" --all
assert_rc 0 "clean history exits 0"
assert_contains "$OUT" "message scan: clean" "history mode reports that messages were scanned"

run_scan "$SCANNER" history "$clean_repo" "HEAD..HEAD"
assert_rc 2 "a range that selects no commits is an error"
assert_contains "$OUT" "selects no commits" "the abort names the empty-range guard"

git -C "$clean_repo" commit -q --allow-empty -m "empty"
run_scan "$SCANNER" history "$clean_repo" "HEAD~1..HEAD"
assert_rc 2 "a range the scanner reads no commits from is an error"
assert_contains "$OUT" "no commits scanned" "the abort names the commits-scanned guard"

ignored=$(new_repo ignored-history)
printf 'clean\n' >"$ignored/readme"
printf 'creds:aws-access-token:1\n' >"$ignored/.gitleaksignore"
git -C "$ignored" add readme .gitleaksignore && git -C "$ignored" commit -qm "add files"
git -C "$ignored" rm -q .gitleaksignore && git -C "$ignored" commit -qm "drop ignore file"
run_scan "$SCANNER" history "$ignored" --all
assert_rc 2 "a .gitleaksignore reachable in history aborts the scan"
assert_contains "$OUT" "suppression file reachable in history" "the abort names the reachable file"

merged=$(new_repo merged)
printf 'base\n' >"$merged/base"
git -C "$merged" add base && git -C "$merged" commit -qm base
git -C "$merged" checkout -q -b side
printf 'side\n' >"$merged/side"
git -C "$merged" add side && git -C "$merged" commit -qm side
git -C "$merged" checkout -q -
printf 'trunk\n' >"$merged/trunk"
git -C "$merged" add trunk && git -C "$merged" commit -qm trunk
git -C "$merged" merge --no-ff -q side -m "merge side"
write_aws_canary "$merged/resolved"
git -C "$merged" add resolved && git -C "$merged" commit -q --amend --no-edit
run_scan "$SCANNER" history "$merged" --all
assert_rc 1 "a secret added only by a merge resolution is found"
assert_contains "$OUT" "aws-access-token" "the merge finding names its rule"

messages=$(new_repo messages)
printf 'clean\n' >"$messages/readme"
git -C "$messages" add readme && git -C "$messages" commit -qm "add readme"
git -C "$messages" commit -q --allow-empty -m "wip $AWS_CANARY"
git -C "$messages" tag -a v0 -m "release token=$GENERIC_CANARY"
run_scan "$SCANNER" history "$messages" --all
assert_rc 1 "a secret in a commit or tag message is found"
assert_contains "$OUT" "commit-" "the message finding names the commit it came from"
assert_contains "$OUT" "tag-v0" "the message finding names the annotated tag"
assert_absent "$OUT" "$AWS_CANARY" "the message finding is redacted"

# --- gate mode: the scanner and the reconciler, together -------------------
# The reconciliation contract is proved directly above. What is left here is
# the join: that a real scan produces identities the declaration file can pin,
# and that both gate modes agree on them.

gate_repo=$(new_repo gate)
printf 'readme\n' >"$gate_repo/readme"
write_aws_canary "$gate_repo/known"
git -C "$gate_repo" add readme known
git -C "$gate_repo" commit -qm "add files"

DECL="$FIXTURE_ROOT/gate.expected"

run_scan "$SCANNER" gate-tree "$FIXTURE_ROOT/no-such-file" "$gate_repo"
assert_rc 2 "a missing declaration file is an error"

printf '# nothing declared\n' >"$DECL"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 2 "a declaration file holding no declarations is an error"

printf 'aws-access-token\tabsent\t0000000000000000\n' >"$DECL"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 1 "an undeclared finding fails the gate"
assert_contains "$OUT" "UNEXPECTED" "the gate names the undeclared finding"
assert_contains "$OUT" "DECLARED-BUT-ABSENT" "the gate names the declaration nothing produced"
assert_absent "$OUT" "$AWS_CANARY" "the gate never echoes the matched value"
# The steering text itself is proved against the reconciler above; this probe
# only has to show that a real scan reaches it.
assert_contains "$OUT" "remove the secret from the tree" "the gate reaches the tree steering"

declarations_from "$OUT" >"$DECL"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 0 "a fully declared finding set passes the gate"

# The same declaration file, unchanged, must satisfy the history scan: the
# identity is a property of the finding, not of which mode produced it.
run_scan "$SCANNER" gate-history "$DECL" "$gate_repo"
assert_rc 0 "the tree declaration also satisfies the history gate"

sed -i '1i # an unrelated first line' "$gate_repo/known"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 0 "an edit that moves the finding's line leaves its declaration valid"

printf 'aws_access_key_id = %s\n' "$SECOND_AWS_CANARY" >>"$gate_repo/known"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 1 "a second secret in a file that already carries a declared finding is unexpected"
assert_absent "$OUT" "$SECOND_AWS_CANARY" "the unexpected finding is redacted"

sed -i '$d' "$gate_repo/known"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 0 "removing the new secret restores the gate to green"

# The decisive one: substituting the secret keeps the finding count, the rule,
# the path and the line identical. A gate pinned on a count would stay green.
printf 'aws_access_key_id = %s\n' "$SECOND_AWS_CANARY" >"$gate_repo/known"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 1 "a substituted secret at the same rule, path and count is unexpected"

write_aws_canary "$gate_repo/known"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 0 "restoring the declared content restores the gate to green"

git -C "$gate_repo" rm -qf known
git -C "$gate_repo" commit -qm "drop the known file"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 1 "a declaration whose finding disappeared fails until the line is removed"
assert_contains "$OUT" "DECLARED-BUT-ABSENT" "the shrink path names the stale declaration"

# The deleted file's finding still exists in reachable history. Marking its
# declaration history-only satisfies both gates: the tree gate ignores the
# line, the history gate strips the marker and reconciles it normally.
sed -i 's/^aws-access-token\t/history-only\taws-access-token\t/' "$DECL"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 2 "a history-only declaration alone leaves the tree set empty and fails closed"
printf 'generic-api-key\treadme\t0000000000000000\n' >>"$DECL"
run_scan "$SCANNER" gate-tree "$DECL" "$gate_repo"
assert_rc 1 "the tree gate reconciles only the plain declarations"
assert_absent "$OUT" "aws-access-token" "the history-only line is invisible to the tree gate"
sed -i '$d' "$DECL"
run_scan "$SCANNER" gate-history "$DECL" "$gate_repo"
assert_rc 0 "the history gate reconciles the history-only declaration"

expected=99
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

scenario_end "$CURRENT_SCENARIO"
summary

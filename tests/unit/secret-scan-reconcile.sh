#!/usr/bin/env bash
# tests/unit/secret-scan-reconcile.sh
#
# Regression proof for tests/lib/secret_scan_reconcile.py, the secret-scan
# reconciliation module: the full steering matrix (tree/history x
# unexpected/absent/both), the fail-closed paths, and the argument contract —
# all against hand-written reports, no scanner and no Docker. The
# gitleaks-backed probes stay in tests/unit/secret-scan.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="secret-scan-reconcile"
scenario_begin "$CURRENT_SCENARIO"

FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

# Never echoes the needle: reconciler output carries finding identities, and
# the discipline that no matched value survives into pasteable output is
# shared with the scanner suite.
assert_absent() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "needle appeared in output" ;;
        *) pass "$name" ;;
    esac
}

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

run_reconcile tre # a typo'd mode must not take the tree path with history steering
assert_rc 2 "the reconciler rejects an unknown mode"
assert_contains "$OUT" "unknown mode" "the unknown mode is named"

write_report a b # readable report: the next failure must be the declarations' own
chmod 000 "$RECON/expected"
run_reconcile tree
chmod 644 "$RECON/expected"
assert_rc 2 "an unreadable declaration file is an error, not a mismatch"
assert_contains "$OUT" "unreadable declarations" "the unreadable declaration file is named"

expected=41
total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
((total == expected)) || fail "check count is stable" "expected $expected, got $total"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# tests/secret-scan.sh
#
# Formal secret scanner, pinned in tools.toml, in the two modes publication
# review needs:
#
#   ./tests/secret-scan.sh install                       fetch + verify the pin
#   ./tests/secret-scan.sh tree    [path]                the tree as it stands
#   ./tests/secret-scan.sh history [repo] [git-log-opts] reachable history
#   ./tests/secret-scan.sh gate-tree    [expected] [target]   tree, reconciled
#   ./tests/secret-scan.sh gate-history [expected] [target]   history, reconciled
#
# The two gate modes are the blocking form: they run the same scan and then
# compare the findings, as stable identities, against the declared set in
# tests/secret-scan.expected — the tree gate as a multiset, the history gate
# as distinct identities (each edit of a declared line re-adds it to history).
# An undeclared finding fails; a declaration nothing produced fails too, so
# removing a false positive means removing its line.
#
# A tree scan covers what a checkout contains right now. It says nothing about
# a secret that was committed and later deleted; only history mode reaches
# those blobs. Run both.
#
# Exit codes match the guards: 0 clean, 1 findings, 2 scanner or usage error.
# Findings print rule, path, line and commit - never the matched value.
# Needs network on first run only; the verified binary is cached outside the
# repository, as are all reports and every temporary file this script writes.
#
# A clean result is only worth the checks behind it, so every scan is preceded
# by a self-test that proves the pinned binary and the pinned ruleset still
# detect synthetic canaries, and by a pre-flight that refuses to scan a target
# carrying an in-band suppression file.

set -uo pipefail

export PYTHONDONTWRITEBYTECODE=1
# Lower-precedence config channels than --config, but unset so a stray value
# can never reach a future invocation that forgets the flag.
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_TOML="$REPO_ROOT/tools.toml"

TOOL_CACHE="${MS_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mediastack-tools}"
# gitleaks reports findings with this code; every other nonzero code is an
# error. Sharing one code with errors is how a broken scan reads as a dirty
# scan, or worse, a clean one.
FINDING_RC=7
# Nested archives are unpacked to this depth. gitleaks defaults to 0, which
# means a secret inside a committed .zip or .tar.gz is never read.
ARCHIVE_DEPTH=4
SCRATCH=""
# Install-time download scratch; removed by the shared EXIT trap so a die
# between mktemp and the success-path rm does not strand the tarball in /tmp.
INSTALL_TMP=""
EXPECTED_DEFAULT="$REPO_ROOT/tests/secret-scan.expected"
# Set by the scan functions so a gate mode can reconcile what they produced
# instead of recomputing the report path and the resolved target.
LAST_REPORT=""
TARGET_ABS=""
MESSAGE_FINDINGS=0

die() {
    printf 'SCAN-ERROR\t%s\n' "$1" >&2
    exit 2
}

cleanup() {
    [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
    [ -n "$INSTALL_TMP" ] && rm -rf "$INSTALL_TMP"
}

usage() {
    cat <<'EOF'
Usage:
  tests/secret-scan.sh install                       fetch + verify the pin
  tests/secret-scan.sh tree    [path]                the tree as it stands
  tests/secret-scan.sh history [repo] [git-log-opts] reachable history
  tests/secret-scan.sh gate-tree    [expected] [target]  tree, reconciled
  tests/secret-scan.sh gate-history [expected] [target]  history, reconciled

Exit codes: 0 clean, 1 findings, 2 scanner or usage error.
EOF
}

# Section-scoped reader for the flat key = "value" form tools.toml uses.
pin() {
    local key="$1" value
    [ -r "$TOOLS_TOML" ] || die "unreadable pin manifest: $TOOLS_TOML"
    value=$(awk -F' *= *' -v key="$key" '
        /^\[/ { in_section = ($0 == "[gitleaks]"); next }
        in_section && $1 == key { gsub(/"/, "", $2); print $2; exit }
    ' "$TOOLS_TOML")
    [ -n "$value" ] || die "tools.toml [gitleaks] is missing $key"
    printf '%s\n' "$value"
}

VERSION="$(pin version)" || exit 2
GITLEAKS="$TOOL_CACHE/gitleaks-$VERSION/gitleaks"
CONFIG="$REPO_ROOT/$(pin config)" || exit 2
BINARY_SHA256="$(pin binary_sha256)" || exit 2

# shellcheck source=tests/lib/secret-scan-install.sh
source "$REPO_ROOT/tests/lib/secret-scan-install.sh"

# One scratch root per invocation, always mktemp: the ignore root, the canaries
# and the message dump must not be reachable through any caller-set variable.
scratch_init() {
    SCRATCH=$(mktemp -d) || die "mktemp failed"
    trap cleanup EXIT
    mkdir -p "$SCRATCH/no-ignore" || die "cannot create $SCRATCH/no-ignore"
}

# Reports may be redirected for archiving; they still never land in the target.
work_dir() {
    local target_abs="$1" dir dir_abs
    dir="${MS_SCAN_REPORT_DIR:-$SCRATCH/reports}"
    mkdir -p "$dir" || die "cannot create $dir"
    dir_abs="$(cd "$dir" && pwd -P)" || die "unreadable report dir: $dir"
    case "$dir_abs/" in
        "$target_abs"/*) die "report dir is inside the scan target: $dir" ;;
    esac
    printf '%s\n' "$dir_abs"
}

# `-i` is additive: it does not stop gitleaks reading a .gitleaksignore out of
# the scan target, and an untracked one never shows up in a review diff.
assert_no_ignore_file() {
    local root="$1" hit
    hit=$(find "$root" -name .gitleaksignore -print -quit 2>/dev/null)
    [ -z "$hit" ] || die "suppression file in the scan target: $hit"
}

assert_no_ignore_in_history() {
    local target="$1" hit
    shift
    hit=$(git -C "$target" log "$@" --format='%H' --name-only \
        -- '*.gitleaksignore' 2>/dev/null | head -4)
    [ -z "$hit" ] || die "suppression file reachable in history: $(tr '\n' ' ' <<<"$hit")"
}

scan() {
    local report="$1" log="$2"
    shift 2
    "$GITLEAKS" "$@" \
        --no-banner --no-color --redact=100 \
        --exit-code "$FINDING_RC" \
        --ignore-gitleaks-allow \
        --max-archive-depth "$ARCHIVE_DEPTH" \
        -i "$SCRATCH/no-ignore" \
        --config "$CONFIG" \
        --report-format json --report-path "$report" 2>"$log"
}

rule_ids() {
    python3 - "$1" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as handle:
    for finding in json.load(handle):
        print(finding.get("RuleID", "?"))
PYEOF
}

# Proves the binary and the ruleset still fire before any result from them is
# believed. A gutted .gitleaks.toml and a substituted binary both land here.
self_test() {
    local dir report log found missing="" rule
    dir="$SCRATCH/self-test"
    report="$SCRATCH/self-test.json"
    log="$SCRATCH/self-test.log"
    mkdir -p "$dir" || die "cannot create $dir"

    # Split literals: assembled only at runtime, so this file is not itself a
    # finding. Values are fixed and verified high-entropy - see tests/README.md.
    local a1="VJKL5MNOPQR3STUW" g1="wZ9tQx4LmN7vB2kR" g2="6yTfJ3sHdPa8XcEu"
    printf 'aws_access_key_id = %s%s\n' "AKIA" "$a1" >"$dir/aws"
    printf -- '%s RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA7f3Kq2WvR9tYxNzB1cLmJ5hGd8XePqAo\n%s RSA PRIVATE KEY-----\n' \
        "-----BEGIN" "-----END" >"$dir/pem"
    printf 'api_key = "%s%s"\n' "$g1" "$g2" >"$dir/generic"

    scan "$report" "$log" dir "$dir"
    [ $? = "$FINDING_RC" ] || die "self-test: scanner did not report the canaries (see $CONFIG)"
    found=$(rule_ids "$report") || die "self-test: unreadable report"
    for rule in aws-access-token private-key generic-api-key; do
        grep -qx "$rule" <<<"$found" || missing="$missing $rule"
    done
    [ -z "$missing" ] || die "self-test: rules did not fire:$missing"
    rm -rf "$dir"
}

# gitleaks logs `scanned ~<bytes> bytes`; zero means the walk found nothing,
# which a symlinked root, an empty tree or a bad target all produce.
assert_scanned() {
    local log="$1" mode="$2" bytes
    bytes=$(sed -n 's/.*scanned ~\([0-9]\{1,\}\) bytes.*/\1/p' "$log" | tail -1)
    [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null \
        || die "$mode scan read 0 bytes - nothing was scanned"
}

report_findings() {
    local report="$1" mode="$2" count
    count=$(
        python3 - "$report" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as handle:
    findings = json.load(handle)
for finding in findings:
    sys.stderr.write("FINDING\t%s\t%s\t%s\t%s\n" % (
        finding.get("RuleID", "?"),
        finding.get("File", "?"),
        finding.get("StartLine", "?"),
        (finding.get("Commit") or "-")[:12],
    ))
print(len(findings))
PYEOF
    ) || die "unreadable report: $report"
    printf '%s scan: %s finding(s)\n' "$mode" "$count"
    [ "$count" -gt 0 ] || die "$mode scan exited $FINDING_RC with an empty report"
}

scan_tree() {
    local target rc work report log
    target="$(realpath -e "${1:-$REPO_ROOT}" 2>/dev/null)" \
        || die "no such path: ${1:-$REPO_ROOT}"
    require_scanner
    scratch_init
    self_test
    assert_no_ignore_file "$target"
    work="$(work_dir "$target")" || exit 2
    report="$work/tree.json"
    log="$SCRATCH/tree.log"
    LAST_REPORT="$report"
    TARGET_ABS="$target"

    scan "$report" "$log" dir "$target"
    rc=$?
    cat "$log" >&2
    assert_scanned "$log" tree
    case $rc in
        0) printf 'tree scan: clean (%s)\n' "$target" ;;
        "$FINDING_RC")
            report_findings "$report" tree
            return 1
            ;;
        *) die "gitleaks dir exited $rc" ;;
    esac
}

# Reads <name>\x1f<body>\x1e records from a file - stdin belongs to the heredoc
# - and writes one file per object so a finding names its commit or tag.
dump_messages() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import os, sys

src, out, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8", errors="replace") as stream:
    raw = stream.read()
for record in raw.split("\x1e"):
    name, sep, body = record.strip("\n").partition("\x1f")
    name = name.strip()
    if not sep or not name:
        continue
    safe = "".join(c if (c.isalnum() or c in "-_.") else "_" for c in name)
    with open(os.path.join(out, prefix + safe + ".msg"), "w") as handle:
        handle.write(body)
PYEOF
}

# Commit and annotated-tag messages are published by the same push as the
# blobs and no gitleaks mode reads them.
scan_messages() {
    local target="$1" dir report log rc
    shift
    dir="$SCRATCH/messages"
    report="$SCRATCH/messages.json"
    log="$SCRATCH/messages.log"
    mkdir -p "$dir" || die "cannot create $dir"

    git -C "$target" log "$@" --format='%H%x1f%B%x1e' >"$SCRATCH/commits.raw" 2>/dev/null \
        || die "cannot read commit messages"
    dump_messages "$SCRATCH/commits.raw" "$dir" commit- || die "cannot write commit messages"
    # for-each-ref has no %xNN escape, so tag bodies are fetched one ref at a time.
    while read -r ref; do
        git -C "$target" for-each-ref --format='%(contents)' "refs/tags/$ref" \
            >"$dir/tag-${ref//\//_}.msg" || die "cannot read tag message: $ref"
    done < <(git -C "$target" for-each-ref --format='%(refname:short)' refs/tags)
    [ -n "$(ls -A "$dir")" ] || die "message scan collected nothing for: $*"

    scan "$report" "$log" dir "$dir"
    rc=$?
    assert_scanned "$log" message
    case $rc in
        0) printf 'message scan: clean (%s messages)\n' "$(find "$dir" -type f | wc -l)" ;;
        "$FINDING_RC")
            report_findings "$report" message
            return 1
            ;;
        *) die "gitleaks dir exited $rc scanning messages" ;;
    esac
}

scan_history() {
    local target rc found=0 work report log expected scanned serialised_opts
    local -a log_opts
    target="$(realpath -e "${1:-$REPO_ROOT}" 2>/dev/null)" \
        || die "no such path: ${1:-$REPO_ROOT}"
    (($# > 0)) && shift
    log_opts=("$@")
    ((${#log_opts[@]} > 0)) || log_opts=(--all)
    git -C "$target" rev-parse --git-dir >/dev/null 2>&1 \
        || die "not a git repository: $target"
    require_scanner
    scratch_init
    self_test
    assert_no_ignore_file "$target"
    assert_no_ignore_in_history "$target" "${log_opts[@]}"
    work="$(work_dir "$target")" || exit 2
    report="$work/history.json"
    log="$SCRATCH/history.log"
    LAST_REPORT="$report"
    TARGET_ABS="$target"

    # gitleaks exits 0 when a bad revision range selects nothing, so the range
    # is resolved here first and an empty selection is an error, not a pass.
    expected=$(git -C "$target" rev-list --count "${log_opts[@]}" 2>/dev/null)
    [ -n "$expected" ] && [ "$expected" -gt 0 ] 2>/dev/null \
        || die "revision range selects no commits: ${log_opts[*]}"

    # gitleaks' --log-opts is a single string, so the argv array is serialised
    # exactly once, here, at that boundary only.
    serialised_opts="${log_opts[*]} --diff-merges=first-parent"

    # Plain `git log -p` omits merge diffs, so a secret added only by a merge
    # resolution is invisible; first-parent diffs put it back in scope.
    scan "$report" "$log" git "$target" --log-opts="$serialised_opts"
    rc=$?
    scanned=$(sed -n 's/.*[^0-9]\([0-9]\{1,\}\) commits scanned.*/\1/p' "$log" | tail -1)
    cat "$log" >&2
    [ -n "$scanned" ] && [ "$scanned" -gt 0 ] 2>/dev/null \
        || die "scanner reported no commits scanned for: ${log_opts[*]}"

    case $rc in
        0) printf 'history scan: clean (%s commits selected, %s scanned)\n' \
            "$expected" "$scanned" ;;
        "$FINDING_RC")
            report_findings "$report" history
            found=1
            ;;
        *) die "gitleaks git exited $rc" ;;
    esac

    scan_messages "$target" "${log_opts[@]}" || {
        found=1
        MESSAGE_FINDINGS=1
    }
    return "$found"
}

# Stable per-finding identity, printed and compared as
# "<rule>\t<repo-relative path>\t<fingerprint>". The fingerprint hashes the
# rule, the path, gitleaks' redacted Match and its Entropy - all properties of
# the finding's own content, never its line number, so an edit elsewhere in the
# file leaves it unchanged while a different secret in a file that already
# carries a declared false positive produces a new identity. Match is already
# redacted (--redact=100) and only its hash is ever emitted.
reconcile() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import collections, hashlib, json, os, sys

report_path, expected_path, root, mode = sys.argv[1:5]


def identity(finding):
    path = finding.get("File", "")
    if os.path.isabs(path):
        path = os.path.relpath(path, root)
    rule = finding.get("RuleID", "?")
    entropy = "%.6f" % float(finding.get("Entropy") or 0.0)
    material = "\0".join([rule, path, finding.get("Match", ""), entropy])
    return "%s\t%s\t%s" % (rule, path, hashlib.sha256(material.encode()).hexdigest()[:16])


# A missing report is the no-findings case; it can never read as a pass,
# because the caller has already refused to run with an empty declaration set.
findings = []
if os.path.isfile(report_path):
    try:
        with open(report_path) as handle:
            findings = json.load(handle)
    except (OSError, ValueError) as exc:
        print("SCAN-ERROR\tunreadable report: %s" % exc, file=sys.stderr)
        sys.exit(2)

actual = collections.Counter(identity(f) for f in findings)
expected = collections.Counter(
    line.rstrip("\n")
    for line in open(expected_path)
    if line.strip() and not line.lstrip().startswith("#")
)

# History compares distinct identities: every edit of a declared line re-adds
# it as a new finding, while tree multiplicity is the tree gate's job.
if mode == "history":
    actual = collections.Counter(set(actual))
    expected = collections.Counter(set(expected))

# Fail closed: an all-comment declaration file would otherwise turn the gate
# into "report whatever you find", which is what a rubber stamp looks like.
if not expected:
    print("SCAN-ERROR\tno declarations in %s" % expected_path, file=sys.stderr)
    sys.exit(2)

rc = 0
for line, n in sorted((actual - expected).items()):
    print("UNEXPECTED\t%s\t(x%d)" % (line, n), file=sys.stderr)
    rc = 1
for line, n in sorted((expected - actual).items()):
    print("DECLARED-BUT-ABSENT\t%s\t(x%d)" % (line, n), file=sys.stderr)
    rc = 1
if rc:
    print(
        "%s gate: findings do not match %s - an undeclared finding is a leak "
        "until proven otherwise; a declaration nothing produced must be deleted"
        % (mode, expected_path),
        file=sys.stderr,
    )
else:
    print("%s gate: %d finding(s), all declared" % (mode, sum(actual.values())))
sys.exit(rc)
PYEOF
}

# Blocking form: scan this repository and reconcile. Every scanner-level
# failure below (missing binary, gutted ruleset, zero bytes read, empty
# revision range) has already exited 2 via die before reconciliation runs.
gate() {
    local kind="$1" expected="${2:-$EXPECTED_DEFAULT}" target="${3:-$REPO_ROOT}" final=0
    [ -s "$expected" ] || die "missing or empty expectation file: $expected"
    case "$kind" in
        tree) scan_tree "$target" ;;
        history) scan_history "$target" --all ;;
    esac
    reconcile "$LAST_REPORT" "$expected" "$TARGET_ABS" "$kind"
    case $? in
        0) ;;
        1) final=1 ;;
        *) die "$kind gate: reconciliation failed" ;;
    esac
    # Message findings are never declarable: a commit or tag message is written
    # by hand, so a secret in one is always a defect, never a false positive.
    ((MESSAGE_FINDINGS == 0)) || final=1
    return "$final"
}

case "${1:-}" in
    install) install_scanner ;;
    tree)
        shift
        scan_tree "$@"
        ;;
    history)
        shift
        scan_history "$@"
        ;;
    gate-tree)
        shift
        gate tree "$@"
        ;;
    gate-history)
        shift
        gate history "$@"
        ;;
    -h | --help | help) usage ;;
    *)
        usage >&2
        die "unknown mode: ${1:-<none>}"
        ;;
esac

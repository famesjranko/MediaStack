# tests/lib/ratchet.sh — shared shrink-only allowlist-ratchet algorithm.
# Sourced by tests/shell-line-cap.sh and tests/python-complexity.sh (and used
# for baseline resolution by tests/naming.sh's plain-path allowlist). No side
# effects at source time.
#
# A ratchet allowlist grandfathers pre-existing offenders: an entry may only
# shrink or stay, and no new entry may appear versus the baseline. Both
# callers key an entry on one or more leading tab-separated fields with a
# trailing numeric value ("file\tcount" or "file\tfunc\tcount"); this module
# treats everything before the last tab as the key and the last field as the
# value, so it does not care how many key columns a caller uses.

# ratchet_base_ref REPO_ROOT
# Prints the git ref an allowlist ratchets against: the merge-base of HEAD
# and origin/main when origin/main resolves, else the merge-base of HEAD and
# a local main, else HEAD^, else HEAD. A merge-base — not a moving branch
# tip — is what keeps a multi-commit branch from smuggling a new allowlist
# entry past "no new entries" one commit at a time.
#
# Fails (returns 1) in a shallow clone with no reachable main: the fallbacks
# would degrade the baseline to HEAD itself there — the tree under test —
# and every allowlist entry would look pre-existing. A depth-1 CI checkout
# is exactly that environment, so it must fail closed, not pass open.
ratchet_base_ref() {
    local repo_root="$1" ref
    if [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)" == true ]] \
        && ! git -C "$repo_root" rev-parse -q --verify origin/main >/dev/null 2>&1 \
        && ! git -C "$repo_root" rev-parse -q --verify main >/dev/null 2>&1; then
        printf 'ratchet: shallow clone with no reachable main — the baseline would be HEAD itself; fetch full history (CI: fetch-depth: 0)\n' >&2
        return 1
    fi
    if git -C "$repo_root" rev-parse -q --verify origin/main >/dev/null 2>&1; then
        if ref=$(git -C "$repo_root" merge-base HEAD origin/main 2>/dev/null) && [[ -n "$ref" ]]; then
            printf '%s\n' "$ref"
            return 0
        fi
    fi
    if git -C "$repo_root" rev-parse -q --verify main >/dev/null 2>&1; then
        if ref=$(git -C "$repo_root" merge-base HEAD main 2>/dev/null) && [[ -n "$ref" ]]; then
            printf '%s\n' "$ref"
            return 0
        fi
    fi
    if ref=$(git -C "$repo_root" rev-parse HEAD^ 2>/dev/null) && [[ -n "$ref" ]]; then
        printf '%s\n' "$ref"
        return 0
    fi
    printf 'HEAD\n'
}

# ratchet_split_key_value LINE -> sets RATCHET_KEY and RATCHET_VALUE
# Splits a tab-separated allowlist line into its key (every field but the
# last, tab-joined) and its trailing numeric value. Returns 1 on a line with
# fewer than two tab-separated fields.
ratchet_split_key_value() {
    local line="$1"
    [[ "$line" == *$'\t'* ]] || return 1
    RATCHET_VALUE="${line##*$'\t'}"
    RATCHET_KEY="${line%$'\t'*}"
}

# ratchet_read_base REPO_ROOT BASE_REF PATH_IN_REPO OUT_ARRAY_NAME
# Populates the nameref associative array OUT_ARRAY_NAME (key -> recorded
# value) from PATH_IN_REPO as it existed at BASE_REF, or leaves it empty if
# the path did not exist there. Prints nothing; malformed lines are the
# caller's own allowlist-reading pass's problem, not this one's — the base
# copy is trusted to already have passed this same gate at BASE_REF.
ratchet_read_base() {
    local repo_root="$1" base_ref="$2" path_in_repo="$3" out_name="$4"
    local -n out_ref="$out_name"
    out_ref=()
    git -C "$repo_root" cat-file -e "$base_ref:$path_in_repo" 2>/dev/null || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        ratchet_split_key_value "$line" || continue
        # shellcheck disable=SC2034  # out_ref is a nameref; shellcheck can't see the caller's array take the write
        out_ref["$RATCHET_KEY"]="$RATCHET_VALUE"
    done < <(git -C "$repo_root" show "$base_ref:$path_in_repo")
}

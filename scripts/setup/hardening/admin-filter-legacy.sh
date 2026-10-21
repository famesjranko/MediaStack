# Owns: detection and removal of the legacy UFW after.rules / after6.rules blocks and the after.init dedup hook that earlier versions wrote.
# Sources: hardening.sh globals (MEDIASTACK_UFW_AFTER*), the ledger helpers and common.sh logging; sourced by admin-filter.sh.

# Whole-line markers. The begin line is the bare marker or the marker plus the
# description MediaStack wrote (hyphen or em dash, optional "(IPv6)"). A user
# line such as "# MEDIASTACK-DOCKER-RULES-NOTE" must not open a block. A
# trailing CR is allowed only so a CRLF file is detected and refused with a
# clear message instead of being skipped.
_ADMIN_FILTER_RULES_BEGIN_RE=$'^# MEDIASTACK-DOCKER-RULES( (-|—) restrict Docker management ports to LAN( [(]IPv6[)])?)?\r?$'
# What is left of the after.init the old hook created when its block is taken
# out. Only a file that reduces to exactly this is deleted whole; a header line
# alone proves nothing, as an administrator may have added hooks under it.
_ADMIN_FILTER_DEDUP_SKELETON=$'#!/bin/sh\n# after.init — MediaStack-managed; trims duplicate DOCKER-USER jumps.\nset -e\ncase "$1" in\nstart)\n    ;;\nesac'
_ADMIN_FILTER_DEDUP_BEGIN_RE=$'^# >>> MEDIASTACK-DOCKER-DEDUP( [(]issue #214[)])?( — keep exactly one DOCKER-USER→RESTRICT jump)?\r?$'

# Prints the legacy after.rules / after6.rules files that still hold a
# MediaStack block. Detected by content: the block was never ledgered.
_admin_filter_legacy_files() {
    local f
    for f in "$MEDIASTACK_UFW_AFTER_RULES" "$MEDIASTACK_UFW_AFTER6_RULES"; do
        if sudo grep -Eq "$_ADMIN_FILTER_RULES_BEGIN_RE" "$f" 2>/dev/null; then
            printf '%s\n' "$f"
        fi
    done
}

# Strip MediaStack's marker-delimited block from one file. Removes the block and
# the single blank line the old writer put in front of it; every other byte
# stays. A begin marker with no end marker is not a block we wrote: the file is
# left untouched and the strip fails, because deleting to end of file would
# take the user's rules with it.
_admin_filter_strip_file() {
    local f="$1" in_f out_f rc=0
    in_f=$(mktemp)
    out_f=$(mktemp)
    # shellcheck disable=SC2024  # sudo reads the root-owned file; $in_f is our own scratch file
    sudo cat "$f" >"$in_f" || rc=1
    if ((rc == 0)) && _admin_filter_has_crlf "$in_f"; then
        log_error "$f has CRLF line endings, so MediaStack cannot find its block markers; convert it to LF line endings and re-run (leaving the file alone)"
        rc=1
    elif ((rc == 0)); then
        if awk -v begin_re="$_ADMIN_FILTER_RULES_BEGIN_RE" '
            function flush_held() { if (held) { print ""; held = 0 } }
            inb { if ($0 == "# END MEDIASTACK-DOCKER-RULES") inb = 0; next }
            $0 ~ begin_re { held = 0; inb = 1; next }
            $0 == "" { flush_held(); held = 1; next }
            { flush_held(); print }
            END { flush_held(); exit inb ? 3 : 0 }
        ' "$in_f" >"$out_f"; then
            # shellcheck disable=SC2024  # tee's target needs sudo, $out_f is our own scratch file
            sudo tee "$f" >/dev/null <"$out_f" || rc=1
        else
            log_error "$f has a MediaStack block without its end marker; leaving the file alone"
            rc=1
        fi
    fi
    rm -f "$in_f" "$out_f"
    return "$rc"
}

# 0 when the scratch file holds a line ending in CR.
_admin_filter_has_crlf() { grep -q $'\r$' "$1"; }

# Strip MediaStack's blocks from after.rules and after6.rules. Succeeds when
# nothing was there. No ufw reload: the live chain is not ufw's to drop, and the
# next ufw load simply no longer carries the block.
_admin_filter_strip_ufw_blocks() {
    local f rc=0
    while IFS= read -r f; do
        _admin_filter_strip_file "$f" || rc=1
    done < <(_admin_filter_legacy_files)
    return "$rc"
}

# Take MediaStack's DOCKER-USER dedup block out of /etc/ufw/after.init. An
# earlier version installed it to trim the jumps that after.rules appended; now
# it would delete the unit's own jump. A file that is exactly what MediaStack
# created (nothing but its block around the skeleton) is removed; otherwise only the block goes and the mode is
# put back, so an admin's file ends byte-identical to what it was. A file with
# CRLF line endings, or a begin marker without a following end marker, is left
# untouched and the strip fails: a range delete would run to end of file.
_admin_filter_strip_dedup_hook() {
    local f="$MEDIASTACK_UFW_AFTER_INIT" in_f out_f rc=0
    sudo test -f "$f" && sudo grep -q 'MEDIASTACK-DOCKER-DEDUP' "$f" || return 0
    in_f=$(mktemp)
    out_f=$(mktemp)
    # shellcheck disable=SC2024  # sudo reads the root-owned file; $in_f is our own scratch file
    sudo cat "$f" >"$in_f" || rc=1
    if ((rc != 0)); then
        :
    elif _admin_filter_has_crlf "$in_f"; then
        log_error "$f has CRLF line endings, so MediaStack cannot find its block markers; convert it to LF line endings and re-run (leaving the file alone)"
        rc=1
    elif ! awk -v begin_re="$_ADMIN_FILTER_DEDUP_BEGIN_RE" '
            inb { if ($0 == "# <<< MEDIASTACK-DOCKER-DEDUP") inb = 0; next }
            $0 ~ begin_re { inb = 1; next }
            { print }
            END { exit inb ? 3 : 0 }
        ' "$in_f" >"$out_f"; then
        log_error "$f has a MediaStack block without its end marker; leaving the file alone"
        rc=1
    elif [[ "$(cat "$out_f")" == "$_ADMIN_FILTER_DEDUP_SKELETON" ]]; then
        sudo rm -f "$f" || rc=1
    elif ! cmp -s "$in_f" "$out_f"; then
        # shellcheck disable=SC2024  # tee's target needs sudo, $out_f is our own scratch file
        sudo tee "$f" >/dev/null <"$out_f" || rc=1
        if ((rc == 0)) && [[ "$(_ms_state_get UFW_AFTER_INIT_ACTIVATED 2>/dev/null || true)" == "true" ]]; then
            sudo chmod 640 "$f" || rc=1
        fi
    else
        # The file only mentions the marker; there is no block of ours to take out.
        rm -f "$in_f" "$out_f"
        return 0
    fi
    rm -f "$in_f" "$out_f"
    ((rc == 0)) || return 1
    _admin_filter_ledger UFW_AFTER_INIT_CREATED false
    _admin_filter_ledger UFW_AFTER_INIT_ACTIVATED false
}

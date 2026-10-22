#!/usr/bin/env bash
# tests/unit/sbin-tools.sh
#
# Repo-wide guard: a script must not call a /usr/sbin or /sbin tool by bare
# name. Debian leaves those directories off a normal user's PATH, so a bare
# `dkms status` or `command -v ufw` reports an installed tool as missing (the
# GPU round 1A defect: a built NVIDIA module looked unbuilt). Use `sudo TOOL`,
# host_tool_path / host_tool_installed, or an explicit /usr/sbin path.
# Standalone: bash tests/unit/sbin-tools.sh
# MS_SBIN_GUARD_ROOT points the scan at another checkout (used to prove the
# guard is red on a tree that still has the bare calls).

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
SCAN_ROOT="${MS_SBIN_GUARD_ROOT:-$REPO_ROOT}"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC2034 # read by tests/lib/assert.sh for failure labels
CURRENT_SCENARIO="sbin-tools"
scenario_begin "$CURRENT_SCENARIO"

# Tools the scripts call that Debian installs under /usr/sbin or /sbin.
# Left out on purpose: mokutil and ip (Debian ships both in /usr/bin) and service
# (only called as `sudo service`; the word is too common in prose and Python).
SBIN_TOOLS='dkms|modprobe|rmmod|insmod|lsmod|depmod|update-initramfs|update-grub|visudo|ufw|iptables|ip6tables|iptables-save|iptables-restore|ip6tables-save|ip6tables-restore|sysctl|smbd|nmbd|pdbedit|smbpasswd|mount\.nfs4?|mount\.cifs|exportfs|showmount|sshd|usermod|groupadd|groupmod|useradd|userdel|chpasswd|adduser|deluser|ldconfig|blkid|fdisk|sgdisk|fsck|swapon|mkswap|losetup|tune2fs|chroot|reboot|shutdown|update-ca-certificates|nologin'

# Exceptions: "path-suffix|reason". A listed file may use any sbin tool bare.
ALLOW=(
    # The apply script runs as root from a systemd oneshot (and via `sudo`),
    # where PATH already includes the sbin directories.
    "scripts/setup/hardening/admin-filter.sh|runs only as root: systemd oneshot and sudo-invoked apply script"
    # `command -v sshd` is followed by an explicit /usr/sbin/sshd fallback.
    "scripts/setup/hardening/ssh.sh|falls back to the explicit /usr/sbin/sshd path"
)

# Prints "file:line:text" for each bare sbin call in a file.
bare_sbin_calls() {
    local file="$1"
    # A tool is "bare" at command position (after ; && || | ( { ! then do else,
    # an optional wrapper such as timeout/env), as `command -v TOOL`, or as the
    # command handed to ui_spin "label". `sudo TOOL` never matches: sudo sits
    # between the separator and the tool.
    local sep='(?:^|[;&|{!`]|\$\(|\bthen\b|\bdo\b|\belse\b)\s*'
    local wrap='(?:(?:timeout|nice|nohup|env|exec)\s+(?:-\S+\s+|[0-9]+[smh]?\s+|\w+=\S+\s+)*)?'
    local tail='(?=\s|$|;|\)|\|)(?!\s*\(\))'
    local re="(?:${sep}${wrap}|\\bcommand\\s+-v\\s+|\\btype\\s+-P\\s+|\\bui_spin\\s+\"[^\"]*\"\\s+)(?:${SBIN_TOOLS})${tail}"
    grep -nP -- "$re" "$file" | grep -vP '^\d+:\s*#' | sed "s|^|${file#"$SCAN_ROOT"/}:|"
}

is_allowed() {
    local rel="$1" entry
    for entry in "${ALLOW[@]}"; do
        [[ "$rel" == "${entry%%|*}" ]] && return 0
    done
    return 1
}

# Given every shell script the product ships (scripts/, setup.sh, mediastack),
# When each line is checked for a bare sbin tool call,
# Then no script outside the justified exceptions makes one.
mapfile -t files < <(
    {
        find "$SCAN_ROOT/scripts" -type f -name '*.sh'
        printf '%s\n' "$SCAN_ROOT/setup.sh" "$SCAN_ROOT/mediastack"
    } | sort
)
hits=""
for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    rel="${f#"$SCAN_ROOT"/}"
    is_allowed "$rel" && continue
    found="$(bare_sbin_calls "$f")"
    [[ -n "$found" ]] && hits+="${found}"$'\n'
done
hits="${hits%$'\n'}"
if [[ -z "$hits" ]]; then
    pass "sbin-tools: no script calls a /usr/sbin tool by bare name"
else
    fail "sbin-tools: no script calls a /usr/sbin tool by bare name" $'\n'"$hits"
fi

# Given a script fixture with one bare call and one call per accepted form,
# When the detector scans it,
# Then it reports only the bare call (the guard can fail, and does not over-fire).
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
SCAN_ROOT="$fixture"
cat >"$fixture/probe.sh" <<'SH'
bare() { dkms status -k "$1"; }
viasudo() { sudo dkms status; }
viahelper() { "$(host_tool_path dkms)" status; }
viapath() { /usr/sbin/dkms status; }
inpipe() { echo x | sysctl -n a; }
probe() { command -v ufw >/dev/null; }
wrapped() { ui_spin "msg" modprobe nvidia; }
# dkms in a comment
msg() { log_info "run dkms later"; }
SH
found="$(bare_sbin_calls "$fixture/probe.sh" | cut -d: -f2 | tr '\n' ' ')"
assert_eq "1 5 6 7 " "$found" "sbin-tools: detector flags bare, piped, command -v and ui_spin forms only"

summary

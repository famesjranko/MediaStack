# Owns: host_tool_path / host_tool_installed / ufw_installed - lookup of root-only host tools.
# Sourced by every module that looks up a root tool; sets no shell options.

# Debian puts root tools (ufw, visudo, mount.nfs, sshd, ...) in /usr/sbin and
# /sbin, which a normal user's PATH omits, so a bare `command -v` reports an
# installed tool as missing. MS_SBIN_DIRS is the test override.
host_tool_path() {
    local name="$1" found dir
    if found="$(command -v "$name" 2>/dev/null)" && [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    for dir in ${MS_SBIN_DIRS:-/usr/sbin /sbin}; do
        if [[ -x "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

host_tool_installed() { host_tool_path "$1" >/dev/null; }

# MS_UFW_SBIN_PATH (one file path) predates MS_SBIN_DIRS; the UFW tests still set it.
ufw_installed() { host_tool_installed ufw || [[ -x "${MS_UFW_SBIN_PATH:-}" ]]; }

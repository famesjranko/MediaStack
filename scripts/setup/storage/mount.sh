# Owns: NFS mounting, mismatched-mount repair, and non-destructive NAS probing.
# Sourced by scripts/setup/storage.sh; depends on storage/core.sh helpers
# (storage_mountpoint, storage_mount_matches, storage_log_*, etc.).

storage_repair_mismatched_mount() {
    local mountpoint live_source live_fstype expected_source

    storage_mount_matches && return 0
    storage_mountpoint_has_mount || return 0

    mountpoint="$(storage_mountpoint)"
    live_source="$(storage_findmnt_source)"
    live_fstype="$(storage_findmnt_fstype)"
    expected_source="$(storage_expected_source)"

    storage_log_warn "A different filesystem is mounted at ${mountpoint}: ${live_source:-unknown} (${live_fstype:-unknown}); expected ${expected_source:-unknown}."
    if declare -F ui_confirm >/dev/null; then
        if ! ui_confirm "Detach the existing mount and mount the selected NAS here?" "yes"; then
            storage_log_warn "Keeping existing mount at ${mountpoint}; NAS mount was not changed."
            return 1
        fi
    fi

    storage_log_info "Detaching existing mount at ${mountpoint} before mounting selected NAS..."
    if ! sudo umount -l "$mountpoint"; then
        storage_log_err "Could not detach existing mount at ${mountpoint}."
        return 1
    fi
}

storage_mount_nfs() {
    local mountpoint
    mountpoint="$(storage_mountpoint)"
    local host="${STORAGE_NFS_HOST:-}"
    local export_path="${STORAGE_NFS_EXPORT:-}"
    local opts="${STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}"

    if [[ -z "$host" || -z "$export_path" ]]; then
        storage_log_err "NAS storage selected but NFS host/export is missing."
        return 1
    fi

    if storage_mount_matches; then
        return 0
    fi

    storage_repair_mismatched_mount || return 1

    sudo mkdir -p "$mountpoint" || return 1
    storage_log_info "Mounting NFS storage ${host}:${export_path} at ${mountpoint}..."
    if sudo mount -t nfs4 -o "$opts" "${host}:${export_path}" "$mountpoint"; then
        storage_log_ok "NFS mount active at ${mountpoint}"
        return 0
    fi

    storage_log_warn "NFSv4 mount failed; retrying with generic nfs type."
    sudo mount -t nfs -o "$opts" "${host}:${export_path}" "$mountpoint"
}

storage_ensure_nfs_common() {
    if command -v mount.nfs >/dev/null 2>&1 || command -v mount.nfs4 >/dev/null 2>&1; then
        return 0
    fi
    storage_log_info "Installing nfs-common for NAS storage..."
    sudo apt-get update -qq >/dev/null 2>&1 || true
    ui_spin "Installing nfs-common..." sudo apt-get install -y -qq nfs-common
}

# TCP reachability probe. Reuses the codebase nc idiom (network.sh) with a
# /dev/tcp fallback so it works without netcat installed.
storage_host_port_open() {
    local host="$1" port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w5 "$host" "$port" >/dev/null 2>&1 && return 0
        return 1
    fi
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

# Turn the user's real mount options into fail-fast probe options: a bad target
# must error out, not hang. Strip hard/soft/timeo/retrans, force soft + short
# timeout so an unreachable export fails in ~10s instead of retrying forever.
storage_probe_opts() {
    local opts="${1:-vers=4.2,proto=tcp,rw}"
    local cleaned
    cleaned=$(printf '%s' "$opts" \
        | tr ',' '\n' \
        | grep -viE '^(hard|soft|timeo=.*|retrans=.*)$' \
        | paste -sd, -)
    printf '%s' "${cleaned:+${cleaned},}soft,timeo=50,retrans=2"
}

# Non-destructive NAS verification for the wizard. Mounts the export to a
# THROWAWAY temp dir (never the real mountpoint), runs discrete checks with one
# line each, classifies the share, then unmounts. Because it never touches the
# real mountpoint, no mismatch/detach can ever happen. Sets _STORAGE_PROBE_CLASS
# on success. Returns 0 only if reachable + mountable + readable + writable.
storage_probe_nas() {
    local host="${STORAGE_NFS_HOST:-}"
    local export_path="${STORAGE_NFS_EXPORT:-}"
    local opts probe_opts tmp rc=0
    opts="${STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}"
    _STORAGE_PROBE_CLASS=""

    if [[ -z "$host" || -z "$export_path" ]]; then
        storage_log_err "NAS storage selected but NFS host/export is missing."
        return 1
    fi

    # 1. NAS reachable (NFSv4 port 2049; fall back to rpcbind 111 for v3).
    if storage_host_port_open "$host" 2049 || storage_host_port_open "$host" 111; then
        storage_log_ok "NAS reachable ($host)"
    else
        storage_log_err "NAS not reachable at ${host}:2049 (host down or firewalled)."
        return 1
    fi

    if ! tmp=$(mktemp -d 2>/dev/null); then
        storage_log_err "Could not create a temporary directory to test the NAS mount."
        return 1
    fi

    # 2. Export mountable — temp mount with fail-fast opts, never the real mountpoint.
    probe_opts="$(storage_probe_opts "$opts")"
    if ui_spin "Testing NFS export ${host}:${export_path}..." \
        sudo mount -t nfs4 -o "$probe_opts" "${host}:${export_path}" "$tmp" \
        || sudo mount -t nfs -o "$probe_opts" "${host}:${export_path}" "$tmp" >/dev/null 2>&1; then
        storage_log_ok "NFS export available (${export_path})"
    else
        storage_log_err "NFS export not found or not permitted for this host (${host}:${export_path})."
        rmdir "$tmp" 2>/dev/null || true
        return 1
    fi

    # 3. Readable.
    if ls "$tmp" >/dev/null 2>&1; then
        storage_log_ok "Share is readable"
    else
        storage_log_err "Share mounted but is not readable."
        rc=1
    fi

    # 4. Writable — tested as the install user (not sudo), mirroring how
    #    MediaStack actually creates directories and the sentinel. Catches
    #    read-only exports and root-squash that would block managed writes.
    if [[ $rc -eq 0 ]]; then
        if touch "$tmp/.mediastack-probe" >/dev/null 2>&1; then
            rm -f "$tmp/.mediastack-probe" 2>/dev/null || true
            storage_log_ok "Share is writable"
        else
            storage_log_err "Share is read-only for this host (check the NFS export's rw option + squash)."
            rc=1
        fi
    fi

    # 5. Classify while still mounted, then always unmount + clean up the temp dir.
    if [[ $rc -eq 0 ]]; then
        _STORAGE_PROBE_CLASS="$(storage_classify_data_root "$tmp")"
    fi
    sudo umount -l "$tmp" >/dev/null 2>&1 || true
    rmdir "$tmp" 2>/dev/null || true
    return "$rc"
}

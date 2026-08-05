# Owns: env persistence, data-root classification, and the NAS preflight/
# guard-before-start orchestration. Sourced by scripts/setup/storage.sh;
# depends on storage/core.sh and storage/mount.sh helpers.

storage_env_set() {
    local key="$1" value="$2" env_file="${SCRIPT_DIR:-$(pwd)}/.env"
    [[ -f "$env_file" ]] || return 0
    # One blessed .env writer (common.sh) — atomic, mode-preserving, quoted.
    _env_write_kv "$env_file" "$key" "$value" >/dev/null || return 1
}

storage_classify_data_root() {
    local data_dir="${1:-${DATA_DIR:-/data}}"
    if [[ ! -d "$data_dir" ]]; then
        printf '%s\n' missing
        return 0
    fi
    if [[ -e "$data_dir/media" && ! -d "$data_dir/media" ]]; then
        printf '%s\n' conflict:media
        return 0
    fi
    if [[ -e "$data_dir/torrents" && ! -d "$data_dir/torrents" ]]; then
        printf '%s\n' conflict:torrents
        return 0
    fi
    if find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        if [[ -d "$data_dir/media" && -d "$data_dir/torrents" ]]; then
            printf '%s\n' mediastack
        else
            printf '%s\n' nonempty
        fi
    else
        printf '%s\n' empty
    fi
}

storage_preflight_nas() {
    storage_is_nas || return 0

    storage_ensure_nfs_common

    storage_mount_nfs || return 1

    local source fstype sentinel
    source="$(storage_findmnt_source)"
    fstype="$(storage_findmnt_fstype)"
    storage_env_set STORAGE_EXPECTED_SOURCE "$source" || return 1
    storage_env_set STORAGE_EXPECTED_FSTYPE "$fstype" || return 1
    export STORAGE_EXPECTED_SOURCE="$source"
    export STORAGE_EXPECTED_FSTYPE="$fstype"

    sentinel="$(storage_sentinel_path)"
    if ! storage_sentinel_is_under_mountpoint; then
        storage_log_err "NAS sentinel must be inside the NAS mountpoint (${sentinel} is outside $(storage_mountpoint))."
        return 1
    fi
    if [[ ! -e "$sentinel" ]]; then
        storage_log_info "Creating NAS sentinel: $sentinel"
        if ! mkdir -p "$(dirname "$sentinel")" 2>/dev/null || ! touch "$sentinel" 2>/dev/null; then
            storage_log_err "Could not create NAS sentinel at $sentinel."
            return 1
        fi
    fi

    if ! storage_nas_ok; then
        storage_log_err "NAS storage check failed: mount identity or sentinel did not verify."
        return 1
    fi

    storage_log_ok "NAS storage verified (${source}, ${fstype}, sentinel=${sentinel})"
}

storage_guard_before_start() {
    storage_is_nas || return 0
    storage_watchdog_enabled || return 0
    if storage_nas_ok; then
        return 0
    fi
    storage_log_err "Refusing to start MediaStack: NAS storage is not mounted and verified."
    storage_log_err "Expected: source=$(storage_expected_source), sentinel=$(storage_sentinel_path)"
    return 1
}

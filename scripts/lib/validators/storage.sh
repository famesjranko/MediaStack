# Owns: Data dir, NAS mountpoint, NFS, and storage-sentinel path validators.
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.

validate_data_dir() {
    local path="$1"
    if [[ -z "$path" ]]; then
        ui_log warn "Data directory path is required."
        return 1
    fi
    # Whitelist: letters, digits, '/', '.', '_', '-'. Anything else (single
    # quotes, $, backtick, ;, =, whitespace, newlines, ...) is rejected.
    # This subsumes the shell-metacharacter guard and additionally
    # blocks characters that silently corrupt downstream parsers:
    #   - '='     breaks awk -F= in _resolve_data_partition / .env parsers
    #   - newline breaks 'awk NR==2' parse of df output and .env line itself
    #   - trailing whitespace silently mismatches '[[ -d "$DATA_DIR" ]]'
    # The whitelist is conservative for a non-technical-user audience whose
    # paths are realistically /data, /srv/media, /mnt/storage, etc.
    if [[ "$path" =~ [^a-zA-Z0-9._/\-] ]]; then
        ui_log warn "Data directory may only contain letters, digits, '.', '_', '-', and '/'."
        return 1
    fi
    if [[ "$path" != /* ]]; then
        ui_log warn "Data directory must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$path" =~ ^/media/ ]]; then
        ui_log warn "$path looks like a removable mount point. Choose a path outside /media/."
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        if ! ui_confirm "Path $path does not exist. Create it?" "yes"; then
            ui_log warn "Data directory $path not created - pick a different path or allow creation."
            return 1
        fi
        # Try unprivileged mkdir first (works for paths under $HOME etc.).
        # Fall back to sudo for system paths like /data, /srv/media, /mnt/storage
        # whose root-owned parents need elevation. Chown back to the current
        # user so MediaStack containers (which run as the host UID/GID) can
        # write into it without further permission gymnastics.
        if mkdir -p "$path" 2>/dev/null; then
            :
        elif sudo mkdir -p "$path" 2>/dev/null && sudo chown "$(id -un):$(id -gn)" "$path" 2>/dev/null; then
            ui_log info "Created $path (root-owned parent - used sudo to create + chown to $(id -un))."
        else
            ui_log warn "Could not create $path (read-only parent or permission denied)."
            return 1
        fi
    fi

    if [[ ! -d "$path" ]]; then
        ui_log warn "$path exists but is not a directory."
        return 1
    fi
    if [[ ! -w "$path" ]]; then
        ui_log warn "$path is not writable by user $(id -un)."
        return 1
    fi

    local opts
    opts=$(findmnt -no OPTIONS --target "$path" 2>/dev/null)
    if [[ ",$opts," == *,ro,* ]]; then
        ui_log warn "$path is on a read-only filesystem."
        return 1
    fi

    local free_gb
    free_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if [[ -z "$free_gb" ]]; then
        ui_log warn "Could not read free space on $path (df returned no output)."
        return 1
    fi
    # Pre-flight already warned-but-continued for the resolved data partition at
    # startup. The validator's disk floor is a parallel safety net that fires
    # when the user picks a custom path. Match that behavior: warn + ask
    # for explicit confirmation, rather than silently looping the prompt.
    if ((free_gb < 30)); then
        ui_log warn "$path has only ${free_gb}GB free - recommended minimum is 30GB."
        if ! ui_confirm "Continue anyway?" "yes"; then
            ui_log warn "Pick a different path with more free space, or free up space on $path."
            return 1
        fi
        ui_log info "Continuing with ${free_gb}GB free at $path (below 30GB recommended)."
    fi
    return 0
}

validate_nas_mountpoint() {
    local path="$1"
    if [[ -z "$path" ]]; then
        ui_log warn "NAS mountpoint path is required."
        return 1
    fi
    if [[ "$path" =~ [^a-zA-Z0-9._/\-] ]]; then
        ui_log warn "NAS mountpoint may only contain letters, digits, '.', '_', '-', and '/'."
        return 1
    fi
    if [[ "$path" != /* ]]; then
        ui_log warn "NAS mountpoint must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$path" == "/" ]]; then
        ui_log warn "NAS mountpoint cannot be '/'."
        return 1
    fi
    if [[ "$path" =~ ^/media/ ]]; then
        ui_log warn "$path looks like a removable mount point. Choose a path outside /media/."
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        if ! ui_confirm "Mountpoint $path does not exist. Create it?" "yes"; then
            ui_log warn "NAS mountpoint $path not created - pick a different path or allow creation."
            return 1
        fi
        if mkdir -p "$path" 2>/dev/null; then
            :
        elif sudo mkdir -p "$path" 2>/dev/null; then
            ui_log info "Created NAS mountpoint $path with sudo."
        else
            ui_log warn "Could not create NAS mountpoint $path (read-only parent or permission denied)."
            return 1
        fi
    fi

    if [[ ! -d "$path" ]]; then
        ui_log warn "$path exists but is not a directory."
        return 1
    fi
    return 0
}

validate_nfs_host() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NAS host/IP is required."
        return 1
    fi
    if [[ "$value" =~ [^a-zA-Z0-9._:\-] ]]; then
        ui_log warn "NAS host/IP may only contain letters, digits, '.', ':', '_', and '-'."
        return 1
    fi
    # Dotted-quad IPv4: bound each octet to <= 255 (same shape check as
    # validate_wireguard_hostname) so 999.999.999.999 is rejected up front.
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        local -a octets
        IFS='.' read -ra octets <<<"$value"
        for octet in "${octets[@]}"; do
            # 10# forces base-10 so a leading-zero octet (08/09) isn't read as octal.
            if ((10#$octet > 255)); then
                ui_log warn "NAS IP has an octet over 255 (expected e.g. 192.168.1.10)."
                return 1
            fi
        done
        return 0
    fi
    # All-numeric with dots but not a 4-octet quad => a partial/malformed IP
    # (e.g. 192.168.1) the user almost certainly mistyped.
    if [[ "$value" =~ ^[0-9.]+$ ]]; then
        ui_log warn "That looks like an incomplete IP address - enter a full IPv4 (e.g. 192.168.1.10) or a hostname."
        return 1
    fi
    # Hostname/FQDN: reject a leading/trailing dot or an empty label. Single-label
    # LAN names (e.g. 'nas') and dotted names (nas.local) are both allowed.
    if [[ "$value" == .* || "$value" == *. || "$value" == *..* ]]; then
        ui_log warn "NAS hostname has a misplaced dot (no leading/trailing dot or empty label)."
        return 1
    fi
    return 0
}

validate_nfs_export() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NFS export path is required."
        return 1
    fi
    if [[ "$value" != /* ]]; then
        ui_log warn "NFS export must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "NFS export cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    return 0
}

validate_nfs_options() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NFS mount options are required."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "NFS mount options cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    if [[ "$value" =~ [^a-zA-Z0-9.,=_:/\-] ]]; then
        ui_log warn "NFS mount options may only contain letters, digits, '.', ',', '=', '_', ':', '/', and '-'."
        return 1
    fi
    return 0
}

validate_storage_sentinel() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Storage sentinel path is required."
        return 1
    fi
    if [[ "$value" != /* ]]; then
        ui_log warn "Storage sentinel must be an absolute path."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "Storage sentinel cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    return 0
}

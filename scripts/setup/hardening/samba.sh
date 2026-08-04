# Owns: optional SMB share setup, skip/warn behavior, and Samba teardown.
# Sources: hardening.sh Samba paths, ledger helpers, and firewall helpers.
# Globals: SAMBA_* paths, SMB_ENABLED, SMB_SHARE_SCOPE, DATA_DIR, PGID, and admin .env values.

setup_samba() {
    if [[ "${SMB_ENABLED:-false}" != "true" ]]; then
        # Cleanup path: undo a prior SMB_ENABLED=true install. Removing the
        # include file silences the [Media] share. Samba tolerates the now-
        # dangling `include = …` line in main smb.conf with just a warning,
        # so we leave it there — re-enabling SMB later just rewrites the
        # include file at the same path.
        if [[ -f "$SAMBA_INCLUDE_FILE" ]]; then
            log_info "SMB_ENABLED=false - removing MediaStack samba config..."
            sudo rm -f "$SAMBA_INCLUDE_FILE"
            sudo systemctl reload smbd >/dev/null 2>&1 || true
            if [[ "$(_ms_state_get SAMBA_CONFIGURED 2>/dev/null || true)" == "true" ]]; then
                _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
            fi
            log_ok "MediaStack samba config removed (user samba config preserved)"
        fi
        return
    fi

    local admin_user="${JELLYFIN_ADMIN_USER:-admin}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-changeme}"
    local smb_scope="${SMB_SHARE_SCOPE:-data}"
    local share_name share_comment share_path
    case "$smb_scope" in
        system)
            share_name="MediaStackSystem"
            share_comment="MediaStack full system access"
            share_path="/"
            ;;
        data | "")
            share_name="Media"
            share_comment="MediaStack data directory"
            share_path="${DATA_DIR:-/data}"
            ;;
        *)
            log_warn "Unknown SMB_SHARE_SCOPE='$smb_scope' - using data-only share"
            smb_scope="data"
            share_name="Media"
            share_comment="MediaStack data directory"
            share_path="${DATA_DIR:-/data}"
            ;;
    esac

    # The functional, byte-stable idempotency marker: the include line itself.
    local include_line="include = $SAMBA_INCLUDE_FILE"

    # Idempotency: include file present AND include line present in main conf.
    # If the requested scope differs from an existing generated include, warn
    # and leave it alone. Re-runs must not silently rewrite host file-sharing
    # scope behind the user's back.
    if [[ -f "$SAMBA_INCLUDE_FILE" ]] \
        && sudo grep -Fxq "$include_line" "$SAMBA_MAIN_CONF" 2>/dev/null; then
        if sudo grep -Fxq "[$share_name]" "$SAMBA_INCLUDE_FILE" 2>/dev/null \
            && sudo grep -Fxq "   path = $share_path" "$SAMBA_INCLUDE_FILE" 2>/dev/null; then
            if [[ "$(_ms_state_get SAMBA_SETUP_PENDING 2>/dev/null || true)" == "true" ]]; then
                local expected_hash
                expected_hash=$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)
                if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]] \
                    || [[ "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")" != "$expected_hash" ]]; then
                    log_warn "Interrupted Samba setup has an edited or unverifiable include; leaving it unchanged"
                    return 0
                fi
                # Resume below: user/group, service, firewall, and final ledger
                # writes are idempotent and may not have completed before interruption.
            elif [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || true)" == "true" ]]; then
                _ms_state_set SAMBA_INCLUDE_SHA256 "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")"
                _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
                _ms_state_set SAMBA_CONFIGURED true
                log_skip "Samba already configured"
                return 0
            else
                log_skip "Samba already configured"
                return 0
            fi
        else
            log_warn "Samba already configured with a different MediaStack share scope; leaving existing SMB config unchanged."
            return 0
        fi
    fi

    # Same hardcoded-1000 trap as create_data_dirs: when .env hasn't been
    # generated yet, falling back to 1000 picks the wrong group on hosts
    # where the operator isn't uid 1000. Use the operator's actual gid so
    # SMB admin is added to the right group for /data access.
    local pgid="${PGID:-$(id -g)}"

    log_info "Configuring SMB file share..."

    local ownership_recorded passdb_preexisted group_preexisted gid_group
    ownership_recorded=$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || echo false)
    if [[ "$ownership_recorded" == "false" ]]; then
        local samba_was_present=false service_was_enabled=false service_was_active=false user_preexisted=false
        passdb_preexisted=false
        command -v smbd &>/dev/null && samba_was_present=true
        if $samba_was_present; then
            sudo systemctl is-enabled smbd >/dev/null 2>&1 && service_was_enabled=true
            sudo systemctl is-active smbd >/dev/null 2>&1 && service_was_active=true
            sudo pdbedit -L -u "$admin_user" >/dev/null 2>&1 && passdb_preexisted=true
        fi
        id "$admin_user" &>/dev/null && user_preexisted=true
        gid_group=$(getent group "$pgid" | cut -d: -f1)
        group_preexisted=true
        if [[ -n "$gid_group" && "$user_preexisted" == "true" ]]; then
            id -nG "$admin_user" | tr ' ' '\n' | grep -Fxq "$gid_group" || group_preexisted=false
        elif [[ -n "$gid_group" ]]; then
            group_preexisted=false
        fi
        _ms_state_set SAMBA_SERVICE_WAS_ENABLED "$service_was_enabled"
        _ms_state_set SAMBA_SERVICE_WAS_ACTIVE "$service_was_active"
        _ms_state_set SAMBA_USER "$admin_user"
        _ms_state_set SAMBA_USER_PREEXISTED "$user_preexisted"
        _ms_state_set SAMBA_PASSDB_PREEXISTED "$passdb_preexisted"
        _ms_state_set SAMBA_GROUP "$gid_group"
        _ms_state_set SAMBA_GROUP_PREEXISTED "$group_preexisted"
        _ms_state_set SAMBA_SETUP_PENDING true
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK false
        _ms_state_set SAMBA_GROUP_ADDED_BY_MEDIASTACK false
        _ms_state_set SAMBA_OWNERSHIP_RECORDED true
        if ! $samba_was_present; then
            _ms_state_set SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK true
            ui_spin "Installing samba..." sudo apt-get install -y -qq samba
        fi
    else
        if [[ "$(_ms_state_get SAMBA_USER)" != "$admin_user" ]]; then
            log_warn "Samba owner changed after setup; leaving existing Samba configuration unchanged"
            return 0
        fi
        if ! command -v smbd &>/dev/null; then
            if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK)" != "true" ]]; then
                log_warn "Recorded Samba package is missing; leaving state unchanged"
                return 0
            fi
            ui_spin "Retrying Samba installation..." sudo apt-get install -y -qq samba
        fi
        passdb_preexisted=$(_ms_state_get SAMBA_PASSDB_PREEXISTED)
        group_preexisted=$(_ms_state_get SAMBA_GROUP_PREEXISTED)
        gid_group=$(_ms_state_get SAMBA_GROUP)
    fi

    if ! id "$admin_user" &>/dev/null; then
        [[ "$(_ms_state_get SAMBA_USER_PREEXISTED)" == "false" ]] \
            || {
                log_warn "Pre-existing Samba OS user was removed; leaving state unchanged"
                return 0
            }
        sudo useradd -M -s /usr/sbin/nologin "$admin_user"
    fi
    if [[ -n "$gid_group" && "$group_preexisted" == "false" ]] \
        && ! id -nG "$admin_user" | tr ' ' '\n' | grep -Fxq "$gid_group"; then
        sudo usermod -aG "$gid_group" "$admin_user"
        _ms_state_set SAMBA_GROUP_ADDED_BY_MEDIASTACK true
    fi
    if [[ "$passdb_preexisted" == "false" ]] \
        && ! sudo pdbedit -L -u "$admin_user" >/dev/null 2>&1; then
        printf '%s\n%s\n' "$admin_pw" "$admin_pw" | sudo smbpasswd -a -s "$admin_user" >/dev/null 2>&1
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK true
    elif [[ "$passdb_preexisted" == "true" ]]; then
        log_warn "Samba user '$admin_user' already exists; preserving its existing password"
    fi

    # Write the [Media] share to the dedicated include file. NO [global]
    # block: that would silently override the user's main-conf [global] on
    # samba reload and break existing shares. The user's [global] owns
    # workgroup, server-role, security-mode, etc.
    sudo install -d -m 0755 "$(dirname "$SAMBA_INCLUDE_FILE")"
    sudo tee "$SAMBA_INCLUDE_FILE" >/dev/null <<EOF
# Managed by MediaStack setup.sh — DO NOT EDIT
# Edits will be overwritten on the next setup.sh run. Disable via
# SMB_ENABLED=false in .env (rerun ./setup.sh) — this file will be removed.

[$share_name]
   comment = $share_comment
   path = $share_path
   browseable = yes
   read only = no
   valid users = ${admin_user}
   create mask = 0664
   directory mask = 0775
EOF
    _ms_state_set SAMBA_INCLUDE_SHA256 "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")"

    # Idempotently add the include line to main smb.conf (append-only — never
    # overwrite). Detection keys on the `include = <path>` line itself, so the
    # human-readable comment written above it is decorative and never matched.
    if [[ ! -f "$SAMBA_MAIN_CONF" ]]; then
        sudo install -m 0644 /dev/null "$SAMBA_MAIN_CONF"
    fi
    if ! sudo grep -Fxq "$include_line" "$SAMBA_MAIN_CONF"; then
        printf '\n%s\n%s\n' "$SAMBA_INCLUDE_MARKER" "$include_line" \
            | sudo tee -a "$SAMBA_MAIN_CONF" >/dev/null
    fi

    sudo systemctl enable --now smbd >/dev/null 2>&1
    sudo systemctl reload smbd >/dev/null 2>&1 || true

    # LAN-only SMB access
    local cidr
    for cidr in "${LAN_CIDRS[@]}"; do
        _ms_ufw_allow from "$cidr" to any port 445 proto tcp comment MediaStack:SMB-LAN >/dev/null 2>&1
    done
    sudo ufw reload >/dev/null 2>&1

    _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
    _ms_state_set SAMBA_CONFIGURED true
    _ms_state_set SAMBA_SETUP_PENDING false

    log_ok "SMB share configured: \\\\<server-ip>\\${share_name} -> ${share_path}"
}

_uninstall_samba() {
    [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED)" == "true" ]] || return 0
    if [[ "$(_ms_state_get SAMBA_SETUP_PENDING)" == "true" ]]; then
        log_error "Samba setup is incomplete; rerun setup to finish it before uninstalling"
        return 1
    fi
    local expected current adopted=false user group
    expected=$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)
    if sudo test -e "$SAMBA_INCLUDE_FILE"; then
        if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]] \
            || [[ "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")" != "$expected" ]]; then
            log_error "Edited or unverifiable MediaStack Samba include preserved: $SAMBA_INCLUDE_FILE"
            return 1
        fi
    fi
    current=$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)
    [[ "$current" == "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" ]] || adopted=true

    sudo rm -f "$SAMBA_INCLUDE_FILE" || return 1
    if sudo test -e "$SAMBA_MAIN_CONF"; then
        sudo sed -i '/^# MEDIASTACK include - managed by setup\.sh$/d' "$SAMBA_MAIN_CONF" \
            && sudo sed -i '\#^include = /etc/samba/smb\.conf\.d/mediastack\.conf$#d' "$SAMBA_MAIN_CONF" || return 1
    fi
    user=$(_ms_state_get SAMBA_USER)
    if [[ "$(_ms_state_get SAMBA_PASSDB_CREATED_BY_MEDIASTACK)" == "true" ]] \
        && sudo pdbedit -L -u "$user" >/dev/null 2>&1; then
        sudo smbpasswd -x "$user" >/dev/null 2>&1 || return 1
    fi
    group=$(_ms_state_get SAMBA_GROUP)
    if [[ -n "$group" && "$(_ms_state_get SAMBA_GROUP_ADDED_BY_MEDIASTACK)" == "true" ]] \
        && id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group"; then
        sudo gpasswd -d "$user" "$group" >/dev/null 2>&1 || return 1
    fi

    if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK)" == "true" ]] \
        && command -v smbd >/dev/null 2>&1; then
        if $adopted; then
            log_warn "Samba has non-MediaStack configuration; preserving the package"
        else
            sudo apt-get remove -y -qq samba >/dev/null 2>&1 || return 1
        fi
    else
        if [[ "$(_ms_state_get SAMBA_SERVICE_WAS_ENABLED)" == "false" ]] \
            && sudo systemctl is-enabled smbd >/dev/null 2>&1; then
            sudo systemctl disable smbd >/dev/null 2>&1 || return 1
        fi
        if [[ "$(_ms_state_get SAMBA_SERVICE_WAS_ACTIVE)" == "false" ]] \
            && sudo systemctl is-active smbd >/dev/null 2>&1; then
            sudo systemctl stop smbd >/dev/null 2>&1 || return 1
        else
            sudo systemctl reload smbd >/dev/null 2>&1 || true
        fi
    fi
    log_ok "MediaStack Samba configuration removed; Linux account preserved"
}

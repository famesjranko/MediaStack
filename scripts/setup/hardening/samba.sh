# Owns: setup_* uninstall_* — optional SMB share setup, skip/warn behavior, and Samba teardown.
# Sources: hardening.sh Samba paths, ledger helpers, and firewall helpers.
# Globals: SAMBA_* paths, SMB_ENABLED, SMB_SHARE_SCOPE, DATA_DIR, PGID, and admin .env values.

# smbd lives in /usr/sbin, which a normal user's PATH omits.
# shellcheck source=/dev/null
declare -F host_tool_installed >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/host-tools.sh"

# shellcheck source=/dev/null
declare -p MS_APT_INSTALL >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/apt.sh"

# Rules MediaStack opened for SMB carry this exact ufw comment.
MS_SMB_UFW_COMMENT="MediaStack:SMB-LAN"

# Records, once and for good, that the live Samba config left what MediaStack
# recorded. The flag is sticky and MediaStack never clears it: re-enabling SMB
# re-baselines nothing, so a later uninstall or SMB OFF cannot mistake the
# user's shares for its own. A missing or malformed hash is not a divergence.
# Returns 0 when the config has diverged (now or before), 1 when it has not, so a
# caller can act on a divergence even when the ledger write failed.
_setup_samba_note_divergence() {
    local recorded
    [[ "$(_ms_state_get SAMBA_CONFIG_ADOPTED 2>/dev/null || true)" == "true" ]] && return 0
    recorded=$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)
    [[ "$recorded" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)" != "$recorded" ]] || return 1
    _ms_state_set SAMBA_CONFIG_ADOPTED true \
        || log_warn "Could not record that Samba has non-MediaStack configuration"
    return 0
}

# True when Samba is no longer only MediaStack's: the ledger flag is set, or the
# live config differs from what MediaStack recorded after its own setup (the user
# added shares or settings). A missing hash counts as differing, which keeps
# Samba running.
_setup_samba_config_adopted() {
    local current
    _setup_samba_note_divergence && return 0
    current=$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)
    [[ "$current" != "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" ]]
}

# Drops MediaStack's SMB UFW rules (live and in the ledger). The comment match is
# exact so a user's own rule, or another MediaStack tag, is never touched.
# While ufw is inactive it lists no rules, so each ledger entry is deleted by
# its rule spec instead; only entries actually deleted leave the ledger.
_setup_samba_ufw_rules_remove() {
    ufw_installed || return 0
    local numbers=() number count i rule kept=0 failed=0 status_out inactive=false spec
    status_out=$(LC_ALL=C sudo ufw status numbered 2>/dev/null || true)
    [[ "$status_out" == "Status: inactive"* ]] && inactive=true
    mapfile -t numbers < <(awk -v tag="# $MS_SMB_UFW_COMMENT" '
            { sub(/[[:space:]]+$/, "") }
            substr($0, length($0) - length(tag) + 1) == tag && match($0, /^\[[[:space:]]*[0-9]+\]/) {
                n = substr($0, RSTART + 1, RLENGTH - 2); gsub(/ /, "", n); print n
            }' <<<"$status_out" \
        | sort -rn)
    for number in "${numbers[@]}"; do
        sudo ufw --force delete "$number" >/dev/null || return 1
    done
    ((${#numbers[@]} == 0)) || sudo ufw reload >/dev/null 2>&1 || return 1

    # Compact the ledger so uninstall does not retry rules that are already gone.
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    for ((i = 1; i <= count; i++)); do
        rule=$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)
        if [[ "$rule" == *" comment $MS_SMB_UFW_COMMENT" ]]; then
            $inactive || continue
            spec=${rule% comment "$MS_SMB_UFW_COMMENT"}
            # shellcheck disable=SC2086 # the ledger rule spec is deliberately word-split
            if sudo ufw --force delete $spec >/dev/null 2>&1; then
                continue
            fi
            failed=1
        fi
        kept=$((kept + 1))
        ((kept == i)) || _ms_state_set "UFW_RULE_$kept" "$rule" || return 1
    done
    ((kept == count)) || _ms_state_set UFW_RULE_COUNT "$kept" || return 1
    return "$failed"
}

# SMB OFF: remove MediaStack's share block and firewall rules. The daemons stop
# only when MediaStack installed Samba and the user has added nothing to it; a
# Samba with the user's own shares keeps serving them.
_setup_samba_disable() {
    local unit adopted=false
    [[ -f "$SAMBA_INCLUDE_FILE" || "$(_ms_state_get SAMBA_CONFIGURED 2>/dev/null || true)" == "true" ]] || return 0

    log_info "SMB_ENABLED=false - removing MediaStack samba config..."
    # Judge adoption before the include goes: removing it changes the effective config.
    ! _setup_samba_config_adopted || adopted=true
    # Samba tolerates the now-dangling `include = ...` line in main smb.conf with
    # just a warning, so it stays: re-enabling SMB rewrites the same path.
    sudo rm -f "$SAMBA_INCLUDE_FILE" || return 1
    _setup_samba_ufw_rules_remove || {
        log_error "Could not remove the MediaStack SMB firewall rules"
        return 1
    }
    if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK 2>/dev/null || true)" == "true" ]] && ! $adopted; then
        for unit in smbd nmbd; do
            sudo systemctl cat "$unit" >/dev/null 2>&1 || continue
            sudo systemctl disable --now "$unit" >/dev/null 2>&1 || {
                log_error "Could not stop and disable $unit"
                return 1
            }
        done
        log_ok "Samba stopped and disabled (MediaStack installed it)"
    else
        sudo systemctl reload smbd >/dev/null 2>&1 || true
        log_ok "MediaStack samba config removed (user samba config preserved and still running)"
    fi
    # An adopted config keeps its old hash, so a repeated OFF still sees it as the
    # user's and never stops the daemons.
    if ! $adopted && [[ "$(_ms_state_get SAMBA_CONFIGURED 2>/dev/null || true)" == "true" ]]; then
        _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
    fi
}

setup_samba() {
    if [[ "${SMB_ENABLED:-false}" != "true" ]]; then
        _setup_samba_disable
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
                # Backfill only: re-recording an existing hash would adopt the
                # user's later edits as MediaStack's, and SMB OFF and uninstall
                # would then stop or remove their shares. Only the flag matters here.
                _setup_samba_note_divergence || true
                [[ "$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] \
                    || _ms_state_set SAMBA_INCLUDE_SHA256 "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")"
                [[ "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] \
                    || _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
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
        host_tool_installed smbd && samba_was_present=true
        if $samba_was_present; then
            sudo systemctl is-enabled smbd >/dev/null 2>&1 && service_was_enabled=true
            sudo systemctl is-active smbd >/dev/null 2>&1 && service_was_active=true
            sudo pdbedit -L -u "$admin_user" >/dev/null 2>&1 && passdb_preexisted=true
        fi
        id "$admin_user" &>/dev/null && user_preexisted=true
        # The samba and winbind packages create these groups; uninstall removes only
        # the ones that were absent now, so a group the host already had survives.
        local grp groups_preexisted=""
        for grp in sambashare winbindd_priv; do
            ! getent group "$grp" >/dev/null 2>&1 || groups_preexisted+="${groups_preexisted:+ }$grp"
        done
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
        _ms_state_set SAMBA_GROUPS_PREEXISTED "$groups_preexisted"
        _ms_state_set SAMBA_SETUP_PENDING true
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK false
        _ms_state_set SAMBA_GROUP_ADDED_BY_MEDIASTACK false
        _ms_state_set SAMBA_OWNERSHIP_RECORDED true
        if ! $samba_was_present; then
            _ms_state_set SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK true
            ui_spin "Installing samba..." "${MS_APT_INSTALL[@]}" samba
        fi
    else
        if [[ "$(_ms_state_get SAMBA_USER)" != "$admin_user" ]]; then
            log_warn "Samba owner changed after setup; leaving existing Samba configuration unchanged"
            return 0
        fi
        if ! host_tool_installed smbd; then
            if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK)" != "true" ]]; then
                log_warn "Recorded Samba package is missing; leaving state unchanged"
                return 0
            fi
            ui_spin "Retrying Samba installation..." "${MS_APT_INSTALL[@]}" samba
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
        # Error text goes to a file so the tool message survives without a subshell
        local _smb_err_file
        _smb_err_file=$(mktemp)
        if ! printf '%s\n%s\n' "$admin_pw" "$admin_pw" | sudo smbpasswd -a -s "$admin_user" >/dev/null 2>"$_smb_err_file"; then
            log_error "Could not create the Samba account for '$admin_user': $(head -c 300 "$_smb_err_file")"
            rm -f "$_smb_err_file"
            return 1
        fi
        rm -f "$_smb_err_file"
        _ms_state_set SAMBA_PASSDB_CREATED_BY_MEDIASTACK true
    elif [[ "$passdb_preexisted" == "true" ]]; then
        log_warn "Samba user '$admin_user' already exists; preserving its existing password"
    fi

    # Write the [Media] share to the dedicated include file. NO [global]
    # block: that would silently override the user's main-conf [global] on
    # samba reload and break existing shares. The user's [global] owns
    # workgroup, server-role, security-mode, etc.
    # Judge divergence before this run changes the effective config.
    local diverged=false
    _setup_samba_note_divergence && diverged=true
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

    local _smbd_err_file
    _smbd_err_file=$(mktemp)
    if ! sudo systemctl enable --now smbd >/dev/null 2>"$_smbd_err_file"; then
        log_error "Could not start smbd: $(head -c 300 "$_smbd_err_file"). Check: journalctl -u smbd"
        rm -f "$_smbd_err_file"
        return 1
    fi
    rm -f "$_smbd_err_file"
    # SMB OFF stops nmbd with smbd when MediaStack installed Samba; bring it back.
    if [[ "$(_ms_state_get SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK 2>/dev/null || true)" == "true" ]]; then
        sudo systemctl enable --now nmbd >/dev/null 2>&1 || true
    fi
    sudo systemctl reload smbd >/dev/null 2>&1 || true

    # LAN-only SMB access
    local cidr
    for cidr in "${LAN_CIDRS[@]}"; do
        _ms_ufw_allow from "$cidr" to any port 445 proto tcp comment "$MS_SMB_UFW_COMMENT" >/dev/null 2>&1
    done
    sudo ufw reload >/dev/null 2>&1

    # Once the config has diverged the recorded hash stays: re-recording it would
    # adopt the user's shares as MediaStack's. `diverged` covers a failed flag write.
    [[ "$diverged" == true || "$(_ms_state_get SAMBA_CONFIG_ADOPTED 2>/dev/null || true)" == "true" ]] \
        || _ms_state_set SAMBA_EFFECTIVE_SHA256 "$(sudo testparm -s 2>/dev/null | _ms_stream_sha256)"
    _ms_state_set SAMBA_CONFIGURED true
    _ms_state_set SAMBA_SETUP_PENDING false

    log_ok "SMB share configured: \\\\<server-ip>\\${share_name} -> ${share_path}"
}

# Groups the samba package creates and its purge leaves behind. Removed only
# when the ledger shows they were absent before MediaStack, and when empty, so a
# group the host owned or a user has since populated survives. winbindd_priv
# belongs to the winbind package, which a purge of samba leaves installed.
# A ledger without SAMBA_GROUPS_PREEXISTED keeps both groups.
_uninstall_samba_groups() {
    local grp preexisted
    preexisted=$(_ms_state_get SAMBA_GROUPS_PREEXISTED 2>/dev/null) || {
        log_info "No record of which Samba groups existed before MediaStack; groups preserved"
        return 0
    }
    for grp in sambashare winbindd_priv; do
        [[ " $preexisted " != *" $grp "* ]] || continue
        getent group "$grp" >/dev/null 2>&1 || continue
        [[ -z "$(getent group "$grp" | cut -d: -f4)" ]] || continue
        if [[ "$grp" == winbindd_priv && "$(dpkg-query -W -f='${db:Status-Abbrev}' winbind 2>/dev/null)" == ii* ]]; then
            continue
        fi
        sudo groupdel "$grp" >/dev/null 2>&1 || log_warn "Could not remove group '$grp'"
    done
}

# Removes the Linux account only when MediaStack created it (ledger) and nothing
# outside MediaStack's own paths uses it; otherwise keeps it and says why.
# userdel also drops the account's private group.
_uninstall_samba_account() {
    local user="$1" adopted="$2" stray
    [[ "$(_ms_state_get SAMBA_USER_PREEXISTED)" == "false" ]] || {
        log_info "Linux account '$user' existed before MediaStack; preserved"
        return 0
    }
    id "$user" &>/dev/null || return 0
    if [[ "$adopted" == "true" ]]; then
        log_warn "Linux account '$user' preserved: Samba has non-MediaStack configuration"
        return 0
    fi
    if sudo pgrep -u "$user" >/dev/null 2>&1; then
        log_warn "Linux account '$user' preserved: it has running processes"
        return 0
    fi
    # -xdev keeps the scan off network mounts; MediaStack's data and checkout are
    # the paths the account legitimately owns.
    stray=$(sudo find / -xdev \( -path /proc -o -path /sys -o -path "${DATA_DIR:-/data}" \
        -o -path "${SCRIPT_DIR:-/nonexistent}" \) -prune -o -user "$user" -print -quit 2>/dev/null)
    if [[ -n "$stray" ]]; then
        log_warn "Linux account '$user' preserved: it owns files outside MediaStack paths (e.g. $stray)"
        return 0
    fi
    sudo userdel "$user" >/dev/null 2>&1 || {
        log_error "Could not remove Linux account '$user'"
        return 1
    }
    log_ok "Linux account '$user' removed (MediaStack created it)"
}

_uninstall_samba() {
    [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED)" == "true" ]] || return 0
    if [[ "$(_ms_state_get SAMBA_SETUP_PENDING)" == "true" ]]; then
        log_error "Samba setup is incomplete; rerun setup to finish it before uninstalling"
        return 1
    fi
    local expected adopted=false user group
    expected=$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)
    if sudo test -e "$SAMBA_INCLUDE_FILE"; then
        if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]] \
            || [[ "$(_ms_root_sha256 "$SAMBA_INCLUDE_FILE")" != "$expected" ]]; then
            log_error "MediaStack Samba include preserved: $SAMBA_INCLUDE_FILE (edited since install, unverifiable, or the ownership ledger is missing)"
            return 1
        fi
    fi
    # After a purge testparm is gone and the hash always differs, so a retry
    # (e.g. userdel failed) must not read that as the user's own configuration.
    if [[ "$(_ms_state_get SAMBA_PURGED 2>/dev/null || true)" != "true" ]]; then
        ! _setup_samba_config_adopted || adopted=true
    fi

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
        && host_tool_installed smbd; then
        if $adopted; then
            log_warn "Samba has non-MediaStack configuration; preserving the package"
        else
            # Purge, not remove: remove leaves the package in dpkg 'rc' state with
            # its conffiles. No autoremove: it would also sweep unrelated orphaned
            # packages the user left behind, and MediaStack records only 'samba'.
            "${MS_APT_PURGE[@]}" samba >/dev/null 2>&1 || return 1
            _ms_state_set SAMBA_PURGED true || return 1
            _uninstall_samba_groups
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
    _uninstall_samba_account "$user" "$adopted" || return 1
    log_ok "MediaStack Samba configuration removed"
}

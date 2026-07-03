# =============================================================================
# MediaStack Setup - Post-reboot resume (systemd oneshot)
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

_systemd_unit_escape() {
    local value="$1"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        return 1
    fi

    # systemd unit files use C-style escapes for path values; shell quotes make
    # WorkingDirectory invalid and raw spaces split ExecStart. ExecStart uses
    # the ":" prefix below so literal "$" in checkout paths is not treated as
    # systemd environment substitution.
    value=${value//\\/\\x5c}
    value=${value//$'\t'/\\x09}
    value=${value// /\\x20}
    value=${value//\"/\\x22}
    value=${value//%/%%}
    printf '%s' "$value"
}

schedule_post_reboot() {
    local service_file="/etc/systemd/system/mediastack-setup.service"
    local working_dir
    local exec_start

    if ! working_dir=$(_systemd_unit_escape "$SCRIPT_DIR") || ! exec_start=$(_systemd_unit_escape "$SCRIPT_DIR/setup.sh"); then
        log_error "Checkout path contains unsupported control characters; cannot schedule post-reboot resume"
        return 1
    fi

    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=MediaStack post-reboot setup (one-time)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
TimeoutStartSec=infinity
User=$USER
WorkingDirectory=$working_dir
ExecStart=:$exec_start
ExecStartPost=+/bin/bash -c 'systemctl disable mediastack-setup.service && rm -f $service_file'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    # systemctl enable prints "Created symlink ..." to stderr; suppress it (the
    # log_ok below is the user-facing confirmation) but warn on real failure.
    if ! sudo systemctl enable mediastack-setup.service >/dev/null 2>&1; then
        log_warn "Could not enable the post-reboot resume service; choose Install MediaStack from the menu after reboot to finish."
    fi
    log_ok "Scheduled: setup.sh will resume automatically after reboot"
}

cleanup_post_reboot() {
    if [[ -f /etc/systemd/system/mediastack-setup.service ]]; then
        local _svc_state
        _svc_state=$(systemctl show mediastack-setup.service -p ActiveState --value 2>/dev/null || echo "")
        if [[ "$_svc_state" == "activating" || "$_svc_state" == "active" ]]; then
            # We ARE the running service - leave the unit file alone so systemd
            # keeps our TimeoutStartSec=infinity. ExecStartPost handles cleanup.
            log_ok "Resuming post-reboot setup"
        else
            # Manual run with a stale service file - clean it up
            sudo systemctl disable mediastack-setup.service 2>/dev/null || true
            sudo rm -f /etc/systemd/system/mediastack-setup.service
            sudo systemctl daemon-reload 2>/dev/null || true
            log_ok "Stale post-reboot service cleaned up"
        fi
    fi
}

# Print a banner before rebooting so the user knows what to expect.
print_reboot_notice() {
    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    lan_ip="${lan_ip:-<this-machine>}"

    ui_box "Rebooting to activate GPU drivers" \
        "Setup will continue automatically after reboot." \
        "This typically takes 2-3 minutes." \
        "" \
        "When it's done, open:  http://${lan_ip}:3000" \
        "" \
        "Check progress:" \
        "  ssh ${USER}@${lan_ip}" \
        "  journalctl -u mediastack-setup -f"
}

_shell_single_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Write a login banner so the user sees setup results on first SSH login.
install_post_reboot_banner() {
    local banner_script="/etc/profile.d/mediastack-setup-result.sh"
    local result_file="$SCRIPT_DIR/.setup-result"
    local result_file_q

    result_file_q=$(_shell_single_quote "$result_file")

    sudo tee "$banner_script" > /dev/null <<PROFILE_EOF
# MediaStack: show post-reboot setup status on login
_ms_setup_result=$result_file_q
if [ -f "\$_ms_setup_result" ]; then
    cat "\$_ms_setup_result"
    rm -f "\$_ms_setup_result"
    sudo rm -f /etc/profile.d/mediastack-setup-result.sh 2>/dev/null
elif [ -f /etc/systemd/system/mediastack-setup.service ]; then
    _c='\033[1;33m'; _r='\033[0m'
    printf '\n'
    printf "  \${_c}+====================================================+\${_r}\n"
    printf "  \${_c}|\${_r}%-52s\${_c}|\${_r}\n" "  MediaStack setup is still running..."
    printf "  \${_c}|\${_r}%-52s\${_c}|\${_r}\n" ""
    printf "  \${_c}|\${_r}%-52s\${_c}|\${_r}\n" "  Watch progress:"
    printf "  \${_c}|\${_r}%-52s\${_c}|\${_r}\n" "    journalctl -u mediastack-setup -f"
    printf "  \${_c}+====================================================+\${_r}\n"
    printf '\n'
fi
unset _ms_setup_result _c _r
PROFILE_EOF
    sudo chmod +x "$banner_script"
}

# Called by setup.sh at the end of a successful post-reboot run.
write_setup_result() {
    local status="$1"  # "ok" or "error"
    local result_file="$SCRIPT_DIR/.setup-result"
    local script_dir_q lan_ip

    script_dir_q=$(_shell_single_quote "$SCRIPT_DIR")
    lan_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    lan_ip="${lan_ip:-<this-server-ip>}"

    # The post-reboot service runs only to finalize GPU (NVIDIA) transcoding, so
    # report that outcome on the login banner — otherwise "completed" gives no
    # sign whether the NVENC/patch step (the whole reason for the reboot) worked.
    # A failed patch/driver finalize sets STAGE_3_GPU_STATE=fallback but the run
    # still exits "ok" (the LAN media server is fine on software transcoding), so
    # surface that as a warning line rather than letting it look fully clean.
    local _tc_state _tc_gpu _tc_mode tc_line="" tc_warn=""
    _tc_state=$(grep -oP '^STAGE_3_GPU_STATE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "\"'")
    case "$_tc_state" in
        complete)
            _tc_gpu=$(grep -oP '^JELLYFIN_GPU=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "\"'")
            _tc_mode=$(grep -oP '^NVIDIA_DRIVER_MODE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "\"'")
            case "$_tc_gpu" in
                nvidia) tc_line="NVIDIA NVENC"
                        if [[ "$_tc_mode" == "unlock" ]]; then
                            if [[ -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched" ]]; then
                                tc_line+=" (session limit NOT removed - patch failed; retry via Manage hardware transcoding)"
                            else
                                tc_line+=" - session limit removed (patch applied)"
                            fi
                        fi ;;
                intel)  tc_line="Intel QSV" ;;
                amd)    tc_line="AMD VAAPI" ;;
            esac
            ;;
        fallback)
            tc_warn="Hardware transcoding did NOT finalize - using software. See: journalctl -u mediastack-setup --no-pager"
            ;;
    esac

    local _c _r='\033[0m' _y='\033[1;33m'
    if [[ "$status" == "ok" ]]; then
        _c='\033[0;32m'
        {
            printf '\n'
            printf "  ${_c}+====================================================+${_r}\n"
            printf "  ${_c}|${_r}%-52s${_c}|${_r}\n" "  MediaStack setup completed successfully!"
            printf "  ${_c}+====================================================+${_r}\n"
            printf '\n'
            [[ -n "$tc_line" ]] && printf "  Hardware transcoding: %s\n\n" "$tc_line"
            [[ -n "$tc_warn" ]] && printf "  ${_y}! %s${_r}\n\n" "$tc_warn"
            printf "  Open your dashboard:  http://%s:3000\n" "$lan_ip"
            printf "  Manage MediaStack:    cd %s && ./mediastack\n" "$script_dir_q"
            printf '\n'
        } > "$result_file"
    else
        _c='\033[0;31m'
        {
            printf '\n'
            printf "  ${_c}+====================================================+${_r}\n"
            printf "  ${_c}|${_r}%-52s${_c}|${_r}\n" "  MediaStack post-reboot setup encountered errors."
            printf "  ${_c}+====================================================+${_r}\n"
            printf '\n'
            printf '  Check the log:  journalctl -u mediastack-setup --no-pager\n'
            printf '  Then re-run:    cd %s && ./setup.sh\n' "$script_dir_q"
            printf '\n'
        } > "$result_file"
    fi
}

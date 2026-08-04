# Owns: NPM post-publication nginx reload and rate-limit jail verification.
# Sources: main.sh for SCRIPT_DIR/NPM_* globals and logging/config helpers; hidden caller locals: http_top_created, rate_enabled.

# shellcheck disable=SC2154
_npm_finish_configuration() {
    # Reload nginx if http_top.conf was just created (on re-runs where proxy
    # hosts already existed, no API call triggered an automatic reload).
    if [[ "$http_top_created" == "true" ]]; then
        docker exec npm nginx -s reload >/dev/null 2>&1 \
            && log_ok "NPM nginx reloaded (rate limit zone active)" \
            || log_warn "Could not reload NPM nginx - rate limits active after next proxy host change"
    fi

    # Verify npm-ratelimit jail values match config.yml. Only when rate limiting is
    # enabled: the jail ships disabled alongside rate_limiting.enabled=false.
    if [[ "$rate_enabled" != "true" ]]; then
        log_skip "Fail2ban: npm-ratelimit jail skipped (rate limiting disabled)"
    else
        local rl_maxretry rl_findtime
        rl_maxretry=$(cfg_field "rate_limiting.ban_maxretry" 2>/dev/null || echo "10")
        rl_findtime=$(cfg_field "rate_limiting.ban_findtime" 2>/dev/null || echo "60")

        local jail_file="$SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf"
        if grep -q "\[npm-ratelimit\]" "$jail_file" 2>/dev/null; then
            local current_maxretry current_findtime current_jail_enabled
            current_maxretry=$(sed -n '/\[npm-ratelimit\]/,/^\[/{s/^maxretry = //p}' "$jail_file")
            current_findtime=$(sed -n '/\[npm-ratelimit\]/,/^\[/{s/^findtime = //p}' "$jail_file")
            current_jail_enabled=$(sed -n '/\[npm-ratelimit\]/,/^\[/{s/^enabled = //p}' "$jail_file")
            if [[ "$current_jail_enabled" != "true" ]]; then
                log_warn "Fail2ban: npm-ratelimit jail is disabled (enabled = ${current_jail_enabled:-unset})."
                log_warn "Rate limiting is active but bans won't fire; set enabled = true in $jail_file"
            fi
            if [[ "$current_maxretry" == "$rl_maxretry" && "$current_findtime" == "$rl_findtime" ]]; then
                log_skip "Fail2ban: npm-ratelimit jail matches config.yml (maxretry=$rl_maxretry, findtime=${rl_findtime}s)"
            else
                log_warn "Fail2ban: npm-ratelimit jail values differ from config.yml."
                log_warn "jail: maxretry=$current_maxretry findtime=$current_findtime; config: maxretry=$rl_maxretry findtime=$rl_findtime"
            fi
        else
            log_warn "Fail2ban: npm-ratelimit jail not found in $jail_file"
        fi
    fi
}

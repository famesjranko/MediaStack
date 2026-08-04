#!/usr/bin/env bash
# Owns: DDNS status, credential updates, live verification, and rollback.
# Sources: launcher globals, .env, scripts/lib/ui.sh, network.sh, env_gen.sh, and service helpers.

_resolve_ddns_ip() {
    local _dom="${DOMAIN:-}" _ip=""
    # BOUNDED: the shared _stage2_dns_lookup_a is unbounded (~30s worst case, fine
    # for install/on-demand checks, not for a hot render path). Short-timeout digs
    # (system resolver, then 8.8.8.8) via the shared IPv4 extractor. Broken DNS
    # falls to "" -> "not resolving yet", never a frozen menu.
    if [[ -n "$_dom" && "$_dom" != "example.com" ]] && command -v dig &>/dev/null; then
        _ip=$(dig +short +time=2 +tries=1 A "$_dom" 2>/dev/null | _stage2_first_ipv4)
        [[ -z "$_ip" ]] && _ip=$(dig +short +time=2 +tries=1 A "$_dom" @8.8.8.8 2>/dev/null | _stage2_first_ipv4)
    fi
    printf '%s' "$_ip"
}

_ddns_status() {
    local wan="${1:-}" ip
    _ddns_configured || {
        printf 'off'
        return 0
    }
    _service_is_running ddns-updater || {
        printf 'stopped'
        return 0
    }
    ip=$(_resolve_ddns_ip)
    [[ -z "$ip" ]] && {
        printf 'unresolved'
        return 0
    }
    if [[ -n "$wan" && "$ip" == "$wan" ]]; then
        printf 'ok:%s' "$ip"
    else
        printf 'stale:%s' "$ip"
    fi
}

_ddns_configured() {
    [[ -n "${DDNS_PROVIDER:-}" && -f "$SCRIPT_DIR/config/ddns-updater/config.json" ]]
}

_ddns_write_live_config() {
    local payload="$1" live="$SCRIPT_DIR/config/ddns-updater/config.json"
    _DDNS_LIVE_MUTATED=0
    local dir
    dir="$(dirname "$live")"
    _ddns_prepare_config_dir "$dir" || return 1
    local tmp
    tmp=$(mktemp "$SCRIPT_DIR/.ddns-updater-config.XXXXXX") || return 1
    if printf '%s\n' "$payload" >"$tmp" \
        && { mv -f "$tmp" "$live" 2>/dev/null || sudo mv -f "$tmp" "$live"; }; then
        _DDNS_LIVE_MUTATED=1
        repair_ddns_updater_config_permissions
        return $?
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

_ddns_restart_and_check() {
    docker restart ddns-updater >/dev/null 2>&1 || return 1
    local i status
    for i in 1 2 3; do
        sleep 2
        status=$(docker inspect --format '{{.State.Status}}' ddns-updater 2>/dev/null || echo "")
        [[ "$status" == "running" ]] || return 1
    done
    return 0
}

action_change_ddns() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        pause_for_menu
        return 0
    fi
    # The row is already gated on "remote ready AND ddns configured"; this guard is
    # the safety net for a stale/direct call and routes to "Add remote access".
    if recovery_menu_remote_available || ! _ddns_configured; then
        ui_log info "No DDNS provider is set up yet - use 'Add remote access' to configure remote access first."
        pause_for_menu
        return 0
    fi
    if ! _service_is_running ddns-updater; then
        ui_log warn "ddns-updater isn't running - start the stack first."
        pause_for_menu
        return 0
    fi

    # The shared DDNS registry/renderer + config-write helpers live in env_gen.sh
    # (which also sources the provider registry). Load it lazily; the guard keeps a
    # repeat visit cheap. ddns_verify_via_container is already sourced via network.sh.
    type ddns_render_config_json &>/dev/null || source "$SCRIPT_DIR/scripts/setup/env_gen.sh"

    local domain="${DOMAIN:-}"
    if [[ -z "$domain" ]]; then
        ui_log warn "No domain on record - use 'Add remote access' to set the domain first."
        pause_for_menu
        return 0
    fi

    ui_log info "Current DDNS provider: ${DDNS_PROVIDER:-unknown}  (domain: ${domain})"
    ui_log info "Re-enter credentials, or switch to a provider that keeps your current domain. A different hostname is set up in 'Add remote access'."

    # PICK — the shared, wizard-identical chooser. Skip / empty leaves it unchanged.
    local new_provider
    new_provider=$(ddns_provider_pick "${DDNS_PROVIDER:-}")
    if [[ -z "$new_provider" || "$new_provider" == "${_DDNS_SKIP:-__skip__}" ]]; then
        ui_log info "No change."
        pause_for_menu
        return 0
    fi

    # A provider switch KEEPS the shared media domain, which only works when the new
    # provider can manage it: same provider (re-enter creds) or both bring-your-own
    # (a domain you own is portable between Cloudflare/Porkbun). Any switch involving a
    # free-hostname provider (duckdns/dynu/desec/dynv6) needs a NEW hostname in that
    # provider's namespace, and the domain cascades to HTTPS certs, WireGuard and
    # service URLs — exactly what "Add remote access" reconfigures. Route there instead
    # of dead-ending at the verify (which would just reject the mismatched hostname).
    local new_cat old_cat
    new_cat=$(ddns_provider_category "$new_provider" 2>/dev/null || printf '')
    old_cat=$(ddns_provider_category "${DDNS_PROVIDER:-}" 2>/dev/null || printf '')
    if [[ "$new_provider" != "${DDNS_PROVIDER:-}" ]] \
        && { [[ "$new_cat" == free ]] || [[ "$old_cat" == free ]]; }; then
        ui_log warn "'${new_provider}' can't manage your current domain (${domain}) - it needs a new hostname of its own."
        ui_log info "Changing the domain also updates HTTPS, WireGuard and your service URLs, so it's done in 'Add remote access'."
        # ui_confirm defaults 'no'; action_remote runs setup.sh --remote then re-execs the
        # launcher, so it never returns to this action on a real run — "No change" is the
        # decline-only path.
        if ui_confirm "Open 'Add remote access' now to set the new hostname?" no; then
            action_remote
        else
            ui_log info "No change to DDNS."
        fi
        pause_for_menu
        return 0
    fi

    # COLLECT + VERIFY. verify has zero blast radius (throwaway container), so we
    # verify BEFORE the disruptive confirm/restart. Bounded so a reject can't spin:
    # a non-TTY required-field collect already self-terminates on exhausted stdin,
    # and this cap backstops the interactive reject re-prompt.
    local payload="" fields_spec attempt
    fields_spec=$(ddns_provider_fields "$new_provider") || fields_spec=""
    for attempt in 1 2 3; do
        local -A _ddns_new_fields=()
        local spec name validator val
        for spec in $fields_spec; do
            name="${spec%%:*}"
            validator="${spec##*:}"
            val=$(ui_input_validated "Enter ${name//_/ }" "" "$validator")
            # The validators tolerate surrounding whitespace (a dashboard paste
            # often carries a trailing newline/space); ui_input_validated returns
            # the raw entry, so trim here before storing so the written config is
            # clean. Same trim + validator contract as the wizard's field loop.
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            _ddns_new_fields["$name"]="$val"
        done
        _ddns_new_fields[domain]="$domain"

        if ! payload=$(ddns_render_config_json "$new_provider" _ddns_new_fields); then
            ui_log warn "Couldn't build the DDNS config from those entries - no change made."
            pause_for_menu
            return 0
        fi

        local vtmp vbody verify_rc=2
        vtmp=$(mktemp "$SCRIPT_DIR/.ddns-verify.XXXXXX" 2>/dev/null) || vtmp=""
        vbody=$(mktemp 2>/dev/null) || vbody=""
        if [[ -n "$vtmp" ]] && printf '%s\n' "$payload" >"$vtmp"; then
            ui_spin "Testing your ${new_provider} credentials..." \
                ddns_verify_via_container "$vtmp" "$vbody"
            verify_rc=$?
        fi
        [[ -n "$vtmp" ]] && rm -f "$vtmp"

        if ((verify_rc == 0)); then
            [[ -n "$vbody" ]] && rm -f "$vbody"
            break
        fi
        if ((verify_rc == 1)); then
            [[ -n "$vbody" && -s "$vbody" ]] && ui_log warn "Provider rejected the credentials: $(cat "$vbody")"
            [[ -n "$vbody" ]] && rm -f "$vbody"
            if ((attempt < 3)); then
                ui_confirm "Those credentials were rejected. Re-enter them?" yes || {
                    ui_log info "No change."
                    pause_for_menu
                    return 0
                }
                continue
            fi
            ui_log warn "Still rejected after ${attempt} attempts - no change made."
            pause_for_menu
            return 0
        fi
        # verify_rc == 2 -> degrade (docker/pull/timeout). Never restart a working
        # live service on unverified creds; leave the current provider untouched.
        [[ -n "$vbody" ]] && rm -f "$vbody"
        ui_log warn "Couldn't verify the new credentials (Docker or network issue) - no change made."
        pause_for_menu
        return 0
    done
    [[ -z "$payload" ]] && {
        ui_log info "No change."
        pause_for_menu
        return 0
    }

    # WARN + CONFIRM the disruptive part (the live restart).
    ui_confirm "Switch DDNS to '${new_provider}' and restart the updater now? Your current config is backed up and restored if it fails to start." no || {
        ui_log info "No change."
        pause_for_menu
        return 0
    }

    # APPLY (verify-first). Snapshot the current config into a variable for rollback
    # (the live file is chmod 600 owned by 1000:1000, so a cross-owner backup FILE is
    # fragile; a direct read with a sudo -n fallback matches the wizard's recall).
    local live="$SCRIPT_DIR/config/ddns-updater/config.json"
    local old_payload
    old_payload=$(cat "$live" 2>/dev/null)
    [[ -z "$old_payload" ]] && old_payload=$(sudo -n cat "$live" 2>/dev/null)
    if [[ -z "$old_payload" ]]; then
        ui_log warn "Couldn't read the current DDNS config to make a rollback point - no change made."
        pause_for_menu
        return 0
    fi

    ui_log info "Switching DDNS provider to '${new_provider}'..."
    if _ddns_write_live_config "$payload" && _ddns_restart_and_check; then
        # Persist the non-secret provider key only after the live service comes up.
        _set_env_var DDNS_PROVIDER "$new_provider"
        _reload_env
        # No cache to invalidate: the banner re-resolves the DDNS record every render,
        # so it will honestly read "propagating" until the new record propagates.
        # Honest verify tier, matching the wizard: a token provider's verify
        # 202 is genuine (the token IS the account key, it cannot mask), but a
        # dyndns2 provider (Dynu) server-side no-ops on an UNCHANGED IP without
        # checking the password — and this row is only reachable when the record
        # already points here, so its verify ALWAYS nochg-masks. Say so rather than
        # let "completed successfully" imply a credential check we couldn't make.
        local _vtier
        _vtier=$(ddns_provider_verify_tier "$new_provider" 2>/dev/null || printf 'token')
        if [[ "$_vtier" == "dyndns2" ]]; then
            ui_log warn "'${new_provider}' couldn't be fully re-verified — it reports success without re-checking the password when your IP hasn't changed. The day-2 Health check flags a wrong login on your next IP change."
        fi
        _show_action_result 0 "Update DDNS provider / credentials"
    elif ((!_DDNS_LIVE_MUTATED)); then
        # The forward write never landed (e.g. no write access / no sudo) — the live
        # config.json is untouched and still matches .env, so there's nothing to roll
        # back and nothing is inconsistent. Report the no-op plainly.
        ui_log warn "Couldn't write the new DDNS config - your existing DDNS setup is unchanged."
        _show_action_result 1 "Update DDNS provider / credentials"
    else
        # The new config WAS written (the mv landed) but the updater didn't come up —
        # roll back. Warn on ANY unclean rollback: a failed mv may leave the unverified
        # provider live (content), and a failed perms repair may leave the restored
        # config unreadable by the uid-1000 container (permissions). Either way the
        # user must know rather than have us silently restart onto a broken config.
        ui_log warn "ddns-updater didn't come up cleanly - restoring your previous DDNS config."
        if ! _ddns_write_live_config "$old_payload"; then
            ui_log error "Couldn't fully restore config/ddns-updater/config.json (content or permissions) - re-run 'Update DDNS provider / credentials' to fix it."
        fi
        docker restart ddns-updater >/dev/null 2>&1 || true
        _show_action_result 1 "Update DDNS provider / credentials"
    fi
    pause_for_menu
    return 0
}

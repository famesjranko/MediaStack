#!/usr/bin/env bash
# Owns: Per-service image-policy management, update scans, applies, reverts, and menu routing.
# Sources: launcher globals, .env, override.sh, image-drift.py, compose helpers, and scripts/lib/ui.sh.

_service_profile_flag() {
    case "$1" in
        bazarr) echo "--profile subtitles" ;;
        npm | fail2ban | ddns-updater) echo "--profile proxy" ;;
        wireguard) echo "--profile remote" ;;
        autoheal) echo "--profile autoheal" ;;
        *) echo "" ;;
    esac
}

_regenerate_override() {
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/override.sh"
    detect_host_memory >/dev/null 2>&1 || true
    generate_override "${JELLYFIN_GPU:-none}"
}

_image_policy_state_file() { printf '%s\n' "$SCRIPT_DIR/config/state/image-policy.tsv"; }

_image_policy_header() {
    echo "# MediaStack per-service image policy - managed by 'Manage updates'."
    echo "# Format: service<TAB>stable|latest|<image>@sha256:<digest>. A digest value pins"
    echo "# the service to its installed image. Absent row = follow global IMAGE_CHANNEL."
}

_set_service_policy() {
    local svc="$1" pol="$2" file tmp
    file="$(_image_policy_state_file)"
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp)
    {
        _image_policy_header
        [[ -f "$file" ]] && awk -F '\t' -v s="$svc" \
            '$1 !~ /^#/ && NF >= 2 && $1 != s { print $1 "\t" $2 }' "$file"
        printf '%s\t%s\n' "$svc" "$pol"
    } >"$tmp"
    mv "$tmp" "$file"
}

_clear_service_policy() {
    local svc="$1" file tmp
    file="$(_image_policy_state_file)"
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    {
        _image_policy_header
        awk -F '\t' -v s="$svc" \
            '$1 !~ /^#/ && NF >= 2 && $1 != s { print $1 "\t" $2 }' "$file"
    } >"$tmp"
    mv "$tmp" "$file"
}

_install_image_ref() {
    local svc="$1" file="$SCRIPT_DIR/config/state/image-install.tsv"
    [[ -f "$file" ]] || return 0
    awk -F '\t' -v s="$svc" '
        $1 == s && $3 ~ /^sha256:/ { print $2 "@" $3; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$file" 2>/dev/null || return 0
}

_service_policy_raw() {
    local svc="$1" file
    file="$(_image_policy_state_file)"
    [[ -f "$file" ]] || return 0
    awk -F '\t' -v s="$svc" '
        $1 !~ /^#/ && NF >= 2 && $1 == s { print $2; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$file" 2>/dev/null || return 0
}

_restore_service_policy_row() {
    local svc="$1" val="$2"
    if [[ -z "$val" ]]; then
        _clear_service_policy "$svc"
    else
        _set_service_policy "$svc" "$val"
    fi
}

_set_env_var() {
    local key="$1" val="$2" file="$SCRIPT_DIR/.env" status
    [[ -f "$file" ]] || return 1
    if ! status=$(_env_write_kv "$file" "$key" "$val"); then
        _env_write_kv_warn "$key" "$status"
        return 1
    fi
}

_reload_env() {
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
}

_wait_service_running() {
    local svc="$1" i=0 max=60 state health
    echo -ne "  Waiting for ${svc}..."
    while ((i < max)); do
        state=$(docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null || echo "")
        if [[ "$state" == "running" ]]; then
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$svc" 2>/dev/null || echo "")
            if [[ -z "$health" || "$health" == "healthy" ]]; then
                echo -e " ${GREEN}ready${NC}"
                return 0
            elif [[ "$health" == "unhealthy" ]]; then
                echo -e " ${RED}unhealthy${NC}"
                return 1
            fi
        fi
        sleep 2
        ((i += 2))
        echo -ne "."
    done
    echo -e " ${YELLOW}still starting${NC}"
    return 0
}

_service_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

_recreate_service() {
    local svc="$1" done_msg="$2"
    # Profile flag(s) as a proper array — matches the `${profiles[@]}` pattern
    # used everywhere else (and _build_profile_args) and removes the
    # word-splitting hazard of an unquoted $pflag. read -ra on an empty string
    # yields an empty array, so a profile-less service passes no extra args.
    local pflag=()
    read -ra pflag <<<"$(_service_profile_flag "$svc")"
    # Record whether the pull actually fetched a fresh image. On failure we fall
    # back to the cached (old) image, so the caller must NOT then claim the
    # service is up to date. _MU_PULL_OK is read by _apply_service_update's flip
    # gate; harmless (unset) for any other caller.
    if docker compose "${pflag[@]}" pull "$svc" 2>&1; then
        _MU_PULL_OK=1
    else
        ui_log warn "Pull reported an issue; using cached image."
        _MU_PULL_OK=0
    fi
    if ! _service_is_running "$svc"; then
        ui_log info "${svc} is stopped - the new image is staged and applies next time it starts."
        return 0
    fi
    if docker compose "${pflag[@]}" up -d "$svc" 2>&1; then
        _wait_service_running "$svc"
        ui_log ok "$done_msg"
    else
        ui_log error "Failed to recreate ${svc}."
        return 1
    fi
}

_apply_service_update() {
    local svc="$1" skip_confirm="${2:-}"
    # A service is "on the image it was installed with" when it is stable-effective
    # (still on its lock/tag) OR has a digest pin (was reverted); updating
    # either floats it to its upstream tag and needs consent.
    local is_float=0
    if [[ "$(_effective_channel "$svc")" == "stable" || -n "$(_service_pin "$svc")" ]]; then
        is_float=1
    fi
    if [[ "$svc" == "wireguard" ]]; then
        ui_log warn "Updating WireGuard restarts remote access and may disconnect VPN clients."
        ui_log info "Run this from your LAN / local console if you rely on WireGuard for access."
        ((is_float)) && ui_log warn "It also moves WireGuard to its upstream tag, off the image it was installed with."
        ui_confirm "Update WireGuard now?" no || {
            ui_log info "Skipped WireGuard."
            return 0
        }
        # That single confirm already covers the float consent for WireGuard, so
        # don't re-prompt in the float branch below.
        skip_confirm=1
    fi
    if ((is_float)); then
        # Floating drops this service off the image it was installed with, so
        # confirm first - unless the caller already gathered consent (the "Update
        # all" path, and the WireGuard branch above, pass skip_confirm to avoid a
        # double-prompt).
        if [[ "$skip_confirm" != "1" ]]; then
            ui_log warn "This moves ${svc} to its upstream tag, off the image it was installed with."
            ui_confirm "Update ${svc} to the newest upstream image?" no || {
                ui_log info "Left ${svc} unchanged."
                return 0
            }
        fi
        ui_log info "${svc}: now tracking its upstream tag - off the image it was installed with."
    fi
    # Record a manual 'latest' override on any channel (overwriting any digest pin),
    # so an updated service becomes revertable to its installed image even on a
    # Latest install where updates otherwise leave no policy row. Written before the
    # pull so consent is sticky across a transient pull failure - the next apply (or
    # ./scripts/update.sh) still pulls it forward.
    _set_service_policy "$svc" latest
    _regenerate_override || {
        ui_log error "Could not regenerate compose override."
        return 1
    }
    storage_guard_before_start || return 1
    ui_log info "Pulling ${svc}..."
    _recreate_service "$svc" "${svc} updated." || return 1
    # Flip the row to "Up to date" for the next render without a full rescan, but
    # only when the container is actually running the freshly pulled image
    # (running == upstream by construction). A staged (stopped) service or a
    # pull-failure-cached recreate is left pending - both would still show the
    # update on a rescan. _MU_APPLIED is the submenu's local (dynamic scope);
    # unset (harmless) for other callers.
    if [[ "${_MU_PULL_OK:-0}" == 1 ]] && _service_is_running "$svc"; then
        _MU_APPLIED+=("$svc")
    fi
    # A jellyfin/seerr update can change the log format its fail2ban filter parses,
    # silently breaking brute-force bans. Offer to verify (single-service path only;
    # the "Update all" batch, skip_confirm=1, runs one aggregate check at the end).
    if [[ "$skip_confirm" != "1" ]] && _service_is_running "$svc"; then
        case "$svc" in
            jellyfin | seerr)
                declare -F health_fail2ban_regex >/dev/null 2>&1 || source "$SCRIPT_DIR/scripts/lib/health.sh"
                if _health_f2b_running && ui_confirm "Verify fail2ban still protects ${svc} after this update?" no; then
                    _health_present_spin "Checking fail2ban ${svc} filter (~15s)..." health_fail2ban_regex "$svc"
                fi
                ;;
        esac
    fi
    return 0
}

_reset_service_to_default() {
    local svc="$1" install_ref prior
    install_ref="$(_install_image_ref "$svc")"
    if [[ -z "$install_ref" ]]; then
        ui_log warn "${svc}: no recorded install digest; clearing its override instead."
        _clear_service_policy "$svc"
    else
        prior="$(_service_policy_raw "$svc")"
        _set_service_policy "$svc" "$install_ref"
    fi
    ui_log info "${svc}: reverting to the image it was installed with..."
    _regenerate_override || {
        ui_log error "Could not regenerate compose override."
        return 1
    }
    storage_guard_before_start || return 1
    if _recreate_service "$svc" "${svc} reverted to its installed image."; then
        return 0
    fi
    # Recreate failed. Only a digest pin can point at an unfetchable image; restore
    # the prior override and bring the service back up (onto its previous cached
    # image when that pull also fails, else its prior tracking-tag image).
    if [[ -n "$install_ref" ]]; then
        ui_log warn "${svc}: revert failed (the installed image may no longer be available); restoring its previous image."
        _restore_service_policy_row "$svc" "$prior"
        _regenerate_override || {
            ui_log error "Could not regenerate compose override."
            return 1
        }
        _recreate_service "$svc" "${svc} restored to its previous image." || return 1
    fi
    return 1
}

_update_status_scan() {
    python3 "$SCRIPT_DIR/scripts/image-drift.py" --status-tsv 2>/dev/null
}

_render_update_table() {
    local tsv="$1" svc pol override status upd label color has_manual=0
    printf '  %-13s %-18s %s\n' "SERVICE" "POLICY" "STATUS"
    printf '  %-13s %-18s %s\n' "-------------" "------------------" "------"
    while IFS=$'\t' read -r svc pol override status upd; do
        [[ -z "$svc" ]] && continue
        case "$pol" in
            stable) label="Pinned" ;;
            latest) label="Tracking tag" ;;
            pinned) label="Pinned (install)" ;;
            *) label="$pol" ;;
        esac
        # A pinned service is held on its installed image - the opposite of the `*`
        # footnote ("tracking its upstream tag"), so pins get no star.
        if [[ "$override" == "manual" && "$pol" != "pinned" ]]; then
            label="${label} *"
            has_manual=1
        fi
        case "$status" in
            "Up to date") color="$GREEN" ;;
            "Update available") color="$YELLOW" ;;
            "Not installed" | "Unknown (offline)" | "Unknown local digest") color="$CYAN" ;;
            *) color="$NC" ;;
        esac
        printf '  %-13s %-18s %b%s%b\n' "$svc" "$label" "$color" "$status" "$NC"
    done <<<"$tsv"
    ((has_manual)) && printf '  %s\n' "* manual override - tracking its upstream tag, not the image it was installed with"
}

_mu_scan() {
    local _tmp _out
    _tmp=$(mktemp)
    _mu_scan_to_file() { _update_status_scan >"$_tmp"; }
    ui_spin "Checking each image against its registry..." _mu_scan_to_file
    unset -f _mu_scan_to_file
    _out=$(cat "$_tmp")
    rm -f "$_tmp"
    [[ -z "$_out" ]] && return 1
    tsv=$_out
    return 0
}

_mu_flip_row() {
    local tsv="$1" svc="$2"
    local f_svc pol override status upd newpol
    while IFS=$'\t' read -r f_svc pol override status upd; do
        [[ -z "$f_svc" ]] && continue
        if [[ "$f_svc" == "$svc" ]]; then
            newpol="$(_service_policy "$svc")"
            [[ "$newpol" == "latest" ]] && {
                pol="latest"
                override="manual"
            }
            status="Up to date"
            upd="false"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$f_svc" "$pol" "$override" "$status" "$upd"
    done <<<"$tsv"
}

_menu_update_selected() {
    local tsv="$1" svc pol override status upd
    local -a labels=()
    while IFS=$'\t' read -r svc pol override status upd; do
        [[ "$upd" == "true" ]] || continue
        labels+=("${svc}  (${status})")
    done <<<"$tsv"
    if ((${#labels[@]} == 0)); then
        ui_log info "No services have an available update."
        pause_for_menu
        return 0
    fi
    labels+=("Back")
    local choice
    choice=$(ui_choose "Update which service?" "${labels[@]}")
    [[ "$choice" == "Back" ]] && return 0
    _apply_service_update "${choice%% *}"
    pause_for_menu
}

_menu_update_all() {
    local tsv="$1" svc pol override status upd wg_updatable=0
    local -a svcs=()
    # Every updatable service. WireGuard is excluded - it restarts remote access
    # and force-confirms, so it's updated explicitly via "Update a service".
    while IFS=$'\t' read -r svc pol override status upd; do
        [[ "$upd" == "true" ]] || continue
        if [[ "$svc" == "wireguard" ]]; then
            wg_updatable=1
            continue
        fi
        svcs+=("$svc")
    done <<<"$tsv"
    if ((${#svcs[@]} == 0)); then
        if ((wg_updatable)); then
            ui_log info "Only WireGuard has an update - use 'Update a service' to update it explicitly."
        else
            ui_log info "No updates available."
        fi
        pause_for_menu
        return 0
    fi
    ui_log warn "About to update ${#svcs[@]} service(s) to the newest upstream image."
    ui_log info "This moves them off the images they were installed with."
    ui_log info "Services: ${svcs[*]}"
    ((wg_updatable)) && ui_log info "WireGuard is excluded (remote access) - update it explicitly if needed."
    ui_confirm "Proceed?" no || {
        ui_log info "Cancelled."
        pause_for_menu
        return 0
    }
    local s
    for s in "${svcs[@]}"; do
        # skip_confirm=1: the bulk "Proceed?" above already covered these floats,
        # so don't re-prompt per service inside _apply_service_update.
        _apply_service_update "$s" 1
    done
    # One aggregate fail2ban regex check for any jellyfin/seerr that was updated
    # (the per-service offer is suppressed under skip_confirm=1). No extra prompt.
    declare -F health_present_fail2ban_updates >/dev/null 2>&1 || source "$SCRIPT_DIR/scripts/lib/health.sh"
    health_present_fail2ban_updates "${svcs[@]}"
    pause_for_menu
}

_menu_reset_default() {
    local tsv="$1" svc pol override status upd
    local -a labels=()
    # Only services with an *explicit* override (a floated update) and a container.
    # A stopped one is staged, not started (see _recreate_service); Not installed
    # (no container) is skipped.
    while IFS=$'\t' read -r svc pol override status upd; do
        [[ "$override" == "manual" ]] || continue
        [[ "$status" == "Not installed" ]] && continue
        labels+=("${svc}  (${status})")
    done <<<"$tsv"
    if ((${#labels[@]} == 0)); then
        ui_log info "No services have an update to revert."
        pause_for_menu
        return 1
    fi
    labels+=("Back")
    local choice
    choice=$(ui_choose "Revert which service to its installed image?" "${labels[@]}")
    [[ "$choice" == "Back" ]] && return 1
    _reset_service_to_default "${choice%% *}"
    pause_for_menu
    return 0
}

submenu_manage_updates() {
    # The policy backend (_service_policy / _effective_channel) lives in override.sh,
    # which the launcher otherwise sources only lazily inside _regenerate_override;
    # source it here so the apply/flip helpers below resolve it. Pure function defs,
    # no side effects, no name collisions - idempotent via the type guard.
    type _service_policy &>/dev/null || source "$SCRIPT_DIR/scripts/setup/override.sh"
    # Banner first, then run the registry scan under it (the scan takes a few
    # seconds; showing the banner first tells the user where they are).
    clear
    ui_box "MediaStack - Manage Updates" "$(ui_kv 'Install channel' "${IMAGE_CHANNEL:-stable}")"
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - cannot check for image updates."
        pause_for_menu
        return 0
    fi
    # ui_spin (background, killable): _render_spin runs the scan as a background
    # job that receives a real SIGINT from the process group on Ctrl-C, then
    # re-raises it so the launcher exits cleanly. (Our _render_spin no longer uses
    # `gum spin`, so it can wrap this shell function and isn't hit by gum's
    # spin/Ctrl-C bugs.)
    local tsv=""
    local -a _MU_APPLIED=()
    if ! _mu_scan; then
        ui_log error "Could not read update status (is python3 + python3-yaml installed?)."
        pause_for_menu
        return 0
    fi

    while true; do
        clear
        ui_box "MediaStack - Manage Updates" "$(ui_kv 'Install channel' "${IMAGE_CHANNEL:-stable}")"
        echo ""
        _render_update_table "$tsv"
        echo ""
        local choice _mu_rescan=0
        _MU_APPLIED=()
        choice=$(ui_choose "Manage updates:" \
            "Update a service" \
            "Update all" \
            "Revert a service to its installed image" \
            "Re-check for updates now" \
            "Back")

        case "$choice" in
            "Update a service"*) _menu_update_selected "$tsv" ;;
            "Update all"*) _menu_update_all "$tsv" ;;
            # Revert re-pins a service to its installed image, so a real revert needs
            # a registry comparison to re-derive the status - rescan. But a no-op
            # (nothing to revert, or Back) returns non-zero, so skip the rescan then.
            "Revert a service"*) _menu_reset_default "$tsv" && _mu_rescan=1 ;;
            "Re-check for updates now"*) _mu_rescan=1 ;;
            *) return 0 ;;
        esac

        # Refresh the cached table for the next render. Services updated onto their
        # upstream tag flip locally (no rescan); the explicit re-check and revert
        # rescan the registry.
        if ((_mu_rescan)); then
            _mu_scan || {
                ui_log warn "Could not refresh update status; showing last known."
                pause_for_menu
            }
        else
            local _s
            for _s in "${_MU_APPLIED[@]}"; do
                tsv=$(_mu_flip_row "$tsv" "$_s")
            done
        fi
    done
}

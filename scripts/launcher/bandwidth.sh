#!/usr/bin/env bash
# Owns: The qBittorrent bandwidth-limit day-2 action.
# Sources: launcher globals, .env, scripts/lib/ui.sh, validators.sh, and qBittorrent helpers.

# Guided day-2 adjust of qBittorrent download/upload speed limits (MB/s; the knob
# the wizard set once at install). Reuses the SAME input path as Stage 1
# (ui_input_validated + validate_mb_per_sec, "MB/s" copy) and applies live through
# the product's own qBittorrent API helper (qbt_set_speed_limits) — the limits are
# NOT container env, so a recreate would not change them. Apply-first / persist-on-
# success: .env is only rewritten once the live apply succeeds, so .env never drifts
# ahead of the daemon. Non-TTY safe: the current value is sanitized to a valid number
# before use, so an EOF returns a validator-passing default (no re-prompt loop) and
# "no change" exits before any API call.
action_adjust_bandwidth() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        pause_for_menu
        return 0
    fi
    if ! _service_is_running qbittorrent; then
        ui_log warn "qBittorrent isn't running - start the stack first."
        pause_for_menu
        return 0
    fi

    # A hand-edited .env can hold a non-numeric value; ${x:-0} only defaults on
    # empty, so a stale "10mb"/"5 " would become the prompt default and a non-TTY
    # EOF would re-prompt forever (the default never validates). Sanitize to a
    # valid number first, and say so.
    local cur_dl="${QBT_DL_LIMIT:-0}" cur_ul="${QBT_UL_LIMIT:-0}"
    validate_mb_per_sec "$cur_dl" 2>/dev/null || {
        ui_log warn "Stored download limit '${cur_dl}' isn't a valid MB/s number; using 0 (unlimited)."
        cur_dl=0
    }
    validate_mb_per_sec "$cur_ul" 2>/dev/null || {
        ui_log warn "Stored upload limit '${cur_ul}' isn't a valid MB/s number; using 0 (unlimited)."
        cur_ul=0
    }
    ui_log info "qBittorrent speed limits in MB/s (0 = unlimited). Press Enter to keep a value."
    ui_log info "Current: download ${cur_dl} MB/s, upload ${cur_ul} MB/s."

    local new_dl new_ul
    new_dl=$(ui_input_validated "Download limit (MB/s, 0 = unlimited)" "$cur_dl" validate_mb_per_sec)
    new_ul=$(ui_input_validated "Upload limit (MB/s, 0 = unlimited)" "$cur_ul" validate_mb_per_sec)

    if [[ "$new_dl" == "$cur_dl" && "$new_ul" == "$cur_ul" ]]; then
        ui_log info "No change."
        pause_for_menu
        return 0
    fi
    ui_confirm "Apply download ${new_dl} MB/s / upload ${new_ul} MB/s to qBittorrent now?" yes || {
        ui_log info "No change."
        pause_for_menu
        return 0
    }

    # Source the product's qBittorrent module on demand (the launcher does not load
    # it at startup); the guard makes a repeat visit idempotent.
    type qbt_set_speed_limits &>/dev/null || source "$SCRIPT_DIR/scripts/services/qbittorrent/main.sh"

    ui_log info "Applying new speed limits to qBittorrent..."
    local rc=0
    qbt_set_speed_limits "$new_dl" "$new_ul" || rc=$?
    if ((rc == 0)); then
        # Persist only after the live apply succeeds, so .env stays in lock-step
        # with the running daemon (a future configure run trusts these values).
        _set_env_var QBT_DL_LIMIT "$new_dl"
        _set_env_var QBT_UL_LIMIT "$new_ul"
        _reload_env
    fi
    _show_action_result "$rc" "Adjust bandwidth limits"
    pause_for_menu
}

# Atomically write + secure a DDNS config.json payload to the live path, reusing
# the product's dir-prepare and perms-repair helpers (chown 1000:1000, chmod 600,
# symlink-guarded, sudo fallback). The temp file lives OUTSIDE config/ddns-updater/
# (that dir is writable by the uid-1000 container). Used for both the new write and
# the rollback, so verify-first apply and restore share one code path. Returns
# non-zero on any failure. Requires env-gen.sh to have been sourced by the caller.
# Set by _ddns_write_live_config to 1 the instant the live config.json is replaced
# (the mv lands), before the perms repair. Lets action_change_ddns tell a write
# that never touched the file (mv failed -> old config still intact) from one that
# did (needs a real rollback), so it doesn't cry "config may be inconsistent" when
# nothing changed.

#!/usr/bin/env bash
# Owns: The day-2 quality-profile picker and Sonarr/Radarr apply path.
# Sources: launcher globals, .env, scripts/lib/ui.sh, wizard_apply.py, and configure.sh.

_quality_keys_for_name() {
    local name="$1"
    MS_DIR="$SCRIPT_DIR" TARGET_NAME="$name" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["MS_DIR"], "scripts", "setup"))
import wizard_apply as w
m = w.load_quality_model(os.path.join(os.environ["MS_DIR"], "scripts", "setup", "presets.yml"))
target = os.environ["TARGET_NAME"]
for rk in (m.get("resolutions") or {}):
    for sk in (m.get("sizes") or {}):
        try:
            if w.compose_cell(m, rk, sk)["profile_name"] == target:
                print(rk + " " + sk); sys.exit(0)
        except Exception:
            pass
' 2>/dev/null
}

action_change_quality() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        pause_for_menu
        return 0
    fi
    if ! _service_is_running sonarr || ! _service_is_running radarr; then
        ui_log warn "Sonarr and Radarr both need to be running - start the stack first."
        pause_for_menu
        return 0
    fi

    # Shared two-axis picker — the SAME one the setup wizard uses, so the two
    # surfaces can never drift. Sourced lazily (guard makes repeat visits cheap).
    type quality_select_pick &>/dev/null || source "$SCRIPT_DIR/scripts/lib/quality_select.sh"

    local cur_name
    cur_name=$(CONFIG_FILE="$SCRIPT_DIR/config.yml" cfg_field "quality_profile.name" 2>/dev/null)
    if [[ -z "$cur_name" ]]; then
        # No readable profile name means we can't safely target an in-place
        # rename (QP_RENAME_FROM would match nothing, and configure.sh would
        # refuse rather than orphan). Bail with a clear message instead.
        ui_log warn "Couldn't read the current quality profile from your settings - can't change it safely. No change."
        pause_for_menu
        return 0
    fi
    ui_log info "Current quality profile: ${cur_name}"
    ui_log info "Re-pick the resolution ceiling and file-size envelope. This rewrites only"
    ui_log info "the quality settings; your indexers, subtitles and bandwidth stay as-is."

    # Pre-select the current cell when its name maps to a known (res, size).
    local keys def_res="" def_size=""
    keys=$(_quality_keys_for_name "$cur_name")
    read -r def_res def_size <<<"$keys"

    local new_res new_size
    if ! quality_select_pick new_res new_size "$def_res" "$def_size"; then
        ui_log warn "Could not read the quality menu - no change."
        pause_for_menu
        return 0
    fi

    # Compose the target name from the product (no duplicated naming logic).
    local new_name
    new_name=$(MS_DIR="$SCRIPT_DIR" QSEL_RES="$new_res" QSEL_SIZE="$new_size" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["MS_DIR"], "scripts", "setup"))
import wizard_apply as w
m = w.load_quality_model(os.path.join(os.environ["MS_DIR"], "scripts", "setup", "presets.yml"))
print(w.compose_cell(m, os.environ["QSEL_RES"], os.environ["QSEL_SIZE"])["profile_name"])
' 2>/dev/null)
    if [[ -z "$new_name" ]]; then
        ui_log warn "Could not compose the chosen quality cell - no change."
        pause_for_menu
        return 0
    fi
    if [[ "$new_name" == "$cur_name" ]]; then
        ui_log info "Already on '${new_name}'. No change."
        pause_for_menu
        return 0
    fi

    ui_log warn "Changing to '${new_name}' makes Sonarr/Radarr re-search and upgrade"
    ui_log warn "existing media toward the new ceiling - expect extra downloads and disk use."
    ui_log info "Your existing profile is renamed in place ('${cur_name}' -> '${new_name}') - no duplicate profile is created."
    ui_confirm "Apply '${new_name}' to Sonarr and Radarr now?" no || {
        ui_log info "No change."
        pause_for_menu
        return 0
    }

    ui_log info "Rewriting quality settings..."
    local rc=0 rename_failed="" qp_status_file="" _qa_out _qa_line
    _qa_out=$(python3 "$SCRIPT_DIR/scripts/setup/wizard_apply.py" --quality-only \
        --resolution "$new_res" --size "$new_size" \
        --config "$SCRIPT_DIR/config.yml") || rc=$?
    while IFS= read -r _qa_line; do
        [[ -n "$_qa_line" ]] && ui_log ok "$_qa_line"
    done <<<"$_qa_out"
    if ((rc == 0)); then
        ui_log info "Re-pushing '${new_name}' to Sonarr and Radarr (renaming in place, no orphan)..."
        # QP_RENAME_FROM tells configure_quality_profile to PUT the new render
        # onto the OLD profile's id instead of POSTing a duplicate. configure.sh
        # keeps its deliberate never-abort exit-0 contract even when a rename
        # fails, so the *arr configurator records any app it could NOT rename to
        # QP_RENAME_STATUS — we read that to report honestly instead of a false
        # "completed successfully".
        qp_status_file=$(mktemp 2>/dev/null) || qp_status_file=""
        QP_RENAME_FROM="$cur_name" QP_RENAME_STATUS="$qp_status_file" \
            "$SCRIPT_DIR/scripts/configure.sh" --only sonarr,radarr || rc=$?
        if [[ -n "$qp_status_file" ]]; then
            [[ -s "$qp_status_file" ]] && rename_failed=$(tr '\n' ' ' <"$qp_status_file" | sed 's/ *$//')
            rm -f "$qp_status_file"
        fi
    fi
    if ((rc != 0)); then
        _show_action_result "$rc" "Change quality profile"
    elif [[ -n "$rename_failed" ]]; then
        echo ""
        ui_log warn "Quality change did NOT apply to: ${rename_failed} (see the messages above)."
        ui_log warn "Your library still uses '${cur_name}'. Fix the warning and retry, or rebuild."
    elif [[ -z "$qp_status_file" ]]; then
        # mktemp failed, so we couldn't capture the re-push's per-app outcome.
        # Under-claim rather than over-claim (cf. _run_setup_return): the re-push
        # most likely applied, but we can't confirm it from here.
        echo ""
        ui_log warn "Re-pushed '${new_name}', but couldn't verify the result - check the messages above to confirm it applied to Sonarr and Radarr."
    else
        _show_action_result 0 "Change quality profile"
    fi
    pause_for_menu
}

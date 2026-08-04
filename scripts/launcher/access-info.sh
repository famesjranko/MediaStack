#!/usr/bin/env bash
# Owns: The day-2 access-information view.
# Sources: scripts/setup/stack.sh (lazy), launcher globals, and scripts/lib/ui.sh.

action_access_info() {
    type print_access_info &>/dev/null || source "$SCRIPT_DIR/scripts/setup/stack.sh"
    print_access_info mask

    local pw
    pw=$(_access_admin_pw)
    if [[ -n "$pw" ]]; then
        echo ""
        # Flush any buffered type-ahead first so a stray pre-typed keystroke can't
        # auto-confirm revealing the shared credential. Interactive TTY only — a
        # non-TTY caller's default ("no") already suppresses the reveal, and draining
        # a pipe would eat input meant for later prompts.
        if [[ -t 0 ]]; then
            local _flush
            read -rsd '' -t 0.01 _flush 2>/dev/null || true
        fi
        if ui_confirm "Reveal the admin password? (it is your single login for every service)" no; then
            echo -e "  ${BOLD}Admin password:${NC}   ${GREEN}${pw}${NC}"
            echo ""
        fi
    fi
}

# =============================================================================
# Action wrappers (call existing scripts)
# =============================================================================

# Capstone summary printed after each action so the user gets an unambiguous
# verdict, not just whatever raw output the script emitted.
#
# A bare exit code can't tell a real wipe/reinstall apart from "user backed out"
# (both exit 0) or a deliberate abort apart from a crash (both exit non-zero), so
# _run_setup_return plumbs an outcome token out of setup.sh:
#   completed → genuine success    aborted → deliberate abort
#   unchanged → nothing changed    failed → partial/failed action
#   (empty) → setup.sh said nothing
# For STRICT actions (install / wipe) success must be AFFIRMED by a `completed`
# token: a bare exit 0 with no token means the wizard was aborted before
# finishing (e.g. quit a Stage-1 prompt after a wipe), so we must NOT call that
# "completed successfully". Non-strict actions (remote / transcoding / port-check
# / update) keep the simple rc-based verdict.

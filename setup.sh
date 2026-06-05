#!/usr/bin/env bash
# =============================================================================
# MediaStack Setup Script
# =============================================================================
# Most users should run ./mediastack instead. The launcher detects machine
# state and calls this script for them. Run setup.sh directly only for a
# scripted / non-interactive install (see README "Scripted / automation
# install").
#
# Usage:
#   ./setup.sh          # Stack setup only (Docker must be installed)
#   ./setup.sh --full   # Full setup from bare Debian (installs Docker)
#   ./setup.sh --remote # Retry remote access setup after Stage 1
#   ./setup.sh --transcoding # Retry hardware transcoding setup after Stage 1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Demo mode renders the UI for review / screenshots, usually through a pipe
# (non-TTY) and sometimes with NO_COLOR set. Force the full colour + glyph
# render BEFORE the UI libs below freeze their palette + glyph vocabulary at
# source time — ui_demo.sh also sets these, but it is sourced too late to win.
[[ " $* " == *" --demo "* ]] && export UI_DEMO=1 UI_FORCE_COLOR=1 UI_FORCE_GLYPHS=1

source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/ui.sh"

# --- Setup modules ---
source "$SCRIPT_DIR/scripts/setup/checks.sh"
source "$SCRIPT_DIR/scripts/setup/packages.sh"
source "$SCRIPT_DIR/scripts/setup/gpu.sh"
source "$SCRIPT_DIR/scripts/setup/override.sh"
source "$SCRIPT_DIR/scripts/setup/env_gen.sh"
source "$SCRIPT_DIR/scripts/setup/storage.sh"
source "$SCRIPT_DIR/scripts/setup/wizard.sh"
source "$SCRIPT_DIR/scripts/setup/reboot.sh"
source "$SCRIPT_DIR/scripts/setup/stack.sh"
source "$SCRIPT_DIR/scripts/setup/hardening.sh"
source "$SCRIPT_DIR/scripts/setup/recovery.sh"

# =============================================================================
# Main
# =============================================================================

# Interactive interrupt handler. The target user reflexively hits Ctrl-C on a
# long, opaque wait (pull_images / start_stack are plain foreground commands)
# and otherwise lands on a bare bash prompt with no idea whether the box is
# half-broken or how to resume. Installed only on a TTY (see main), so CI,
# piped stdin, and the post-reboot systemd run (all non-TTY) behave exactly as
# before and the post-reboot ERR trap is untouched.
_setup_on_interrupt() {
    trap - INT TERM
    echo ""
    log_warn "Setup interrupted."
    if [[ -n "${DATA_DIR:-}" ]]; then
        log_info "Nothing was destroyed — your media in ${DATA_DIR} is untouched."
    else
        log_info "Nothing was destroyed — your existing media and downloads are untouched."
    fi
    log_info "Re-run ./setup.sh to resume where you left off."
    exit 130
}

main() {
    ui_banner "MediaStack Setup" "Turnkey Media Server for Home Networks"

    # Track whether this is a post-reboot resume so we can write login
    # feedback when it finishes (success or failure).
    local _is_post_reboot=false
    if [[ -f /etc/systemd/system/mediastack-setup.service ]]; then
        _is_post_reboot=true
    fi

    if $_is_post_reboot; then
        trap 'write_setup_result "error"' ERR
    fi

    # Reassure a user who Ctrl-C's a long step. Interactive only: on a non-TTY
    # (CI, piped stdin, post-reboot systemd) the trap is never installed, so
    # signal handling and the ERR trap above stay exactly as before. Single
    # quotes keep $DATA_DIR expansion at fire-time, not install-time.
    if [[ -t 0 ]]; then
        trap '_setup_on_interrupt' INT TERM
    else
        # Non-TTY (piped) only: ui_choose SIGTERMs the process group when its
        # stdin runs dry. Map that group-kill to a distinct, documented exit
        # code so a piped driver can tell "input exhausted" apart from a generic
        # kill (143) or a real failure. ERR/post-reboot handling above is on a
        # different signal and is untouched.
        trap 'log_warn "No more input on stdin - exiting non-interactive setup."; exit '"${UI_EXIT_INPUT_EXHAUSTED:-3}"'' TERM
    fi

    check_not_root
    check_debian

    if stage3_marker_exists; then
        if stage3_marker_ready_to_finalize; then
            cleanup_post_reboot
            if [[ -f "$SCRIPT_DIR/.env" ]]; then
                set -a
                source "$SCRIPT_DIR/.env"
                set +a
            fi
            stage3_finalize_nvidia
            if $_is_post_reboot; then
                write_setup_result "ok"
            fi
            record_launcher_outcome completed
            return 0
        fi
        log_info "NVIDIA hardware transcoding is prepared; finalization will run after reboot."
    fi

    if [[ "${1:-}" == "--remote" ]]; then
        run_remote_recovery
        return $?
    fi

    if [[ "${1:-}" == "--transcoding" ]]; then
        run_transcoding_recovery
        return $?
    fi

    # Initialise globals BEFORE pre-flight so PRE-07's stash_gpu_type has a
    # defined destination. In --full mode, GPU_TYPE is re-stashed after base
    # packages install pciutils so bare Debian hosts do not miss GPUs.
    # FULL_MODE must be parsed before Docker-dependent checks so
    # ./setup.sh --full can install Docker on a bare host.
    FULL_MODE=false
    if [[ "${1:-}" == "--full" ]]; then
        FULL_MODE=true
    fi

    # Auto-promote to --full when Docker/Compose is missing AND we're on an
    # interactive TTY, so a non-technical user on a bare Debian host doesn't
    # have to know what `--full` means. CI / piped-stdin keeps the historical
    # hard-fail behavior so automation surfaces missing prereqs explicitly.
    if ! $FULL_MODE && [[ -t 0 && "${MEDIASTACK_NONINTERACTIVE:-0}" != "1" ]]; then
        if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
            echo ""
            log_warn "Docker and/or Docker Compose v2 is not installed on this host."
            log_info "Docker is the container engine MediaStack runs on - a normal, safe one-time install."
            log_info "MediaStack can install them now via the official Docker apt repository."
            local _install_choice
            _install_choice=$(ui_choose "Install prerequisites and continue?" \
                "Install Docker + Compose and continue" \
                "Exit (I'll install Docker myself)")
            case "$_install_choice" in
                "Install Docker + Compose and continue")
                    FULL_MODE=true
                    log_ok "Will install prerequisites - equivalent to ./setup.sh --full"
                    ;;
                *)
                    log_info "Exiting. Install Docker, then re-run ./setup.sh"
                    record_launcher_outcome aborted
                    exit 1
                    ;;
            esac
        fi
    fi
    NEEDS_REBOOT=false
    GPU_TYPE="none"
    local watchdog_paused_before_wizard=false

    # --- Pre-flight battery ---
    # Hard fails run before user prompts; detect_existing_install runs LAST
    # so the user is only asked to type
    # DESTROY on a host already confirmed viable.
    check_disk_floor
    check_internet_reachability
    check_ram_warn
    prompt_sudo_cache
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
        if [[ "${STAGE_1_COMPLETE:-}" != "1" ]]; then
            storage_pause_watchdog_for_install || return 1
            watchdog_paused_before_wizard=true
        fi
    fi
    stash_gpu_type
    if ! $FULL_MODE; then
        check_docker
        check_compose
    fi
    local existing_install_rc=0
    detect_existing_install || existing_install_rc=$?
    case "${RECOVERY_MENU_ACTION:-}" in
        continue)
            return 0
            ;;
        completed|abort)
            return "$existing_install_rc"
            ;;
        wipe)
            if (( existing_install_rc != 0 )); then
                return "$existing_install_rc"
            fi
            ;;
        "")
            if (( existing_install_rc != 0 )); then
                return "$existing_install_rc"
            fi
            ;;
        *)
            if (( existing_install_rc != 0 )); then
                return "$existing_install_rc"
            fi
            ;;
    esac
    # --- end pre-flight ---

    if $FULL_MODE; then
        log_info "Full setup mode: installing prerequisites..."
        echo ""

        install_base_packages
        check_internet_reachability
        install_docker
        check_docker
        check_compose
        stash_gpu_type

        echo ""
    fi

    # Standard setup (both --full and default reach here)
    # check_docker + check_compose moved to pre-flight battery (D-04).
    cleanup_post_reboot

    # Ensure python3-yaml is available for configure.sh
    if ! python3 -c "import yaml" 2>/dev/null; then
        log_info "Installing python3-yaml (needed for config parsing)..."
        sudo apt-get install -y -qq python3-yaml >/dev/null 2>&1
    fi

    # check_disk_space replaced by check_disk_floor in pre-flight battery (PRE-01).
    detect_host_memory
    echo ""

    setup_hardening
    echo ""

    detect_env

    if [[ "$watchdog_paused_before_wizard" != "true" && -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
        if [[ "${STAGE_1_COMPLETE:-}" != "1" ]]; then
            storage_pause_watchdog_for_install || return 1
            watchdog_paused_before_wizard=true
        fi
    fi

    run_wizard

    # Re-source .env for DATA_DIR/PUID/PGID
    set -a; source "$SCRIPT_DIR/.env"; set +a

    if [[ "$watchdog_paused_before_wizard" != "true" && "${WIZARD_RAN_INSTALL:-false}" != "true" && "${STAGE_1_COMPLETE:-}" != "1" ]]; then
        storage_pause_watchdog_for_install || return 1
    fi

    setup_ufw_service_ports
    setup_samba

    if [[ "${WIZARD_RAN_INSTALL:-false}" == "true" ]]; then
        if $_is_post_reboot; then
            write_setup_result "ok"
        fi
        record_launcher_outcome completed
        return 0
    fi

    # Belt-and-braces guard against BL-03: if a completed Stage 1 ever reaches
    # this point with WIZARD_RAN_INSTALL unset (e.g. future edit clears it),
    # the late install block below would tear down the running stack on every
    # re-run. Project invariants require re-runs to skip already-configured
    # services. run_stage1 already sets WIZARD_RAN_INSTALL=true on the skip
    # path, so reaching here with STAGE_1_COMPLETE=1 indicates a regression.
    if [[ "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        log_skip "Stage 1 marker present - skipping late install block (no stack churn on re-run)"
        if $_is_post_reboot; then
            write_setup_result "ok"
        fi
        record_launcher_outcome completed
        return 0
    fi

    stop_existing_stack
    create_data_dirs
    create_config_dirs
    generate_override "$GPU_TYPE"

    echo ""
    pull_images

    echo ""
    start_stack
    storage_install_watchdog
    wait_all_healthy

    # Run auto-configuration (wire up Sonarr/Radarr/qBittorrent/Jackett)
    echo ""
    log_info "Running auto-configuration..."
    "$SCRIPT_DIR/scripts/configure.sh"

    print_access_info

    if $_is_post_reboot; then
        write_setup_result "ok"
    fi
    record_launcher_outcome completed
}

# --- Demo mode: exercise UI components without touching the system ---
if [[ "${1:-}" == "--demo" ]]; then
    source "$SCRIPT_DIR/scripts/lib/ui_demo.sh"
    run_demo "${2:-auto}"
    exit 0
fi

# Only run main when executed directly; sourcing for tests should expose the
# helper functions without triggering the installer flow.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

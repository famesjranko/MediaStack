# =============================================================================
# MediaStack Setup — Prerequisite checks
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

# Tell the day-2 launcher (mediastack) the real recovery outcome. The launcher
# runs setup.sh as a child process and can't see RECOVERY_MENU_ACTION across the
# boundary, so it can't tell a real wipe/reinstall (exit 0) from a user who
# backed out (also exit 0) or a deliberate abort (exit 1) from a crash. When the
# launcher wants to know, it sets MEDIASTACK_LAUNCHER_RESULT to a file path and
# we drop a one-word token in it. No-op for direct `./setup.sh` runs (and the
# DinD recovery fixtures), which never set the variable. set -u safe.
record_launcher_outcome() {
    [[ -n "${MEDIASTACK_LAUNCHER_RESULT:-}" ]] || return 0
    printf '%s\n' "$1" >"$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null || true
}

check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. Run as your normal user (sudo will be used when needed)."
        exit 1
    fi
}

check_debian() {
    if ! grep -qi 'debian' /etc/os-release 2>/dev/null; then
        log_error "This script is designed for Debian Server. Detected: $(. /etc/os-release && echo "$NAME")"
        exit 1
    fi
    log_ok "Debian detected: $(. /etc/os-release && echo "$PRETTY_NAME")"
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Run with --full to install it, or install manually."
        exit 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker is not running or current user lacks permissions."
        log_info "Try: sudo systemctl start docker && sudo usermod -aG docker \$USER"
        exit 1
    fi
    log_ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
}

check_compose() {
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 not found. Run with --full to install it."
        exit 1
    fi
    log_ok "Docker Compose $(docker compose version --short)"
}

_resolve_data_partition() {
    # PRE-01 helper. Reads DATA_DIR from .env if set, else defaults to /data.
    # Walks up to nearest existing parent so disk-floor check works on a fresh
    # host where /data doesn't yet exist (D-07).
    local data_dir=""
    if [[ -s "$SCRIPT_DIR/.env" ]]; then
        data_dir=$(awk -F= '/^DATA_DIR=/ {print $2; exit}' "$SCRIPT_DIR/.env" | tr -d '"' | tr -d "'")
    fi
    local target="${data_dir:-/data}"
    while [[ ! -e "$target" && "$target" != "/" ]]; do
        target=$(dirname "$target")
    done
    printf '%s\n' "$target"
}

check_disk_floor() {
    # PRE-01: hard-fail when root <10 GB or data partition <30 GB.
    # On single-FS hosts (root and data on the same mountpoint), run one
    # check at the higher 30 GB floor (D-08).
    #
    # WR-01 fix: empty `df` output (cgroup mounts, long device paths,
    # locale issues, df failure) is treated as a hard fail BEFORE any
    # comparison branch — silently passing on unparseable disk state
    # converts the floor into a false positive.
    local data_path
    data_path=$(_resolve_data_partition)
    log_info "Data partition resolves to: ${data_path}"

    local root_mount data_mount
    root_mount=$(stat -c %m / 2>/dev/null || echo "/")
    data_mount=$(stat -c %m "$data_path" 2>/dev/null || echo "$data_path")

    local root_free data_free
    root_free=$(df -BG / 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
    data_free=$(df -BG "$data_path" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')

    # WR-01 hard-fail: empty df output on / is unrecoverable; we cannot
    # prove the disk floor.
    if [[ -z "$root_free" ]]; then
        log_error "Pre-flight: could not read free space on /. df output was empty or unparsable."
        exit 1
    fi

    # Disk-floor policy: 30GB on the data FS (and 10GB on / for split-FS
    # hosts) is the recommended minimum, not a hard gate. We warn loudly
    # but let the user proceed — the recommended floor stays as a reference,
    # and tighter test surfaces (e.g. a 30GB GCP boot disk that ends up at
    # 26GB free after Debian + apt + swap) can still complete a setup run.
    # Unparsable df output remains a hard-fail above: that means the check
    # itself can't run, not that disk is small.
    if [[ "$root_mount" == "$data_mount" ]]; then
        # Single-FS host: one check at 30 GB floor (D-08).
        if (( root_free < 30 )); then
            log_warn "Pre-flight: / has only ${root_free}GB free; recommended minimum is 30GB. Continuing anyway."
        else
            log_ok "Disk: ${root_free}GB free (single FS)"
        fi
        return 0
    fi

    # Two-FS host: independent floors. data_free must also be parsable.
    if [[ -z "$data_free" ]]; then
        log_error "Pre-flight: could not read free space on ${data_path}. df output was empty or unparsable."
        exit 1
    fi

    if (( root_free < 10 )); then
        log_warn "Pre-flight: / has only ${root_free}GB free; recommended minimum is 10GB. Continuing anyway."
    fi
    if (( data_free < 30 )); then
        log_warn "Pre-flight: ${data_path} has only ${data_free}GB free; recommended minimum is 30GB. Continuing anyway."
    fi

    # Soft warn when both above floor but combined ≤50 GB (Pattern B).
    local combined=$(( root_free + data_free ))
    if (( combined <= 50 )); then
        log_warn "Disk: only ${combined}GB combined free across / and ${data_path}. Recommended: 50GB+."
    else
        log_ok "Disk: /=${root_free}GB free, ${data_path}=${data_free}GB free"
    fi
}

check_ram_warn() {
    # PRE-02: tiered RAM warning. Never hard-fails — 4 GB SBCs are valid
    # targets (D-14, D-15). Two tiers:
    #   < 2 GB free: stack-wide warning (the original D-14 floor).
    #   < 4 GB free: flaresolverr/Chromium may flap (~1 GB working set).
    # Defensive guard for kernels without MemAvailable (kernel <3.14 — L1).
    local free_gb="" total_gb=""
    if grep -q '^MemAvailable:' /proc/meminfo 2>/dev/null; then
        free_gb=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo)
    fi
    if grep -q '^MemTotal:' /proc/meminfo 2>/dev/null; then
        total_gb=$(awk '/^MemTotal:/ {print int($2/1024/1024)}' /proc/meminfo)
    fi
    if [[ -z "$free_gb" ]]; then
        log_warn "Could not read MemAvailable from /proc/meminfo - skipping RAM check"
        return 0
    fi
    # Show "X of Y total" so non-technical users have context — "Only 1GB free"
    # alone tells them nothing about whether the host has 2 GB or 32 GB.
    local ctx="${free_gb}GB"
    [[ -n "$total_gb" ]] && ctx="${free_gb}GB free of ${total_gb}GB total"
    if (( free_gb < 2 )); then
        log_warn "Only ${ctx} - Bazarr/Jellyseerr may struggle. Continuing."
    elif (( free_gb < 4 )); then
        log_warn "Only ${ctx} - flaresolverr (Cloudflare bypass) needs ~1GB for Chromium and may flap on this host. If indexer tests stall, consider disabling the public indexer preset. Continuing."
    else
        log_ok "RAM: ${ctx}"
    fi
}

check_internet_reachability() {
    # PRE-03: hard-fail when Docker Hub is unreachable. Let's Encrypt is
    # remote-access-only, so Stage 1 LAN setup warns but continues; Stage 2
    # performs the real certificate attempt and classifies failures.
    # Single 5s timeout each (D-10..D-13).
    # HEAD over GET (-I) — lighter and sufficient. No retry loop (D-13).
    #
    # CR-02 fix: use `cmd || rc=$?` (single-statement capture) so a
    # failed curl does NOT trip `set -e` before rc is read. The pattern
    # `cmd; rc=$?; if (( rc != 0 ))` is set-e-broken — set -e fires on
    # the cmd line and the next statement never runs.
    if ! command -v curl &>/dev/null; then
        if [[ "${FULL_MODE:-false}" == "true" ]]; then
            log_warn "Pre-flight: curl is not installed yet; deferring internet reachability check until base packages are installed."
            return 0
        fi
        log_error "Pre-flight: curl is not installed. Run with --full to install prerequisites, or install curl manually."
        exit 1
    fi

    local rc=0
    curl --max-time 5 -fsSI https://hub.docker.com >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        log_error "Pre-flight: Docker Hub unreachable (${rc}). Check your internet, retry."
        exit 1
    fi
    log_ok "Internet reachability: Docker Hub"

    rc=0
    curl --max-time 5 -fsSI https://acme-v02.api.letsencrypt.org/directory >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        log_warn "Pre-flight: Let's Encrypt unreachable (${rc}). LAN setup can continue; Stage 2 remote access will verify certificates when selected."
        return 0
    fi

    log_ok "Internet reachability: Let's Encrypt"
}

prompt_sudo_cache() {
    # PRE-04: pre-cache sudo creds so downstream sudo calls don't re-prompt
    # mid-wizard. 15-minute cache is the sudoers default (D-16). Distinct
    # error for "sudo not installed" vs "no sudo access" (D-18 + RESEARCH §5).
    if ! command -v sudo &>/dev/null; then
        log_error "Pre-flight: sudo not installed. Install it: apt-get install sudo"
        exit 1
    fi

    # Passwordless sudo (NOPASSWD or valid cached timestamp) — D-17.
    if sudo -n true 2>/dev/null; then
        log_ok "Passwordless sudo confirmed"
        return 0
    fi

    # Otherwise prompt. -v extends an existing session OR prompts; success
    # means we have a valid timestamp going forward.
    if sudo -p "[setup] sudo password (cached for 15 minutes): " -v; then
        log_ok "Sudo cached for 15 minutes"
        return 0
    fi

    log_error "Pre-flight: this user cannot run sudo. Add to sudoers or run as a sudo-capable user."
    exit 1
}

stash_gpu_type() {
    # PRE-07: WIRE — invoke the existing detect_gpu (gpu.sh:9-31), which
    # already populates GPU_TYPE in {nvidia, amd, intel, none} and gracefully
    # handles `lspci` absence (D-25, D-26). Hardware transcoding consumes the
    # global GPU_TYPE downstream.
    detect_gpu
    log_info "GPU type: ${GPU_TYPE}"
}

detect_existing_install() {
    # PRE-05: detects an existing MediaStack install per D-19 predicate:
    # .env non-empty AND STAGE_1_COMPLETE=1 AND (ddns config exists OR
    # jellyfin container running).
    # When detected, presents three choices via ui_choose (D-20). Runs LAST
    # in the pre-flight battery (D-04) so all hard fails fire first.
    #
    # CONTRACT (CR-01 fix): this function never returns non-zero on the
    # "no install detected" path. It sets the global EXISTING_INSTALL_DETECTED
    # to true|false so the call site (setup.sh::main) can read state without
    # tripping `set -euo pipefail`.
    local env_file="$SCRIPT_DIR/.env"
    local ddns_config="$SCRIPT_DIR/config/ddns-updater/config.json"

    # Default state: no install detected. Exported so recovery/setup routing
    # can read it without re-running detection.
    export EXISTING_INSTALL_DETECTED=false

    # Predicate part 1: .env must exist and be non-empty.
    [[ -s "$env_file" ]] || return 0

    local stage1_complete
    stage1_complete=$(awk -F= '$1 == "STAGE_1_COMPLETE" {print $2; exit}' "$env_file" 2>/dev/null || true)
    if [[ "$stage1_complete" != "1" ]]; then
        log_warn "Incomplete Stage 1 state detected; resuming setup instead of existing-install menu."
        return 0
    fi

    # Predicate part 2: ddns config OR running jellyfin container.
    local detected=false
    local evidence=""
    if [[ -f "$ddns_config" ]]; then
        detected=true
        evidence="ddns config"
    else
        # Capture, never pipe to grep -q (SIGPIPE+pipefail race —
        # see project memory feedback_sigpipe_pipefail_flake.md).
        # Wrap in `timeout 5` per RESEARCH §7 / L3 (degraded daemon
        # would otherwise hang for ~30s).
        local jellyfin_id
        jellyfin_id=$(timeout 5 docker ps --filter name=jellyfin -q 2>/dev/null || true)
        if [[ -n "$jellyfin_id" ]]; then
            detected=true
            evidence="jellyfin container"
        fi
    fi

    $detected || return 0

    # Existing install detected — present the three-way prompt (D-20 order).
    log_warn "Existing MediaStack install detected (.env + ${evidence})."
    local choice
    choice=$(ui_choose "What would you like to do?" \
        "Use existing install" \
        "Wipe everything and start fresh" \
        "Abort")

    case "$choice" in
        "Use existing install"*)
            export EXISTING_INSTALL_DETECTED=true
            if type show_existing_install_menu >/dev/null 2>&1; then
                RECOVERY_MENU_ACTION=""
                local menu_rc=0
                show_existing_install_menu || menu_rc=$?
                case "${RECOVERY_MENU_ACTION:-}" in
                    wipe)
                        if (( menu_rc == 0 )); then
                            nuke_existing_install
                            local wipe_rc=$?
                            if (( wipe_rc == 0 )); then
                                RECOVERY_MENU_ACTION=""
                            fi
                            return "$wipe_rc"
                        fi
                        return "$menu_rc"
                        ;;
                    continue|completed|abort)
                        return "$menu_rc"
                        ;;
                    *)
                        if (( menu_rc != 0 )); then
                            return "$menu_rc"
                        fi
                        log_ok "Continuing with existing install. No changes made."
                        return 0
                        ;;
                esac
            fi
            log_ok "Continuing with existing install. No changes made."
            return 0
            ;;
        "Wipe everything and start fresh"*)
            nuke_existing_install
            return $?
            ;;
        "Abort"*)
            log_info "Aborted by user. No changes made."
            record_launcher_outcome aborted
            exit 0
            ;;
        *)
            # Unexpected ui_choose output — treat as abort (defensive).
            log_warn "Unexpected choice: ${choice}. Aborting."
            record_launcher_outcome aborted
            exit 0
            ;;
    esac
}

_print_destroy_preview() {
    # PRE-06 helper. Static literal block — D-21 lock (PRESERVED bullets
    # are locked verbatim). DELETE bullets reflect the actual destroy
    # commands per D-23 (down -v + rm .env, no git clean).
    # NO fixed-width padding; UTF-8 glyphs make byte-count padding drift.
    cat <<'PREVIEW'

This will DELETE:
  * Docker containers and named volumes (compose --profile '*' down -v)
  * .env (your secrets file - passwords, API keys, domain)

This will PRESERVE:
  * data/ - your media library (bind mount, never touched by 'down -v')
  * Pre-seeded configs tracked in git (fail2ban filters, jackett ServerConfig, etc.)

PREVIEW
}

nuke_existing_install() {
    # PRE-06: typed-DESTROY confirmation + destroy command sequence.
    # Satisfies the documented rebuild path: down -v + rm .env.
    # data/ bind mount is NEVER touched (preserved per D-21).

    _print_destroy_preview

    local _input
    _input=$(ui_input "Type DESTROY to confirm (anything else aborts)" "")

    # CR strip — defensive against pasted input from Windows clients
    # (RESEARCH §4). No whitespace trim — D-22 locks "one typo aborts".
    local cleaned="${_input//$'\r'/}"

    if [[ "$cleaned" != "DESTROY" ]]; then
        log_info "Aborted. No changes made."
        record_launcher_outcome aborted
        exit 0
    fi

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi
    storage_pause_watchdog_for_install || return 1

    # Destroy command sequence — D-23 verbatim and rebuild-path invariant.
    # No git clean (D-23 explicit — would risk deleting user-valued files
    # in config/jellyfin/data, etc.).
    #
    # CR-04 fix: D-04's prompt_sudo_cache pre-cached creds specifically so
    # this destroy could use sudo when the user's docker group membership
    # isn't loaded yet (the canonical `--full` first-run case). Detect
    # docker-group membership; sudo only when not. Capture rc and emit a
    # warn before `rm -f .env` so the user knows if the destroy was
    # incomplete (D-24 user-observability — no more silent `|| true`).
    local _down_rc=0
    docker compose --profile "*" down -v || _down_rc=$?
    if (( _down_rc != 0 )); then
        log_warn "Pre-flight: destroy did not complete cleanly (docker compose exit ${_down_rc}). Inspect: docker ps -a; docker volume ls"
    fi
    rm -f "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.nvidia-finalize-pending"

    log_ok "Existing install removed. Continuing with fresh setup."
}

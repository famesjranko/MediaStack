# =============================================================================
# MediaStack — `--dry-run` UI explorer
# =============================================================================
# Walk the REAL setup wizard (./setup.sh) and day-2 launcher (./mediastack) by
# hand, with every side effect neutralised — a genuine no-op. The real menus,
# prompts, branches, and rendering run; anything that would change the system
# announces "DRY-RUN: would ..." and does nothing.
#
# SAFETY MODEL: the dry-run runs inside a throwaway, NON-privileged,
# `--network none`, NON-root container (the repo is COPIED in, never bind-mounted
# read-write), so a missed stub cannot touch the host, cannot egress the network,
# and dangerous binaries are absent so they fail harmlessly. The stubs below are
# therefore a FIDELITY aid (keep the walk flowing + print "would ..."), not the
# safety boundary. This is why the dev host (which is production) stays untouched.
#
# Two halves:
#   * Host driver  — `dry_run_launch <entry>`: builds the image, starts the
#     container, copies the repo in, and re-invokes the entry inside it. The
#     trust signal that it is safe to run the stubs is the baked-in sentinel
#     `/etc/ms-dry-run-sandbox` (`dry_run_in_sandbox`), NOT an env var.
#   * In-container — `dry_run_begin`: install fidelity stubs, seed simulated
#     state, then the entry dispatches the REAL flow (mediastack `main`, or the
#     wizard/recovery functions).
# =============================================================================

: "${DRY_RUN_IMAGE:=ms-dry-run:debian}"

_dry_run_would() { printf '  \033[1;33mDRY-RUN:\033[0m would %s\n' "$*" >&2; }

# True only INSIDE the dedicated dry-run sandbox container — the sentinel is baked
# into tests/Dockerfile.dry-run and exists nowhere else. This file marker (NOT an
# env var, which could be set accidentally) is the trust signal that it is safe to
# install no-op stubs and write seed files: on any real host the marker is absent,
# so the entry scripts launch the sandbox and dry_run_begin refuses to run.
dry_run_in_sandbox() { [[ -f /etc/ms-dry-run-sandbox ]]; }

# ----------------------------------------------------------------------------
# Host driver
# ----------------------------------------------------------------------------

# Repo root = parent of scripts/lib/ (resolve via this file, not $SCRIPT_DIR,
# so it is correct whether sourced from ./mediastack or ./setup.sh).
_dry_run_repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); }

dry_run_require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "  --dry-run needs Docker (it runs the UI inside a throwaway container)." >&2
        echo "  Install Docker, or run the real ./mediastack / ./setup.sh." >&2
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "  --dry-run needs a running Docker daemon (cannot reach it)." >&2
        return 1
    fi
}

dry_run_ensure_image() {
    local root="$1"
    if docker image inspect "$DRY_RUN_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    echo "  First run: building the dry-run preview image (one-time, ~30s)..." >&2
    if ! docker build -q -t "$DRY_RUN_IMAGE" -f "$root/tests/Dockerfile.dry-run" "$root/tests" >&2; then
        echo "  Failed to build the dry-run image." >&2
        return 1
    fi
}

# dry_run_launch <entry-basename> [args...]
# <entry-basename> is "mediastack" or "setup.sh"; args are passed through (e.g.
# "--remote" for the wizard recovery surface). Runs entirely on the host.
dry_run_launch() {
    local entry="$1"; shift
    local root; root="$(_dry_run_repo_root)"

    dry_run_require_docker || return 1
    dry_run_ensure_image "$root" || return 1

    local cname="ms-dry-run-$$"
    docker rm -f "$cname" >/dev/null 2>&1 || true   # clear any same-name orphan
    # Non-privileged, no network, auto-removed. `sleep infinity` keeps it alive
    # for the exec below; the slim image has no custom entrypoint so this runs
    # directly (no dockerd). --user is baked into the image (mstest).
    if ! docker run -d --rm --network none --name "$cname" "$DRY_RUN_IMAGE" sleep infinity >/dev/null; then
        echo "  Failed to start the dry-run container." >&2
        return 1
    fi
    # Clean up even on Ctrl-C / error.
    # shellcheck disable=SC2064
    trap "docker rm -f '$cname' >/dev/null 2>&1 || true" EXIT INT TERM

    # COPY the repo in (never a read-write bind mount — that would leak writes to
    # the host). Same exclude set as tests/lib/dind.sh:dind_copy_repo.
    docker exec -u mstest "$cname" mkdir -p /home/mstest/MediaStack
    if ! tar --exclude=./.git \
            --exclude=./.env \
            --exclude=./.nvidia-patch \
            --exclude=./backups \
            --exclude=./tests/.dind-state \
            --exclude=./config/portainer \
            --exclude=./config/beszel \
            -cf - -C "$root" . \
        | docker exec -i -u mstest "$cname" tar -xf - -C /home/mstest/MediaStack; then
        echo "  Failed to copy the repo into the dry-run container." >&2
        return 1
    fi

    # Re-invoke the entry INSIDE the container with the recursion guard set, so
    # the in-container run takes the dry_run_begin path instead of spawning
    # another container. Allocate a TTY only when we actually have one (so a
    # piped/scripted host invocation does not error on `-it`).
    # Always -i so a piped/scripted host invocation forwards stdin to the inner
    # flow; add -t only when we actually have a terminal (interactive walk).
    local tflag=(-i)
    [[ -t 0 && -t 1 ]] && tflag=(-it)
    docker exec "${tflag[@]}" -u mstest \
        -e MS_DRYRUN_GPU \
        -e MS_DRYRUN_INSTALLED \
        -e MEDIASTACK_NONINTERACTIVE \
        -w /home/mstest/MediaStack \
        "$cname" "./$entry" --dry-run "$@"
    local rc=$?

    docker rm -f "$cname" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    return "$rc"
}

# ----------------------------------------------------------------------------
# In-container: simulated state + fidelity stubs
# ----------------------------------------------------------------------------

# Seed simulated on-disk state in the container copy so the real disk/var reads
# (is_installed, DOMAIN/banner, run_wizard self-skip guard, detect_existing_install)
# land on the chosen profile. Writes only inside the container — never the host.
_dry_run_seed_state() {
    [[ -f .env ]] || { [[ -f .env.example ]] && cp .env.example .env; }
    if [[ "${MS_DRYRUN_INSTALLED:-1}" == "1" ]]; then
        _dry_run_set_env STAGE_1_COMPLETE 1
        _dry_run_set_env JELLYFIN_GPU "${MS_DRYRUN_GPU:-nvidia}"
    else
        # Fresh: ensure the wizard self-skip guard cannot fire.
        _dry_run_set_env STAGE_1_COMPLETE ""
    fi
    mkdir -p config/ddns-updater 2>/dev/null || true
}

# Minimal .env key writer (sed in place; append if absent). Container copy only.
_dry_run_set_env() {
    local key="$1" val="$2"
    [[ -f .env ]] || : > .env
    if grep -qE "^${key}=" .env 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${val}#" .env
    else
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}

# scripts/configure.sh runs as a SUBPROCESS, so a shell function can't shadow it.
# Overwrite the on-disk copy with a no-op that seeds the API key the Stage-1
# Jellyfin probe needs to flip STAGE_1_COMPLETE (mirrors wizard-ui-stage1-local.sh).
_dry_run_overwrite_subprocess_scripts() {
    cat > scripts/configure.sh <<'CONFIGURE'
#!/usr/bin/env bash
# DRY-RUN stub of scripts/configure.sh — no API calls; seeds a fake key.
if [[ -f .env ]] && grep -qE '^JELLYFIN_API_KEY=' .env; then
    sed -i 's/^JELLYFIN_API_KEY=.*/JELLYFIN_API_KEY=dry-run-key/' .env
fi
echo "  DRY-RUN: would auto-configure services (Sonarr/Radarr/qBittorrent/...)" >&2
exit 0
CONFIGURE
    chmod +x scripts/configure.sh

    # The launcher dispatches these as SUBPROCESSES, so shell-function stubs do not
    # reach them — overwrite each with an announce-only no-op (otherwise e.g.
    # "Manage updates" runs the real update.sh and hits docker-not-found + real
    # retry sleeps). Container copy only.
    local s name
    for s in scripts/update.sh scripts/port-check.sh scripts/nvidia-repatch.sh; do
        [[ -e "$s" ]] || continue
        name="${s##*/}"
        printf '#!/usr/bin/env bash\necho "  DRY-RUN: would run %s" >&2\nexit 0\n' "$name" > "$s"
        chmod +x "$s"
    done
}

# Install the fidelity stubs as shell functions in THIS process. Side effects
# announce + return success; reads return deterministic values so the real flow
# advances and renders. Consolidated from tests/lib/wizard_stage{1,2,3}_common.sh
# and the day-2 launcher scenarios.
_dry_run_install_stubs() {
    # --- privilege / system side effects (announce, no-op) ---
    sudo()   { _dry_run_would "run as root: $*"; return 0; }
    reboot() { _dry_run_would "reboot the host"; return 0; }

    # --- container / install side effects (announce) ---
    pull_images()             { _dry_run_would "pull container images"; }
    start_stack()             { _dry_run_would "start the stack (docker compose up -d)"; }
    stop_existing_stack()     { _dry_run_would "stop any existing stack"; }
    wait_all_healthy()        { _dry_run_would "wait for services to become healthy"; }
    create_data_dirs()        { _dry_run_would "create data directories under ${DATA_DIR:-/data}"; }
    create_config_dirs()      { mkdir -p config/ddns-updater 2>/dev/null; _dry_run_would "create config directories"; }
    generate_override()       { printf 'services: {}\n' > docker-compose.override.yml 2>/dev/null; _dry_run_would "generate docker-compose.override.yml for GPU '${1:-none}'"; }
    storage_install_watchdog(){ _dry_run_would "install the storage watchdog service"; }
    setup_samba()             { _dry_run_would "configure the Samba host share"; }
    setup_ufw_service_ports() { _dry_run_would "configure the UFW firewall rules"; }
    install_base_packages()   { _dry_run_would "install base packages"; }
    install_docker()          { _dry_run_would "install Docker + Compose"; }
    storage_pause_watchdog_for_install() { return 0; }

    # --- external command stubs (network is --network none; return success) ---
    curl()  { return 0; }
    docker() { _dry_run_docker "$@"; }
    openssl() {
        if [[ "${1:-}" == "rand" ]]; then echo "DryRunGeneratedSecret123"; else return 0; fi
    }
    timedatectl() { echo "Etc/UTC"; }
    free() { printf 'Mem: 16Gi 1Gi 15Gi 0Gi 0Gi 15Gi\n'; }
    # >200G free so the <30GB "Continue anyway?" gate never fires.
    df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted on\n/dev/dryrun 500G 50G 450G 10%% /\n'; }
    findmnt() { return 1; }

    # --- network probes (fixed values) ---
    net_detect_public_ip() { _NET_PUBLIC_IP=203.0.113.10; return 0; }
    net_run_speedtest()    { _NET_DL_MBPS=120; _NET_UL_MBPS=40; return 0; }
    net_check_port_status() { _NET_PORT_STATUS["$1"]=closed; }
    net_is_port_locally_bound() { return 1; }
    validate_smb_port() { return 0; }

    # --- storage / NAS (succeed without touching mounts) ---
    storage_ensure_nfs_common() { return 0; }
    storage_mount_nfs() { return 0; }
    storage_preflight_nas() { return 0; }

    # --- GPU: drive the branch from the simulate-as profile, not real hardware ---
    stash_gpu_type() { GPU_TYPE="${MS_DRYRUN_GPU:-none}"; }

    # --- final access info: keep real (it's pure rendering) ---

    # --- day-2 launcher executors ---
    _docker_reachable()        { return 0; }
    _compose_running_summary() { printf '%s' "11/11"; }
    _update_status_scan()      { printf 'jellyfin\tstable\t-\tOn tested Stable\tno\n'; }
    _regenerate_override()     { _dry_run_would "regenerate docker-compose.override.yml"; return 0; }
    _recreate_service()        { _dry_run_would "recreate the '${1:-}' container"; return 0; }
    _apply_service_update()    { _dry_run_would "update the '${1:-}' container"; return 0; }
    _reset_service_to_default(){ _dry_run_would "reset '${1:-}' to its default image"; return 0; }
    _run_setup_return()        { shift 2 2>/dev/null || true; _dry_run_would "run: ./setup.sh $*"; return 0; }
}

# docker() stub: answer the few read-only queries the flow makes; announce the
# rest. Never reaches a daemon (the container has no docker + --network none).
_dry_run_docker() {
    case "${1:-}" in
        --version) echo "Docker version 27.0.0, build dryrun"; return 0 ;;
        compose)
            case " $* " in
                *" config --services "*)
                    printf '%s\n' jellyfin sonarr radarr jackett qbittorrent seerr homepage portainer unpackerr flaresolverr uptime-kuma
                    return 0 ;;
                *" config --images "*)
                    printf 'image%s\n' 1 2 3 4 5 6 7 8 9 10 11
                    return 0 ;;
                *" ps "*) return 0 ;;
                *) _dry_run_would "run: docker compose ${*:2}"; return 0 ;;
            esac ;;
        info) return 0 ;;
        *) _dry_run_would "run: docker $*"; return 0 ;;
    esac
}

# Entry point the in-container run calls before dispatching the real flow.
# $1 = surface ("wizard" | "launcher"): the wizard defaults to a FRESH host (so
# Stage 1 actually runs); the launcher defaults to an INSTALLED host (so the
# post-install menu shows). Either is overridable with MS_DRYRUN_INSTALLED.
dry_run_begin() {
    # Hard safety guard: never install no-op stubs or write seed files outside the
    # sandbox container. If this ever fires on a real host the launch gate has a
    # bug — refuse rather than risk writing to a real repo.
    if ! dry_run_in_sandbox; then
        echo "  dry-run: refusing to run outside the sandbox container (safety guard)." >&2
        exit 1
    fi
    local surface="${1:-launcher}"
    export MS_DRY_RUN=1
    if [[ "$surface" == "wizard" ]]; then : "${MS_DRYRUN_INSTALLED:=0}"; else : "${MS_DRYRUN_INSTALLED:=1}"; fi
    export MS_DRYRUN_INSTALLED
    # Constrain the GPU knob to the known set (also keeps it safe for the seed sed).
    case "${MS_DRYRUN_GPU:-none}" in nvidia|intel|amd|none) ;; *) MS_DRYRUN_GPU=none ;; esac
    export MS_DRYRUN_GPU
    ui_banner "DRY-RUN MODE" "Exploring the real UI — nothing will be changed"
    _dry_run_install_stubs
    _dry_run_overwrite_subprocess_scripts
    _dry_run_seed_state
    # Re-load the seeded .env so is_installed / DOMAIN / banner reflect the
    # simulated state — mediastack/setup.sh sourced .env (or found none) before
    # this point, so the seeded keys are not yet in the shell.
    if [[ -f .env ]]; then set -a; source .env; set +a; fi
}

# Dispatch the wizard / recovery surface (called by setup.sh in-container).
dry_run_dispatch_setup() {
    detect_env
    # shellcheck disable=SC2034  # consumed by the sourced run_wizard / run_stage3
    GPU_TYPE="${MS_DRYRUN_GPU:-none}"
    case "${1:-}" in
        --remote|--transcoding)
            # Recovery surfaces require a completed Stage 1 — seed it so the UI renders
            # (the wizard default is a FRESH host, which these would otherwise reject).
            _dry_run_set_env STAGE_1_COMPLETE 1
            set -a; source .env; set +a
            if [[ "$1" == "--remote" ]]; then run_remote_recovery; else run_transcoding_recovery; fi
            ;;
        *)             run_wizard ;;
    esac
}

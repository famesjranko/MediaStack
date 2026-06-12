# tests/lib/wizard_stub_common.sh — shared executor stubs for the DinD wizard PTY fixtures.
#
# Single home for the side-effect stubs the Stage 1/2/3 fixture builders
# (wizard_stage{1,2,3}_common.sh) install. Each fixture sources this file at RUN
# time inside the DinD container — AFTER `source ./setup.sh`, so these definitions
# shadow the real functions — then calls the ms_stub_* installers it needs and adds
# its own stage-specific stubs on top.
#
# Philosophy: the DinD fixtures run the REAL wizard inside a throwaway root
# container and let the cheap side effects actually happen (sudo runs the command,
# data dirs are really created), stubbing only the slow / networked / dangerous
# steps so the interactive flow advances and the generated state can be asserted.
#
# This is the deliberate OPPOSITE of scripts/lib/dry_run.sh:_dry_run_install_stubs,
# which ANNOUNCES every side effect ("would ...") for the no-op preview surface
# (non-root, no network, keeps print_access_info real). The two stub sets are
# intentionally parallel and cannot share bodies. When you add a new wizard
# side-effect function, stub it in BOTH this file and scripts/lib/dry_run.sh.

# Services / images the `docker compose config ...` stub reports. Stage 1 is the
# only stage that queries these today, but they are kept faithful and redefinable
# so a stage that needs a different set — e.g. Stage 2's remote-access services —
# can override the list without forking the docker() stub. Literal args, never a
# split variable, so no SC2086.
_stub_compose_service_list() {
    printf '%s\n' jellyfin sonarr radarr jackett qbittorrent seerr \
        homepage portainer unpackerr flaresolverr uptime-kuma
}
_stub_compose_image_list() {
    printf '%s\n' image1 image2 image3 image4 image5 image6 image7 image8 image9 image10 image11
}

# Core external-command stubs shared by every stage. Pass a non-empty api_key to
# make the configure.sh stub seed JELLYFIN_API_KEY (Stage 1 needs it to flip
# STAGE_1_COMPLETE); omit it for a plain no-op configure.sh (Stage 2 / Stage 3).
ms_stub_core() {
    local api_key="${1:-}"
    sudo() { "$@"; }
    curl() { return 0; }
    docker() {
        if [[ "${1:-}" == "--version" ]]; then
            echo "Docker version 27.0.1, build wizard"
            return 0
        fi
        if [[ "${1:-}" == "compose" ]]; then
            case " $* " in
                *" config --services "*) _stub_compose_service_list; return 0 ;;
                *" config --images "*)   _stub_compose_image_list;   return 0 ;;
            esac
            return 0
        fi
        return 0
    }
    openssl() {
        if [[ "${1:-}" == "rand" ]]; then
            echo GeneratedWizardPassword123
            return 0
        fi
        command openssl "$@"
    }
    if [[ -n "$api_key" ]]; then
        cat > scripts/configure.sh <<CONFIGURE
#!/usr/bin/env bash
sed -i 's/^JELLYFIN_API_KEY=.*/JELLYFIN_API_KEY=$api_key/' .env
exit 0
CONFIGURE
    else
        printf '#!/usr/bin/env bash\nexit 0\n' > scripts/configure.sh
    fi
    chmod +x scripts/configure.sh
}

# Clock / memory / public-IP probes shared by Stage 1 and Stage 2.
ms_stub_common_env() {
    timedatectl() { echo Etc/UTC; }
    free() { printf 'Mem: 16Gi 1Gi 15Gi 0Gi 0Gi 15Gi\n'; }
    net_detect_public_ip() { _NET_PUBLIC_IP=203.0.113.10; return 0; }
}

# Image-pull / stack-start / health-wait / access-info no-ops shared by Stage 1
# and Stage 2 (logged so the transcript shows the step was reached — no scenario
# asserts on this text).
ms_stub_service_lifecycle() {
    pull_images() { log_info "stub pull_images"; }
    start_stack() { log_info "stub start_stack"; }
    wait_all_healthy() { log_info "stub wait_all_healthy"; }
    print_access_info() { log_info "stub print_access_info"; }
}

# Stage-1 storage probes: report ample disk and succeed every NAS/SMB operation
# without touching real mounts. The df stub reports >200G free so validate_data_dir's
# <30GB "Continue anyway?" prompt never fires — otherwise these UI-flow scenarios are
# non-deterministic, hanging on runners with <30GB free on the data path.
ms_stub_stage1_storage() {
    df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted on\n/dev/ms-test 500G 50G 450G 10%% /\n'; }
    findmnt() { return 1; }
    net_run_speedtest() { _NET_DL_MBPS=120; _NET_UL_MBPS=40; return 0; }
    net_check_port_status() { _NET_PORT_STATUS["$1"]=closed; }
    net_is_port_locally_bound() { return 1; }
    validate_smb_port() { return 0; }
    storage_ensure_nfs_common() { return 0; }
    storage_mount_nfs() { return 0; }
    storage_preflight_nas() { return 0; }
}

# Stage-1 install no-ops: skip the heavy data-dir / stack steps, but keep the cheap,
# assertion-relevant work real — create_data_dirs really mkdirs $DATA_DIR, and
# create_config_dirs runs the managed-seed cleanup the wizard would.
ms_stub_stage1_install() {
    stop_existing_stack() { log_info "stub stop_existing_stack"; }
    create_data_dirs() { mkdir -p "${DATA_DIR:-/tmp/ms-wizard-data}"; log_info "stub create_data_dirs"; }
    create_config_dirs() {
        mkdir -p config/ddns-updater
        if declare -F clear_qbittorrent_managed_seed_for_manual_storage >/dev/null; then
            clear_qbittorrent_managed_seed_for_manual_storage
        fi
        log_info "stub create_config_dirs"
    }
    generate_override() { printf 'services: {}\n' > docker-compose.override.yml; log_info "stub generate_override $1"; }
    storage_install_watchdog() { log_info "stub storage_install_watchdog"; }
}

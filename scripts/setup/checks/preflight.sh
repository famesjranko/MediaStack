# Owns: hard-fail/warn pre-flight checks (root, OS, Docker, disk, RAM,
# internet reachability, sudo caching, GPU stash) run before the wizard.
# Sources: $SCRIPT_DIR and scripts/lib/common.sh, loaded by the caller
# (scripts/setup/checks.sh, sourced from setup.sh).

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
        if sudo docker info &>/dev/null 2>&1; then
            sudo usermod -aG docker "$USER"
            log_ok "Added $USER to the docker group."
            log_info "Open a new terminal and re-run: ./mediastack"
            exit 1
        fi
        if ! sudo systemctl is-active docker &>/dev/null; then
            log_warn "Docker daemon is not running — attempting to start it..."
            sudo systemctl start docker 2>/dev/null || true
            if docker info &>/dev/null 2>&1; then
                return 0
            fi
        fi
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
    # Reads DATA_DIR from .env if set, else defaults to /data.
    # Walks up to nearest existing parent so disk-floor check works on a fresh
    # host where /data doesn't yet exist.
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
    # Hard-fail when root <10 GB or data partition <30 GB.
    # On single-FS hosts (root and data on the same mountpoint), run one
    # check at the higher 30 GB floor.
    #
    # Empty `df` output (cgroup mounts, long device paths,
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

    # Hard-fail: empty df output on / is unrecoverable; we cannot
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
        # Single-FS host: one check at 30 GB floor.
        if ((root_free < 30)); then
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

    if ((root_free < 10)); then
        log_warn "Pre-flight: / has only ${root_free}GB free; recommended minimum is 10GB. Continuing anyway."
    fi
    if ((data_free < 30)); then
        log_warn "Pre-flight: ${data_path} has only ${data_free}GB free; recommended minimum is 30GB. Continuing anyway."
    fi

    # Soft warn when both above floor but combined ≤50 GB (Pattern B).
    local combined=$((root_free + data_free))
    if ((combined <= 50)); then
        log_warn "Disk: only ${combined}GB combined free across / and ${data_path}. Recommended: 50GB+."
    else
        log_ok "Disk: /=${root_free}GB free, ${data_path}=${data_free}GB free"
    fi
}

check_ram_warn() {
    # Tiered RAM warning. Never hard-fails — 4 GB SBCs are valid
    # targets. Two tiers:
    #   < 2 GB free: stack-wide warning (the original floor).
    #   < 4 GB free: flaresolverr/Chromium may flap (~1 GB working set).
    # Defensive guard for kernels without MemAvailable (kernel <3.14).
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
    if ((free_gb < 2)); then
        log_warn "Only ${ctx} - Bazarr/Seerr may struggle. Continuing."
    elif ((free_gb < 4)); then
        log_warn "Only ${ctx} - flaresolverr (Cloudflare bypass) needs ~1GB for Chromium and may flap on this host. If indexer tests stall, consider disabling the public indexer preset. Continuing."
    else
        log_ok "RAM: ${ctx}"
    fi
}

check_internet_reachability() {
    # Hard-fail when Docker Hub is unreachable. Let's Encrypt is
    # remote-access-only, so Stage 1 LAN setup warns but continues; Stage 2
    # performs the real certificate attempt and classifies failures.
    # 5s per attempt, up to 3 tries so one transient blip (a slow HEAD ->
    # curl 28) does not abort setup.
    # HEAD over GET (-I) — lighter and sufficient.
    #
    # Use `cmd || rc=$?` (single-statement capture) so a
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
    curl --max-time 5 --retry 2 --retry-connrefused --retry-all-errors -fsSI https://hub.docker.com >/dev/null 2>&1 || rc=$?
    if ((rc != 0)); then
        log_error "Pre-flight: Docker Hub unreachable (${rc}). Check your internet, retry."
        exit 1
    fi
    log_ok "Internet reachability: Docker Hub"

    rc=0
    curl --max-time 5 --retry 2 --retry-connrefused --retry-all-errors -fsSI https://acme-v02.api.letsencrypt.org/directory >/dev/null 2>&1 || rc=$?
    if ((rc != 0)); then
        log_warn "Pre-flight: Let's Encrypt unreachable (${rc}). LAN setup can continue; Stage 2 remote access will verify certificates when selected."
        return 0
    fi

    log_ok "Internet reachability: Let's Encrypt"
}

prompt_sudo_cache() {
    # Pre-cache sudo creds so downstream sudo calls don't re-prompt
    # mid-wizard. 15-minute cache is the sudoers default. Distinct
    # error for "sudo not installed" vs "no sudo access".
    if ! command -v sudo &>/dev/null; then
        log_error "Pre-flight: sudo not installed. Install it: apt-get install sudo"
        exit 1
    fi

    # Passwordless sudo (NOPASSWD or valid cached timestamp).
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
    # Invoke the existing detect_gpu (gpu/detection.sh), which
    # already populates GPU_TYPE in {nvidia, amd, intel, none} and gracefully
    # handles `lspci` absence. Hardware transcoding consumes the
    # global GPU_TYPE downstream.
    detect_gpu
    log_info "GPU type: ${GPU_TYPE}"
}

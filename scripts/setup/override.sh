# =============================================================================
# MediaStack Setup — Host memory detection and compose override generation
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# Globals set: HOST_MEMORY_MB (integer).

detect_host_memory() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [[ -z "$mem_kb" || "$mem_kb" -eq 0 ]] 2>/dev/null; then
        mem_kb=$(free -k 2>/dev/null | awk '/^Mem:/ {print $2}')
    fi
    if [[ -z "$mem_kb" || "$mem_kb" -eq 0 ]] 2>/dev/null; then
        log_warn "Could not detect host memory - defaulting to 4GB for resource limits"
        mem_kb=4194304
    fi
    HOST_MEMORY_MB=$((mem_kb / 1024))
    log_ok "Host memory: ${HOST_MEMORY_MB}MB ($((HOST_MEMORY_MB / 1024))GB)"
}

# compute_mem_limit <percentage> <floor_mb> <cap_mb>
# Reads HOST_MEMORY_MB. Echoes clamped value with 'm' suffix.
compute_mem_limit() {
    local pct="$1" floor="$2" cap="$3"
    local raw=$((HOST_MEMORY_MB * pct / 100))
    ((raw < floor)) && raw=$floor
    ((raw > cap)) && raw=$cap
    echo "${raw}m"
}

_compose_image_services() {
    printf '%s\n' \
        jellyfin sonarr radarr jackett qbittorrent flaresolverr seerr \
        unpackerr bazarr homepage portainer npm fail2ban wireguard \
        ddns-updater uptime-kuma beszel beszel-agent autoheal
}

_image_channel() {
    local channel="${IMAGE_CHANNEL:-stable}"
    channel="${channel,,}"
    case "$channel" in
        stable | latest)
            printf '%s\n' "$channel"
            ;;
        *)
            log_error "Invalid IMAGE_CHANNEL '${IMAGE_CHANNEL}'. Use 'stable' or 'latest'."
            return 1
            ;;
    esac
}

# --- Per-service image policy ----------------------------------------------
# Lets a user float one service from its tested stable digest to its compose
# tag (and back) without flipping the global IMAGE_CHANNEL. Managed by the
# "Manage updates" launcher menu and recorded in a gitignored state file.
# Absent row = follow the global channel. The lock file (docs/operations/image-digests.lock)
# is NEVER edited by this path — it stays the maintainer-tested record; user
# intent lives here. Policy 'latest' means "follow the compose tag", which keeps
# the compose tag pins (npm:2, wireguard:15) intact — it only drops the digest.
_image_policy_file() {
    printf '%s\n' "$SCRIPT_DIR/config/state/image-policy.tsv"
}

# Echo 'stable' or 'latest' for a service with a valid per-service policy row;
# echo nothing otherwise. TSV: <service>\t<policy> where policy is
# stable|latest|<image>@sha256:<digest>. This reader answers "what channel" and
# is deliberately blind to a digest pin (that is _service_pin's job).
_service_policy() {
    local service="$1" file
    file="$(_image_policy_file)"
    [[ -f "$file" ]] || return 0
    awk -F '\t' -v service="$service" '
        $1 == service && ($2 == "stable" || $2 == "latest") {
            print $2; found = 1; exit
        }
        END { if (!found) exit 1 }
    ' "$file" 2>/dev/null || return 0
}

# Echo the per-service digest pin (<image>@sha256:...) if one is set, else
# nothing. A pin is orthogonal to the channel: "Revert to installed image"
# re-pins a service to its recorded install digest on any channel.
_service_pin() {
    local service="$1" file
    file="$(_image_policy_file)"
    [[ -f "$file" ]] || return 0
    awk -F '\t' -v service="$service" '
        $1 == service && $2 ~ /@sha256:/ {
            print $2; found = 1; exit
        }
        END { if (!found) exit 1 }
    ' "$file" 2>/dev/null || return 0
}

# Effective channel for a service = per-service policy if set, else global.
_effective_channel() {
    local service="$1" policy
    policy="$(_service_policy "$service")"
    if [[ "$policy" == "stable" || "$policy" == "latest" ]]; then
        printf '%s\n' "$policy"
        return 0
    fi
    _image_channel
}

# Cosmetic header summary of active per-service overrides ("svc=latest ...").
_policy_overrides_note() {
    local file svc pol out=""
    file="$(_image_policy_file)"
    [[ -f "$file" ]] || {
        printf 'none\n'
        return 0
    }
    while IFS=$'\t' read -r svc pol; do
        [[ -z "$svc" || "$svc" == \#* ]] && continue
        if [[ "$pol" == "stable" || "$pol" == "latest" ]]; then
            out+="${svc}=${pol} "
        elif [[ "$pol" == *@sha256:* ]]; then
            out+="${svc}=pinned "
        fi
    done <"$file"
    if [[ -n "$out" ]]; then printf '%s\n' "${out% }"; else printf 'none\n'; fi
}

_stable_image_ref() {
    local service="$1"
    local lock_file="$SCRIPT_DIR/docs/operations/image-digests.lock"
    local row image digest

    if [[ ! -f "$lock_file" ]]; then
        log_error "Stable image channel requires docs/operations/image-digests.lock."
        return 1
    fi

    row=$(awk -F '\t' -v service="$service" '
        NR > 1 && $1 == service {
            print $2 "\t" $3
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$lock_file") || {
        log_error "Stable image lock is missing a row for service '${service}'."
        return 1
    }

    image="${row%%$'\t'*}"
    digest="${row#*$'\t'}"
    if [[ ! "$image" =~ ^[^[:space:]]+:[^[:space:]]+$ ]]; then
        log_error "Stable image lock row for '${service}' has invalid image ref '${image}'."
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        log_error "Stable image lock row for '${service}' has invalid digest '${digest}'."
        return 1
    fi

    printf '%s@%s\n' "$image" "$digest"
}

_validate_stable_image_lock() {
    local service
    while IFS= read -r service; do
        [[ "$(_effective_channel "$service")" == "stable" ]] || continue
        _stable_image_ref "$service" >/dev/null || return 1
    done < <(_compose_image_services)
}

_compose_image_line() {
    local service="$1"
    local pin channel
    # Precedence: an explicit digest pin wins over channel, so a reverted
    # service holds its installed image on any channel.
    pin="$(_service_pin "$service")"
    if [[ -n "$pin" ]]; then
        printf '    image: %s\n' "$pin"
        return 0
    fi
    channel="$(_effective_channel "$service")" || return 1
    if [[ "$channel" != "stable" ]]; then
        return 0
    fi
    printf '    image: %s\n' "$(_stable_image_ref "$service")"
}

generate_override() {
    local gpu_type="${1:-none}"
    local override_file="$SCRIPT_DIR/docker-compose.override.yml"
    local image_channel
    image_channel="$(_image_channel)" || return 1
    # Validate the lock for every service whose *effective* channel is stable
    # (global or per-service override) — a no-op when nothing is pinned.
    _validate_stable_image_lock || return 1
    local overrides_note
    overrides_note="$(_policy_overrides_note)"

    # --- Compute memory limits (proportional to host RAM) ---
    # Declared separately from assignment so compute_mem_limit's exit status is
    # not masked by `local` (SC2155).
    local jf_mem sonarr_mem radarr_mem jackett_mem qbt_mem flare_mem seerr_mem \
        npm_mem unpackerr_mem bazarr_mem homepage_mem portainer_mem f2b_mem \
        wg_mem ddns_mem kuma_mem beszel_mem beszel_agent_mem autoheal_mem
    jf_mem=$(compute_mem_limit 40 1024 8192)
    sonarr_mem=$(compute_mem_limit 12 256 4096)
    radarr_mem=$(compute_mem_limit 12 256 4096)
    jackett_mem=$(compute_mem_limit 10 256 2048)
    qbt_mem=$(compute_mem_limit 12 256 4096)
    flare_mem=$(compute_mem_limit 15 1024 2048)
    seerr_mem=$(compute_mem_limit 10 256 2048)
    npm_mem=$(compute_mem_limit 10 256 2048)
    unpackerr_mem=$(compute_mem_limit 5 128 1024)
    bazarr_mem=$(compute_mem_limit 5 128 1024)
    homepage_mem=$(compute_mem_limit 5 192 512)
    portainer_mem=$(compute_mem_limit 3 64 512)
    f2b_mem=$(compute_mem_limit 3 64 512)
    wg_mem=$(compute_mem_limit 3 64 512)
    ddns_mem=$(compute_mem_limit 2 64 256)
    kuma_mem=$(compute_mem_limit 5 192 1024)
    beszel_mem=$(compute_mem_limit 3 64 512)
    beszel_agent_mem=$(compute_mem_limit 2 64 256)
    autoheal_mem=$(compute_mem_limit 1 32 128)

    # memswap_limit = 1.5x mem_limit (existing convention: 1g/1536m, 512m/768m)
    _swap() {
        local v="${1%m}"
        echo "$((v * 3 / 2))m"
    }
    _restart_line() {
        case "${STORAGE_MODE:-local}:$1" in
            nas:jellyfin | nas:qbittorrent | nas:sonarr | nas:radarr | nas:seerr | nas:unpackerr | nas:bazarr)
                echo '    restart: "no"'
                ;;
        esac
    }

    # --- Build override: selected image channel + resource limits + GPU config ---
    cat >"$override_file" <<YAML
# Auto-generated by setup.sh — image channel + resource limits + GPU config
# Host memory: ${HOST_MEMORY_MB}MB — regenerated on every setup.sh run
# Image channel: ${image_channel}
# Per-service overrides: ${overrides_note}
services:
  jellyfin:
$(_compose_image_line jellyfin)
    mem_limit: ${jf_mem}
    memswap_limit: $(_swap "$jf_mem")
$(_restart_line jellyfin)
YAML

    case "$gpu_type" in
        nvidia)
            cat >>"$override_file" <<'YAML'
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8096/health >/dev/null 2>&1 && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
YAML
            ;;
        amd | intel)
            local render_gid render_device
            render_device="${STAGE_3_GPU_RENDER_DEVICE:-}"
            if [[ -z "$render_device" ]] && type gpu_render_device_for_vendor >/dev/null 2>&1; then
                render_device="$(gpu_render_device_for_vendor "$gpu_type" || true)"
            fi
            if [[ -z "$render_device" ]]; then
                for render_device in /dev/dri/renderD*; do
                    [[ -e "$render_device" ]] && break
                done
            fi
            render_gid=$(stat -c '%g' "$render_device" 2>/dev/null || true)
            if [[ -z "$render_gid" ]]; then
                render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
            fi
            cat >>"$override_file" <<YAML
    devices:
      - /dev/dri:/dev/dri
YAML
            if [[ -n "$render_gid" ]]; then
                cat >>"$override_file" <<YAML
    group_add:
      - "${render_gid}"
YAML
            else
                log_warn "Could not detect /dev/dri render group; Jellyfin may need manual device permissions for hardware transcoding"
            fi
            ;;
    esac

    cat >>"$override_file" <<YAML
  sonarr:
$(_compose_image_line sonarr)
    mem_limit: ${sonarr_mem}
    memswap_limit: $(_swap "$sonarr_mem")
$(_restart_line sonarr)
  radarr:
$(_compose_image_line radarr)
    mem_limit: ${radarr_mem}
    memswap_limit: $(_swap "$radarr_mem")
$(_restart_line radarr)
  jackett:
$(_compose_image_line jackett)
    mem_limit: ${jackett_mem}
    memswap_limit: $(_swap "$jackett_mem")
  qbittorrent:
$(_compose_image_line qbittorrent)
    mem_limit: ${qbt_mem}
    memswap_limit: $(_swap "$qbt_mem")
$(_restart_line qbittorrent)
  flaresolverr:
$(_compose_image_line flaresolverr)
    mem_limit: ${flare_mem}
    memswap_limit: $(_swap "$flare_mem")
    cpus: 1.0
  seerr:
$(_compose_image_line seerr)
    mem_limit: ${seerr_mem}
    memswap_limit: $(_swap "$seerr_mem")
$(_restart_line seerr)
  npm:
$(_compose_image_line npm)
    mem_limit: ${npm_mem}
    memswap_limit: $(_swap "$npm_mem")
  unpackerr:
$(_compose_image_line unpackerr)
    mem_limit: ${unpackerr_mem}
    memswap_limit: $(_swap "$unpackerr_mem")
$(_restart_line unpackerr)
  bazarr:
$(_compose_image_line bazarr)
    mem_limit: ${bazarr_mem}
    memswap_limit: $(_swap "$bazarr_mem")
$(_restart_line bazarr)
  homepage:
$(_compose_image_line homepage)
    mem_limit: ${homepage_mem}
    memswap_limit: $(_swap "$homepage_mem")
  portainer:
$(_compose_image_line portainer)
    mem_limit: ${portainer_mem}
    memswap_limit: $(_swap "$portainer_mem")
  fail2ban:
$(_compose_image_line fail2ban)
    mem_limit: ${f2b_mem}
    memswap_limit: $(_swap "$f2b_mem")
  wireguard:
$(_compose_image_line wireguard)
    mem_limit: ${wg_mem}
    memswap_limit: $(_swap "$wg_mem")
  ddns-updater:
$(_compose_image_line ddns-updater)
    mem_limit: ${ddns_mem}
    memswap_limit: $(_swap "$ddns_mem")
  uptime-kuma:
$(_compose_image_line uptime-kuma)
    mem_limit: ${kuma_mem}
    memswap_limit: $(_swap "$kuma_mem")
  beszel:
$(_compose_image_line beszel)
    mem_limit: ${beszel_mem}
    memswap_limit: $(_swap "$beszel_mem")
  autoheal:
$(_compose_image_line autoheal)
    mem_limit: ${autoheal_mem}
    memswap_limit: $(_swap "$autoheal_mem")
  beszel-agent:
$(_compose_image_line beszel-agent)
    mem_limit: ${beszel_agent_mem}
    memswap_limit: $(_swap "$beszel_agent_mem")
YAML

    # --- S.M.A.R.T. disk monitoring for beszel-agent ---
    local smart_disks=()
    for dev in /dev/sd? /dev/nvme?; do
        [[ -b "$dev" ]] && smart_disks+=("$dev")
    done
    if ((${#smart_disks[@]} > 0)); then
        cat >>"$override_file" <<'YAML'
    cap_add:
      - SYS_RAWIO
      - SYS_ADMIN
    devices:
YAML
        for dev in "${smart_disks[@]}"; do
            echo "      - ${dev}:${dev}" >>"$override_file"
        done
    fi

    # Power-user escape hatch: strip all resource caps. GPU runtime/devices
    # and SMART caps remain (those are hardware passthrough, not limits).
    # Use only when you've measured your stack and want Docker's defaults.
    if [[ "${MS_DISABLE_RESOURCE_LIMITS:-false}" == "true" ]]; then
        sed -i '/^[[:space:]]*\(mem_limit\|memswap_limit\):/d' "$override_file"
        sed -i '/^[[:space:]]*cpus:[[:space:]]*[0-9]/d' "$override_file"
        log_warn "MS_DISABLE_RESOURCE_LIMITS=true - mem_limit/memswap_limit/cpus stripped from override"
        log_ok "Generated docker-compose.override.yml (${HOST_MEMORY_MB}MB host - GPU: ${gpu_type}, image channel: ${image_channel}, limits disabled)"
        return
    fi

    log_ok "Generated docker-compose.override.yml (${HOST_MEMORY_MB}MB host - GPU: ${gpu_type}, image channel: ${image_channel})"
}

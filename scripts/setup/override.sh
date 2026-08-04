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

# shellcheck source=gpu/compose.sh
source "$SCRIPT_DIR/scripts/setup/gpu/compose.sh"

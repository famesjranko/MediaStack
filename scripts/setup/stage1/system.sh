# Owns: Stage 1 detected-system screen and timezone choice.
# Sources: wizard UI helpers, `_ENV_*`/`_NET_*`/`GPU_TYPE` detection globals, and Stage 1 state.

_stage1_show_system() {
    local hostname_value os_value docker_value ram_value root_free data_path data_free gateway_value
    hostname_value=$(hostname)
    # LAN gateway = the router the user logs into for port forwarding. The `via`
    # address of the default route ($3) — reliable on any host with a default
    # route; empty (shown as "unknown") only if there's no route configured.
    # `|| true`: under `set -euo pipefail` a missing/erroring `ip` would make this
    # standalone assignment abort the whole wizard. Empty gateway is fine (shows
    # "unknown").
    gateway_value=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)
    os_value=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || echo "unknown")
    docker_value=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    # Report total RAM in GB (one decimal) so it matches the preflight RAM check
    # and the free-RAM warning, which both use GB — never `free -h`'s mixed Gi/Mi.
    ram_value=$(awk '/^MemTotal:/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    root_free=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}')
    data_path=$(_resolve_data_partition)
    data_free=$(df -BG "$data_path" 2>/dev/null | awk 'NR==2 {print $4}')

    ui_box "Detected your system" \
        "$(ui_kv 'Hostname' "$hostname_value")" \
        "$(ui_kv 'LAN IP' "${_ENV_HOST_ADDRESS:-unknown}")" \
        "$(ui_kv 'Router (gateway)' "${gateway_value:-unknown}")" \
        "$(ui_kv 'Public IP' "${_NET_PUBLIC_IP:-not detected - fine for LAN-only}")" \
        "$(ui_kv 'OS' "$os_value")" \
        "$(ui_kv 'Docker version' "${docker_value:-unknown}")" \
        "$(ui_kv 'RAM total' "${ram_value:-unknown}")" \
        "$(ui_kv 'GPU' "$(gpu_brand_label "${GPU_TYPE:-none}")")" \
        "$(ui_kv 'Timezone' "${_ENV_TZ:-Etc/UTC}")" \
        "$(ui_kv 'Disk free' "/=${root_free:-unknown} | ${data_path}=${data_free:-unknown}")"

    local tz_default action
    tz_default="${_WIZ_TZ:-${_WIZ_PREV_TZ:-${_ENV_TZ:-Etc/UTC}}}"
    action=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Continue with these detected values?" \
        "Continue" \
        "Override timezone" \
        "Abort")

    case "$action" in
        "Override timezone")
            _WIZ_TZ=$(ui_input_validated "Timezone" "$tz_default" validate_timezone)
            ;;
        "Abort")
            log_info "Setup aborted - choose Install MediaStack from the menu to try again"
            exit 0
            ;;
        *)
            _WIZ_TZ="$tz_default"
            ;;
    esac
}

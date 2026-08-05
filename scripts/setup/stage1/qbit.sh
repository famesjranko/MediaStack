# Owns: stage1_* — Stage 1 qBittorrent limit and peer-port collection.
# Sources: wizard UI, validator, network, and discovery helpers.

_stage1_mbps_to_mbs() {
    # Pass numeric inputs through the environment so python3 parses them with
    # float() rather than executing them as Python source. This keeps
    # speedtest-fed values (which travel through speedtest-cli's JSON output
    # and a Python parser) from ever reaching the eval surface, even if a
    # future speedtest-cli version returns a non-numeric token. Same shape
    # as net_ip_in_cloudflare_v4 in network.sh.
    MBPS="$1" RATIO="$2" python3 -c '
import os
mbps = float(os.environ["MBPS"])
ratio = float(os.environ["RATIO"])
value = (mbps * ratio) / 8
text = f"{value:.1f}"
print(text.rstrip("0").rstrip("."))
'
}

# Read a qBittorrent MB/s speed limit, re-prompting until valid. Delegates to the
# shared ui_input_validated + validate_mb_per_sec so the install prompt and the
# day-2 "Adjust bandwidth limits" launcher action use one input path (same
# grammar, same "MB/s" copy — no drift). The default must be numeric (callers
# pass a suggested/previous value or 0) so a non-TTY EOF returns it without
# looping.
_stage1_read_limit() {
    ui_input_validated "$1" "$2" validate_mb_per_sec
}

_stage1_collect_qbit() {
    while true; do
        _stage1_collect_qbit_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these qBittorrent settings?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_qbit_once() {
    ui_section 8 10 "qBittorrent limits + peer port"

    local dl_default ul_default suggested_dl suggested_ul
    suggested_dl="${_WIZ_DL_LIMIT:-${_WIZ_PREV_DL:-0}}"
    suggested_ul="${_WIZ_UL_LIMIT:-${_WIZ_PREV_UL:-0}}"

    if [[ "${_discovery_speed_ok:-false}" == "true" && -n "${_NET_DL_MBPS:-}" && -n "${_NET_UL_MBPS:-}" ]]; then
        suggested_dl=$(_stage1_mbps_to_mbs "$_NET_DL_MBPS" "0.50")
        suggested_ul=$(_stage1_mbps_to_mbs "$_NET_UL_MBPS" "0.25")
        ui_log info "Detected ${_NET_DL_MBPS} Mbps down / ${_NET_UL_MBPS} Mbps up."
        ui_log info "Suggested qBittorrent download limit: ${suggested_dl} MB/s (50% of download)."
        ui_log info "Suggested qBittorrent upload limit: ${suggested_ul} MB/s (25% of upload)."
    fi

    dl_default="${_WIZ_DL_LIMIT:-${_WIZ_PREV_DL:-$suggested_dl}}"
    ul_default="${_WIZ_UL_LIMIT:-${_WIZ_PREV_UL:-$suggested_ul}}"

    _WIZ_DL_LIMIT=$(_stage1_read_limit "qBittorrent download limit MB/s (0 = unlimited)" "${dl_default:-0}")
    _WIZ_UL_LIMIT=$(_stage1_read_limit "qBittorrent upload limit MB/s (0 = unlimited)" "${ul_default:-0}")
    local _dl_disp="${_WIZ_DL_LIMIT:-0}" _ul_disp="${_WIZ_UL_LIMIT:-0}"
    [[ "$_dl_disp" == "0" ]] && _dl_disp="unlimited" || _dl_disp="${_dl_disp} MB/s"
    [[ "$_ul_disp" == "0" ]] && _ul_disp="unlimited" || _ul_disp="${_ul_disp} MB/s"
    ui_kv "Download limit" "$_dl_disp"
    ui_kv "Upload limit" "$_ul_disp"

    _WIZ_TORRENT_PORT=$(ui_input_validated \
        "qBittorrent peer port" \
        "${_WIZ_TORRENT_PORT:-${_WIZ_PREV_TORRENT_PORT:-6881}}" \
        validate_torrent_port)
    ui_kv "Peer port" "${_WIZ_TORRENT_PORT:-6881}"

    # qBittorrent isn't running yet (we haven't even reached the install
    # plan) — so this is a true local-availability check ("is the port free
    # for qBittorrent to bind?"), not a forwarding check. ss-based bind
    # detection is reliable regardless of hairpin NAT / public IP detection.
    if net_is_port_locally_bound "$_WIZ_TORRENT_PORT"; then
        ui_log warn "Port ${_WIZ_TORRENT_PORT} is already in use by another process - qBittorrent will fail to bind. Pick a different port or free this one."
    else
        ui_log info "Port ${_WIZ_TORRENT_PORT}: available - public reachability will be verified after qBittorrent starts in Stage 1."
    fi
}

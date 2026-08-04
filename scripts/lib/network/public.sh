# Owns: Public-IP detection and speed-test helpers.
# Sources: scripts/lib/network.sh state plus curl, python3, and optional librespeed-cli.
net_detect_public_ip() {
    _NET_PUBLIC_IP=""
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        _NET_PUBLIC_IP="203.0.113.42"
        return 0
    fi
    _NET_PUBLIC_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null) \
        && [[ -n "$_NET_PUBLIC_IP" ]] && return 0
    _NET_PUBLIC_IP=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null) \
        && [[ -n "$_NET_PUBLIC_IP" ]] && return 0
    _NET_PUBLIC_IP=""
    return 1
}

# -----------------------------------------------------------------------------
# _speedtest_set_mbps — validate two candidate integers and set the globals.
# Args: <dl> <ul>. Returns 0 and sets _NET_DL_MBPS/_NET_UL_MBPS only when both
# are strict positive integer literals (defense in depth: downstream consumers
# like _stage1_mbps_to_mbs must never see notation like '1.2e8' or an error
# string flow into shell/python contexts).
# -----------------------------------------------------------------------------
_speedtest_set_mbps() {
    local dl="$1" ul="$2"
    [[ "$dl" =~ ^[0-9]+$ && "$ul" =~ ^[0-9]+$ ]] || return 1
    ((dl > 0 && ul > 0)) || return 1
    _NET_DL_MBPS="$dl"
    _NET_UL_MBPS="$ul"
    return 0
}

# -----------------------------------------------------------------------------
# _speedtest_via_curl — primary method, no extra dependency.
# Measures download/upload throughput with curl against Cloudflare's public
# speed endpoints and converts bytes/sec to integer Mbps. Values reach python
# via os.environ (never interpolated into -c) to keep them off the eval surface.
# -----------------------------------------------------------------------------
_speedtest_via_curl() {
    local dl_bps ul_bps out
    # A link too slow to move the fixed payload within --max-time exits 28
    # (timeout) but curl STILL prints the sustained %{speed_*} rate — a valid
    # measurement. `|| true` keeps that captured value instead of discarding it
    # (the old `|| return 1` failed every sub-~7 Mbps link); a hard failure
    # (exit 6/22) prints 0, which the _speedtest_set_mbps `> 0` gate below
    # rejects. `|| true` (not bare removal) keeps the assignment set -e-safe.
    dl_bps=$(curl -fsS --max-time 30 -o /dev/null -w '%{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null) || true
    ul_bps=$(head -c 10000000 /dev/zero \
        | curl -fsS --max-time 30 -o /dev/null -w '%{speed_upload}' \
            --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null) || true
    out=$(DL="$dl_bps" UL="$ul_bps" python3 -c '
import os, sys
try:
    print(int(float(os.environ["DL"]) * 8 / 1_000_000))
    print(int(float(os.environ["UL"]) * 8 / 1_000_000))
except (ValueError, KeyError):
    sys.exit(1)' 2>/dev/null) || return 1
    _speedtest_set_mbps "$(echo "$out" | head -1)" "$(echo "$out" | tail -1)"
}

# -----------------------------------------------------------------------------
# _speedtest_via_librespeed — fallback tool (Debian: apt install librespeed-cli).
# `librespeed-cli --json` emits a JSON array of result records with download/
# upload already in Mbps. Parsed via os.environ, not string interpolation.
# -----------------------------------------------------------------------------
_speedtest_via_librespeed() {
    command -v librespeed-cli &>/dev/null || return 1
    local json out
    json=$(timeout 90 librespeed-cli --json 2>/dev/null) || return 1
    [[ -n "$json" ]] || return 1
    out=$(OUT="$json" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["OUT"])
    rec = d[0] if isinstance(d, list) else d
    print(int(rec["download"]))
    print(int(rec["upload"]))
except (ValueError, KeyError, IndexError, TypeError):
    sys.exit(1)' 2>/dev/null) || return 1
    _speedtest_set_mbps "$(echo "$out" | head -1)" "$(echo "$out" | tail -1)"
}

# -----------------------------------------------------------------------------
# net_run_speedtest — measure download and upload bandwidth.
# Sets _NET_DL_MBPS and _NET_UL_MBPS (integers, Mbps). Returns 0/1.
# Method chain: curl+Cloudflare (primary, no extra dep) -> librespeed-cli
# (fallback tool). Optional: informs qBittorrent limit hints, so it degrades
# gracefully when every method fails. Caller should wrap with ui_spin.
# -----------------------------------------------------------------------------
net_run_speedtest() {
    _NET_DL_MBPS=""
    _NET_UL_MBPS=""
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        _NET_DL_MBPS=120
        _NET_UL_MBPS=40
        return 0
    fi
    _speedtest_via_curl && return 0
    _speedtest_via_librespeed && return 0
    _NET_DL_MBPS=""
    _NET_UL_MBPS=""
    return 1
}

# -----------------------------------------------------------------------------
# net_is_port_locally_bound <port>
# True (return 0) if anything is currently listening on the local TCP port
# (any interface, IPv4 or IPv6). False (return 1) if the port is free.
#
# Uses `ss -tln` — the canonical local bind check on Linux. Unlike
# `nc -z $PUBLIC_IP $port`, this does NOT depend on hairpin NAT or external
# routing; it gives a definitive answer about local kernel state. Use this
# for "is the port available for our service to bind?" checks (Stage 1
# pre-install diagnostics, port-conflict warnings).
# -----------------------------------------------------------------------------

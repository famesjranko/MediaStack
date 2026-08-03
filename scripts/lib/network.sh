# =============================================================================
# MediaStack — shared network utilities
# =============================================================================
# Reusable functions for public IP detection, speed testing, and TCP port
# probing. Sourced by both wizard.sh (discovery phase) and port-check.sh.
#
# Depends on: curl (required), nc (netcat), python3, librespeed-cli (optional fallback).
# The speed test measures throughput with curl against Cloudflare's speed
# endpoints, falling back to librespeed-cli if present. (The old Ookla
# speedtest-cli was dropped: Ookla now HTTP-403s that deprecated client.)
# UI_DEMO=1 mode returns fake data so the wizard demo works offline.

_NET_PUBLIC_IP=""
_NET_DL_MBPS=""
_NET_UL_MBPS=""
declare -A _NET_PORT_STATUS 2>/dev/null || true
_STAGE2_CLOUDFLARE_IPS_V4=""

: "${DDNS_VERIFY_PULL_TIMEOUT_SECONDS:=120}"
: "${DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS:=20}"
: "${DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS:=1}"
: "${DDNS_VERIFY_UPDATE_POLL_ATTEMPTS:=8}"
: "${DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS:=20}"
: "${DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS:=1}"
readonly DDNS_VERIFY_PULL_TIMEOUT_SECONDS
readonly DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS
readonly DDNS_VERIFY_UPDATE_POLL_ATTEMPTS DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS
readonly DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS

# -----------------------------------------------------------------------------
# net_detect_public_ip — detect external IPv4 address
# Sets _NET_PUBLIC_IP. Returns 0 if detected, 1 if not.
# -----------------------------------------------------------------------------
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
net_is_port_locally_bound() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        return 1
    fi
    local hits
    hits=$(ss -tln "sport = :$port" 2>/dev/null | tail -n +2)
    [[ -n "$hits" ]]
}

# -----------------------------------------------------------------------------
# net_check_http <url> — check if an HTTP(S) endpoint responds
# Any HTTP status code (even 4xx/5xx) = port is forwarded. Returns 0/1.
# -----------------------------------------------------------------------------
net_check_http() {
    local url="$1"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then return 0; fi
    local code
    code=$(curl -sko /dev/null --connect-timeout 5 -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    [[ "$code" != "000" ]]
}

# -----------------------------------------------------------------------------
# net_check_port_status <port> <protocol>
# protocol: "tcp" | "udp"
# Stores result in _NET_PORT_STATUS[$port]: "open" | "closed" | "udp-unverifiable"
# -----------------------------------------------------------------------------
net_check_port_status() {
    local port="$1" proto="$2"
    case "$proto" in
        tcp)
            # "open" here means "something is bound locally" (a CONFLICT for
            # services about to be installed). "closed" means "free for our
            # service to bind." This is a local-availability check, not a
            # forwarding check — pre-install nothing is listening yet so
            # forwarding state is irrelevant.
            if net_is_port_locally_bound "$port"; then
                _NET_PORT_STATUS[$port]="open"
            else
                _NET_PORT_STATUS[$port]="closed"
            fi
            ;;
        udp)
            _NET_PORT_STATUS[$port]="udp-unverifiable"
            ;;
    esac
}

stage2_fetch_cloudflare_ips_v4() {
    if [[ -n "${STAGE2_CLOUDFLARE_IPS_TEXT:-}" ]]; then
        printf '%s\n' "$STAGE2_CLOUDFLARE_IPS_TEXT"
        return 0
    fi
    if [[ -n "${STAGE2_CLOUDFLARE_IPS_FILE:-}" && -f "$STAGE2_CLOUDFLARE_IPS_FILE" ]]; then
        cat "$STAGE2_CLOUDFLARE_IPS_FILE"
        return 0
    fi
    if [[ -n "$_STAGE2_CLOUDFLARE_IPS_V4" ]]; then
        printf '%s\n' "$_STAGE2_CLOUDFLARE_IPS_V4"
        return 0
    fi

    _STAGE2_CLOUDFLARE_IPS_V4=$(curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null) || {
        _STAGE2_CLOUDFLARE_IPS_V4=""
        return 1
    }
    printf '%s\n' "$_STAGE2_CLOUDFLARE_IPS_V4"
}

stage2_ip_in_cloudflare_v4() {
    local ip="$1"
    local cidrs="${2:-}"
    if [[ -z "$cidrs" ]]; then
        cidrs=$(stage2_fetch_cloudflare_ips_v4) || return 1
    fi

    IP="$ip" CIDRS="$cidrs" python3 -c '
import ipaddress
import os
import sys

try:
    ip = ipaddress.ip_address(os.environ["IP"])
except ValueError:
    sys.exit(1)

for raw in os.environ["CIDRS"].split():
    try:
        if ip in ipaddress.ip_network(raw, strict=False):
            sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
' 2>/dev/null
}

_stage2_first_ipv4() {
    awk -F. '
        NF == 4 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    next
                }
            }
            print
            exit
        }
    '
}

_stage2_dns_lookup_a() {
    local name="$1"
    local result

    # Try the host's configured resolver first. Some home networks and ISPs
    # block direct queries to public resolvers, and the system resolver is the
    # closest match for what the setup host can actually use.
    result=$(dig +short A "$name" 2>/dev/null | _stage2_first_ipv4)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    result=$(dig +short A "$name" @8.8.8.8 2>/dev/null | _stage2_first_ipv4)
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi

    return 1
}

stage2_dns_classify() {
    local domain="$1" public_ip="$2"
    local jellyfin_a seerr_a apex_a

    jellyfin_a=$(_stage2_dns_lookup_a "jellyfin.${domain}" || true)
    seerr_a=$(_stage2_dns_lookup_a "seerr.${domain}" || true)

    if [[ -z "$jellyfin_a" && -z "$seerr_a" ]]; then
        apex_a=$(_stage2_dns_lookup_a "$domain" || true)
        if [[ -n "$apex_a" ]]; then
            printf 'apex-only'
            return 1
        fi
        printf 'no-a'
        return 1
    fi

    if [[ -z "$jellyfin_a" || -z "$seerr_a" ]]; then
        printf 'no-a'
        return 1
    fi
    if stage2_ip_in_cloudflare_v4 "$jellyfin_a" || stage2_ip_in_cloudflare_v4 "$seerr_a"; then
        printf 'cloudflare'
        return 1
    fi
    if [[ "$jellyfin_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$jellyfin_a"
        return 1
    fi
    if [[ "$seerr_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$seerr_a"
        return 1
    fi

    printf 'ok'
    return 0
}

# Image the ephemeral verify launches — keep in sync with docker-compose.yml's
# ddns-updater service. ponytail: a literal, not a shared constant, for one call
# site; the drift-detector scenario (tests/scenarios/ddns-verify.sh) pins the
# verify behaviour against this image's digest.
_DDNS_VERIFY_IMAGE="qmcgaw/ddns-updater:latest"

# Delay before the single retry poll after a first 500. NOT a correctness
# knob — the body classification below is the real arbiter, so an unhealed
# transient just falls through to degrade (creds kept), never a wrong reject. This
# only trades how often a slow transient auto-heals to 202 vs lands the honest
# "unchecked" tier. ponytail: fixed single retry; if provider transients prove to
# need longer or more attempts, widen this or loop with backoff (costs one more
# provider push per attempt).
_DDNS_VERIFY_RETRY_DELAY=8

# -----------------------------------------------------------------------------
# ddns_verify_via_container <config_json_path> [error_body_file]
#
# One uniform credential check for every DDNS provider, with zero blast radius:
# run a throwaway ddns-updater container whose record resolver is blackholed
# (RESOLVER_ADDRESS=127.0.0.1:1). The blackhole makes the container's hostname
# lookup FAIL, which falls through to a REAL provider push at the current public
# IP (upstream's "// update anyway" path). GET /update then maps the provider's
# response. This is a REJECTION channel, not an acceptance channel: a 500 means
# the credentials are definitely wrong; a 202 means accepted OR provider-masked
# (a username/password provider server-side no-ops on an unchanged IP without
# checking the password).
#
# The caller renders config.json first (ddns_render_config_json), so this file
# stays free of provider-registry knowledge. The rendered config is copied into a
# throwaway data dir; teardown removes both the container and the plaintext-cred
# scratch on any exit.
#
# Exit codes:
#   0  /update 202 — accepted (or masked); caller tiers the message by provider
#   1  rejected — /update 500 (bad creds) OR the container fail-fasted on an
#      invalid config (malformed token shape, bad domain eTLD). The provider /
#      validation error is written to <error_body_file> when given (the caller
#      prints it AFTER ui_spin returns, because ui_spin suppresses stdout), and
#      the caller re-prompts. A fail-fast config error is a reject, not a degrade
#      — otherwise a fat-fingered credential persists and the real ddns-updater
#      dies at install.
#   2  degrade — docker missing / image pull failed / container up but never
#      answered / curl could not connect. NEVER re-prompts: the caller lands the
#      honest "configured, unverified" tier. A pull failure must not look like
#      bad creds.
#
# The blackhole MUST fast-refuse (127.0.0.1:1 = connection refused). An
# unroutable / timing-out address would hit the container's context-deadline
# branch, skip the push, and silently turn the rejection channel off.
# -----------------------------------------------------------------------------
ddns_verify_via_container() {
    local config_json="$1" body_file="${2:-}"
    command -v docker >/dev/null 2>&1 || return 2
    [[ -f "$config_json" ]] || return 2

    # The verify runs during Stage-2 collection, BEFORE pull_images, so on a fresh
    # box the image may be absent. Pull it bounded (never an unbounded implicit
    # pull that could hang the wizard); a pull failure degrades, never rejects.
    if ! docker image inspect "$_DDNS_VERIFY_IMAGE" >/dev/null 2>&1; then
        timeout "$DDNS_VERIFY_PULL_TIMEOUT_SECONDS" docker pull "$_DDNS_VERIFY_IMAGE" >/dev/null 2>&1 || return 2
    fi

    # Inner subshell so the cleanup trap is scoped here — it fires on the
    # subshell's exit (return path OR a signal it converts to exit) without
    # clobbering the caller's traps, and works whether we are invoked directly or
    # inside ui_spin's background subshell. --rm does NOT reap a detached daemon on
    # SIGTERM, so the trap removes the container explicitly.
    (
        local scratch cid=""
        scratch=$(mktemp -d) || exit 2
        trap 'rc=$?; [[ -n "$cid" ]] && docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$scratch"; exit $rc' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        # The container runs as uid 1000. On the common single-user box the invoking
        # uid is 1000, so a 600 copy is readable; widen to 644 so a non-1000
        # installer box can still verify. The file is a throwaway that lives for
        # seconds and holds the user's own creds on their own host.
        # ponytail: if that brief world-read matters on a shared box, chown 1000
        # under `sudo -n` instead; on failure the container just degrades to exit 2.
        cp "$config_json" "$scratch/config.json" 2>/dev/null || exit 2
        chmod 755 "$scratch" && chmod 644 "$scratch/config.json" || exit 2

        # -p 127.0.0.1:0:8000 = ephemeral host port; the real ddns-updater service
        # holds 8000:8000, so a fixed publish would collide during a day-2 verify.
        cid=$(docker run -d -p 127.0.0.1:0:8000 \
            -e RESOLVER_ADDRESS=127.0.0.1:1 -e PERIOD=0 \
            -v "$scratch":/updater/data \
            "$_DDNS_VERIFY_IMAGE" 2>/dev/null) || exit 2

        # Wait for the HTTP server to publish its port. If the container EXITS
        # before it appears, it fail-fasted on the config. An invalid config — a
        # malformed token shape, a domain that fails the provider's eTLD check —
        # is a REJECT (re-prompt), NOT a degrade: otherwise a fat-fingered
        # credential would persist and the real ddns-updater would die at install.
        # A container that is up but simply slow keeps the loop going.
        local port=""
        for _ in $(seq 1 "$DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS"); do
            port=$(docker port "$cid" 8000 2>/dev/null | head -1 | sed 's/.*://')
            [[ -n "$port" ]] && break
            if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]]; then
                local ferr
                # Anchor on ddns-updater's config-validation phase wording only
                # ("validating provider specific settings: <field> is not valid: …"),
                # so an unrelated non-cred startup exit that merely happens to log
                # "invalid" degrades (exit 2) instead of being misread as a
                # bad-cred reject (exit 1) that clears good creds. A real cred/shape
                # error always carries this phrasing.
                ferr=$(docker logs "$cid" 2>&1 \
                    | grep -iE 'validating .* settings|is not valid' \
                    | tail -1)
                if [[ -n "$ferr" ]]; then
                    [[ -n "$body_file" ]] && printf '%s\n' "$ferr" >"$body_file"
                    exit 1
                fi
                exit 2
            fi
            sleep "$DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS"
        done
        [[ -n "$port" ]] || exit 2

        # Bounded poll: --max-time bounds ONE request; this caps the LOOP. The
        # first /update runs a full synchronous cycle (fetch IP + push, ~5s), so
        # give each request a generous timeout and break on the first real
        # response. Capture the body inline (-o). A container that is up but never
        # answers stays at 000 across the loop and degrades rather than spinning.
        local resp="$scratch/resp"
        _ddns_poll_update() {
            local c="000" _i
            for _i in $(seq 1 "$DDNS_VERIFY_UPDATE_POLL_ATTEMPTS"); do
                c=$(curl -s -o "$resp" -w '%{http_code}' --max-time "$DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS" \
                    "http://127.0.0.1:${port}/update" 2>/dev/null)
                [[ -n "$c" && "$c" != "000" ]] && break
                sleep "$DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS"
            done
            printf '%s' "$c"
        }

        # A 500 is NOT proof of bad credentials. ddns-updater returns 500 for its
        # OWN transient failures too — a failed public-IP fetch alone yields
        # 500 {"errors":["obtaining ipv4 address: ... connection refused"]} with
        # ZERO provider contact, and a provider-side blip surfaces the same way.
        # The flakiness this guards: identical creds rejected on attempt 1, accepted
        # on attempt 2, because attempt 1 cleared good creds on a transient 500. So
        # a single 500 never decides — wait for the transient to clear and re-poll
        # once (one extra push on a genuine badauth is bounded and harmless).
        local code
        code=$(_ddns_poll_update)
        if [[ "$code" == "500" ]]; then
            sleep "$_DDNS_VERIFY_RETRY_DELAY"
            code=$(_ddns_poll_update)
        fi

        case "$code" in
            202) exit 0 ;;
            500)
                [[ -n "$body_file" ]] && cp "$resp" "$body_file" 2>/dev/null
                # A second 500, 8s apart. If the body is ddns-updater's OWN
                # infrastructure vocabulary (IP-fetch / DNS / connection / deadline /
                # throttle), this is an environment failure, NOT a credential
                # rejection -> DEGRADE (exit 2): keep the shape-valid creds and land
                # the honest "unchecked" tier instead of clearing good creds on a
                # blip. Any other body (a real provider auth error) -> REJECT.
                # Unknown text defaults to reject = the historical fail-safe.
                if grep -qiE 'obtaining ip|dial tcp|no such host|i/o timeout|connection refused|connection reset|context deadline|too many requests' "$resp" 2>/dev/null; then
                    exit 2
                fi
                exit 1
                ;;
            *) exit 2 ;;
        esac
    )
}

stage2_check_http_ports() {
    local port80="closed" port443="closed" unavailable=()
    # Accept both rc=0 (verified open) and rc=4 (existing-bound, probed open
    # but verification skipped) as "open" for the wizard's LE attempt — if
    # the existing service is actually wrong-host'd, the LE attempt itself
    # will fail and the wizard's existing retry loop catches it.
    case $(
        net_check_tcp_port_external 80
        echo "rc:$?"
    ) in
        rc:0 | rc:4) port80="open" ;;
        rc:2)
            port80="probe-unavailable"
            unavailable+=("80")
            ;;
    esac
    case $(
        net_check_tcp_port_external 443
        echo "rc:$?"
    ) in
        rc:0 | rc:4) port443="open" ;;
        rc:2)
            port443="probe-unavailable"
            unavailable+=("443")
            ;;
    esac

    if ((${#unavailable[@]} > 0)); then
        printf 'probe-unavailable:%s' "$(
            IFS=,
            echo "${unavailable[*]}"
        )"
    elif [[ "$port80" == "open" && "$port443" == "open" ]]; then
        printf 'ok'
    elif [[ "$port80" == "closed" && "$port443" == "closed" ]]; then
        printf 'closed:80,443'
    elif [[ "$port80" == "closed" ]]; then
        printf 'closed:80'
    else
        printf 'closed:443'
    fi
}

# True external TCP port reachability check using canyouseeme.org.
#
# WHY: nc -z $PUBLIC_IP $port from inside the VM relies on hairpin NAT
# (router/cloud-network looping the VM's outbound packet back to itself).
# Works on most home routers; FAILS on cloud VMs (GCP, AWS without
# explicit hairpin) and some consumer routers — gives false "closed".
#
# HOW: bind a temporary stand-in listener on the port, then ask
# canyouseeme.org to probe FROM their server. This proves the WAN→LAN
# route works regardless of whether MediaStack's eventual listener
# (NPM, qBittorrent, etc.) has started yet. After the probe, tear down
# the listener cleanly. If something is ALREADY listening on the port
# (e.g., NPM in a re-run scenario), skip the stand-in and just probe.
#
# Returns:
#   0 — port is reachable AND traffic lands on this host's listener
#       (we spun up our own verifier listener and it received a connection)
#   1 — port is closed (firewall, no forwarding, or service unreachable)
#   2 — external probe service / our own listener could not be set up; caller
#       should fall back to a less-strict check or skip
#   3 — port is reachable from internet, but traffic does NOT land on
#       this host (router forwards public_ip:port to a DIFFERENT LAN
#       device). Only emitted when WE spun up the listener.
#   4 — port is reachable from internet, but verification was SKIPPED
#       because an existing service is already bound to the port. The
#       traffic *probably* lands on this host (the existing service is
#       presumably working), but we can't prove it without disturbing
#       the running service. Callers should treat this as "open" for
#       wizard flow purposes but warn the user the check was partial.
net_check_tcp_port_external() {
    local port="$1"
    local listener_pid="" sudo_cmd="" marker_file=""
    ((port < 1024)) && sudo_cmd="sudo"

    # If something is already bound (NPM running on a re-run, or another
    # service we should NOT disturb), skip the stand-in and just probe.
    # Limitation: in this branch we can't verify the connection lands on
    # us — the existing service may not log accepted connections in a
    # way we can scrape.
    local existing
    existing=$(ss -tln "sport = :$port" 2>/dev/null | tail -n +2)
    if [[ -z "$existing" ]]; then
        marker_file=$(mktemp -t net-probe.XXXXXX)
        # Listener accept()s up to N connections during a 60s window and
        # writes "GOT_CONNECTION" per accept. The bash side greps the
        # marker file after the probe to verify traffic actually landed
        # on THIS host's listener (not just on whoever the router
        # forwards public_ip:port to).
        $sudo_cmd python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
    s.listen(5)
except OSError:
    sys.exit(2)
s.settimeout(60)
deadline = time.time() + 60
while time.time() < deadline:
    try:
        c, _ = s.accept()
        c.close()
        print("GOT_CONNECTION", flush=True)
    except socket.timeout:
        break
    except OSError:
        break
' "$port" >"$marker_file" 2>&1 &
        listener_pid=$!
        sleep 1
        # Verify the listener actually bound (sudo prompt swallow, port
        # taken, kernel module missing, etc.). If it died, canyouseeme
        # would just see the port as closed for an irrelevant reason.
        if ! kill -0 "$listener_pid" 2>/dev/null; then
            rm -f "$marker_file"
            return 2
        fi
    fi

    # Probe via a chain of independent external services. Each call is
    # ~5-15s; we try them in order and stop at the first conclusive
    # answer. Any single service can be down/rate-limited/blocked
    # without breaking the wizard.
    local rc=2
    rc=$(_net_probe_via_external "$port")

    # Teardown: kill our stand-in if we started one. Brief drain wait so
    # any in-flight connections land on the listener before we kill it,
    # then wait for the kernel to actually free the port (callers may
    # probe again immediately for the next port).
    if [[ -n "$listener_pid" ]]; then
        sleep 2
        $sudo_cmd kill "$listener_pid" 2>/dev/null || true
        wait "$listener_pid" 2>/dev/null || true
    fi

    # If WE spun up the listener, verify it actually accepted a
    # connection. External probes report "open" based on SYN-ACK from
    # WHATEVER host the router forwards public_ip:port to — that may
    # NOT be us. Catching this distinguishes "forwarded to this host"
    # from "forwarded to some other LAN device" (and from "not
    # forwarded at all"). Only WE-spun-up case can verify; existing-
    # listener case keeps the old probe-only semantics.
    if [[ -n "$marker_file" ]]; then
        local saw_connection=0
        grep -q "GOT_CONNECTION" "$marker_file" 2>/dev/null && saw_connection=1
        rm -f "$marker_file"
        if ((rc == 0)) && ((saw_connection == 0)); then
            return 3
        fi
    elif ((rc == 0)); then
        # Existing-bound case + probe says open. We could NOT verify the
        # connection actually landed on this host (skipping the listener
        # spin-up for an already-bound port). Return rc=4 to surface the
        # caveat — caller decides whether to treat as PASS-with-warning
        # or partial-skip. Probe-failed cases (rc=1, rc=2) pass through
        # unchanged below.
        return 4
    fi
    return $rc
}

# Walk a chain of independent external port-check services. Returns
# 0 (open) / 1 (closed) on the first conclusive answer; only returns 2
# (service unreachable) when ALL services fail or return junk.
#
# Order chosen for response simplicity + reliability:
#   1. portchecker.io  — plain text "True"/"False"
#   2. canyouseeme.org — HTML, well-known, been around forever
#   3. yougetsignal.com — HTML with flag_green/flag_red img
_net_probe_via_external() {
    local port="$1"
    local ip resp
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || ip=""
    [[ -z "$ip" ]] && {
        printf 2
        return 0
    }

    # 1. portchecker.io
    if resp=$(curl -sf --max-time 12 "https://portchecker.io/api/${ip}/${port}" 2>/dev/null); then
        case "$(printf '%s' "$resp" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            true)
                printf 0
                return 0
                ;;
            false)
                printf 1
                return 0
                ;;
        esac
    fi

    # 2. canyouseeme.org — GET form is documented and scriptable; POST also
    #    works in current testing but GET is what the docs recommend.
    if resp=$(curl -sf --max-time 15 "https://canyouseeme.org/?port=${port}" 2>/dev/null); then
        if [[ "$resp" == *'<b>Success:</b>'* ]]; then
            printf 0
            return 0
        fi
        if [[ "$resp" == *'<b>Error:</b>'* ]]; then
            printf 1
            return 0
        fi
    fi

    # 3. yougetsignal.com
    if resp=$(curl -sf --max-time 12 https://ports.yougetsignal.com/check-port.php \
        -d "remoteAddress=${ip}" -d "portNumber=${port}" 2>/dev/null); then
        if [[ "$resp" == *'flag_green'* || "$resp" == *'alt="Open"'* ]]; then
            printf 0
            return 0
        fi
        if [[ "$resp" == *'flag_red'* || "$resp" == *'alt="Closed"'* ]]; then
            printf 1
            return 0
        fi
    fi

    # All three returned non-2xx, timed out, or unparseable
    printf 2
}

stage2_is_rfc6598() {
    local ip="$1"
    IP="$ip" python3 -c '
import ipaddress
import os
import sys

try:
    ip = ipaddress.ip_address(os.environ["IP"])
except ValueError:
    sys.exit(1)
sys.exit(0 if ip in ipaddress.ip_network("100.64.0.0/10") else 1)
' 2>/dev/null
}

stage2_classify_port_failure() {
    local public_ip="$1"
    local dns_state="${2:-ok}"
    local port_state="${3:-closed}"
    local hint="${4:-}"

    case "$dns_state" in
        cloudflare)
            printf 'cloudflare'
            return 0
            ;;
        aaaa-mismatch)
            printf 'aaaa-mismatch'
            return 0
            ;;
        mismatch:*)
            printf 'wrong-lan-target'
            return 0
            ;;
    esac

    if stage2_is_rfc6598 "$public_ip"; then
        printf 'cgnat'
        return 0
    fi

    case "$port_state" in
        probe-unavailable:*)
            printf 'probe-unavailable'
            return 0
            ;;
    esac

    case "$hint" in
        carrier)
            printf 'carrier-block'
            ;;
        hairpin)
            printf 'hairpin-ambiguous'
            ;;
        wrong-lan-target)
            printf 'wrong-lan-target'
            ;;
        *)
            case "$port_state" in
                closed:80 | closed:443 | closed:80,443) printf '%s' "$port_state" ;;
                *) printf 'hairpin-ambiguous' ;;
            esac
            ;;
    esac
}

stage2_port_gate_classify() {
    local public_ip="$1"
    local dns_state="${2:-ok}"
    local hint="${3:-}"
    local port_state
    port_state=$(stage2_check_http_ports)
    if [[ "$port_state" == "ok" ]]; then
        printf 'ok'
        return 0
    fi
    stage2_classify_port_failure "$public_ip" "$dns_state" "$port_state" "$hint"
}

# detect_lan_cidr — read the host's default-route interface and emit the
# normalized network CIDR (e.g. host 192.168.1.50/24 → 192.168.1.0/24).
# Returns empty + non-zero on failure; caller decides the fallback.
detect_lan_cidr() {
    local iface host_cidr
    iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ -z "$iface" ]] && return 1
    host_cidr=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4; exit}')
    [[ -z "$host_cidr" ]] && return 1
    python3 -c '
import sys, ipaddress
try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except Exception:
    sys.exit(1)
' "$host_cidr" 2>/dev/null
}

# wg_firewall_ips_for_tier — returns the comma-separated firewallIps entries
# wg-easy expects for an initial peer at the given tier. Used by both the
# Stage-2 wizard preview and the wireguard configurator.
#
# Tiers:
#   full-lan    → whole LAN CIDR, all ports
#   server      → server IP /32, all ports (host services included: SSH, SMB, etc.)
#   containers  → server IP, explicit MediaStack container ports (51821 excluded)
#   streaming          → server IP, Jellyfin only (watch-only: kids)
#   streaming-requests → server IP, Jellyfin + Seerr (watch + request: friends)
#
# Container port list: keep in sync with docker-compose.yml. Excludes 51821
# (wg-easy admin) so containers-tier peers can't add or modify other peers.
wg_firewall_ips_for_tier() {
    local tier="$1" lan_cidr="$2" server_ip="$3"

    case "$tier" in
        full-lan)
            [[ -z "$lan_cidr" ]] && return 1
            printf '%s' "$lan_cidr"
            ;;
        server)
            [[ -z "$server_ip" ]] && return 1
            printf '%s/32' "$server_ip"
            ;;
        containers)
            [[ -z "$server_ip" ]] && return 1
            # Ports: 80/443/81 NPM (HTTP/HTTPS/admin), 3000 Homepage, 3001 Uptime Kuma,
            # 5055 Seerr, 6767 Bazarr, 7359/udp Jellyfin auto-discovery, 7878 Radarr,
            # 8000 DDNS, 8080 qBittorrent, 8090 Beszel, 8096 Jellyfin, 8191 FlareSolverr,
            # 8989 Sonarr, 9000 Portainer, 9117 Jackett. 51821 (wg-easy admin) excluded.
            local ports=(80/tcp 81/tcp 443/tcp 3000/tcp 3001/tcp 5055/tcp 6767/tcp
                7359/udp 7878/tcp 8000/tcp 8080/tcp 8090/tcp 8096/tcp 8191/tcp
                8989/tcp 9000/tcp 9117/tcp)
            local entries=() p
            for p in "${ports[@]}"; do entries+=("${server_ip}:${p}"); done
            local IFS=,
            printf '%s' "${entries[*]}"
            ;;
        streaming)
            [[ -z "$server_ip" ]] && return 1
            printf '%s:8096/tcp' "$server_ip"
            ;;
        streaming-requests)
            [[ -z "$server_ip" ]] && return 1
            printf '%s:8096/tcp,%s:5055/tcp' "$server_ip" "$server_ip"
            ;;
        *)
            return 1
            ;;
    esac
}

# stage2_wireguard_access_tier_env — given the wizard's tier choice plus the
# detected/confirmed LAN CIDR and server IP, emit the env-key lines the wizard
# persists. WG_PER_CLIENT_FIREWALL is true for every tier; users wanting full
# tunnel set both WG_INIT_ALLOWED_IPS and WG_PER_CLIENT_FIREWALL=false in .env.
stage2_wireguard_access_tier_env() {
    local tier="$1" lan_cidr="$2" server_ip="$3"
    local allowed_ips

    case "$tier" in
        full-lan)
            [[ -z "$lan_cidr" ]] && return 1
            allowed_ips="$lan_cidr"
            ;;
        server | containers | streaming | streaming-requests)
            [[ -z "$server_ip" ]] && return 1
            allowed_ips="${server_ip}/32"
            ;;
        *)
            return 1
            ;;
    esac

    printf "WG_ACCESS_TIER='%s'\n" "$tier"
    printf "WG_LAN_CIDR='%s'\n" "$lan_cidr"
    printf "WG_SERVER_LAN_IP='%s'\n" "$server_ip"
    printf "WG_INIT_ALLOWED_IPS='%s'\n" "$allowed_ips"
    printf "WG_PER_CLIENT_FIREWALL='true'\n"
}

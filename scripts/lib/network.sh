# =============================================================================
# MediaStack — shared network utilities
# =============================================================================
# Reusable functions for public IP detection, speed testing, and TCP port
# probing. Sourced by both wizard.sh (discovery phase) and port-check.sh.
#
# Depends on: curl, nc (netcat), python3, speedtest-cli (optional).
# UI_DEMO=1 mode returns fake data so the wizard demo works offline.

_NET_PUBLIC_IP=""
_NET_DL_MBPS=""
_NET_UL_MBPS=""
declare -A _NET_PORT_STATUS 2>/dev/null || true
_STAGE2_CLOUDFLARE_IPS_V4=""

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
# net_run_speedtest — measure download and upload bandwidth
# Sets _NET_DL_MBPS and _NET_UL_MBPS (integers, Mbps). Returns 0/1.
# Caller should wrap with ui_spin for spinner display.
# -----------------------------------------------------------------------------
net_run_speedtest() {
    _NET_DL_MBPS=""
    _NET_UL_MBPS=""
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        _NET_DL_MBPS=120
        _NET_UL_MBPS=40
        return 0
    fi
    command -v speedtest-cli &>/dev/null || return 1
    local tmpfile
    tmpfile=$(mktemp)
    if timeout 60 speedtest-cli --json > "$tmpfile" 2>/dev/null; then
        local results
        results=$(python3 -c "
import json, sys
with open('$tmpfile') as f:
    d = json.load(f)
print(int(d['download'] / 1_000_000))
print(int(d['upload'] / 1_000_000))" 2>/dev/null)
        if [[ -n "$results" ]]; then
            _NET_DL_MBPS=$(echo "$results" | head -1)
            _NET_UL_MBPS=$(echo "$results" | tail -1)
            rm -f "$tmpfile"
            # Defense in depth for downstream consumers (e.g. _stage1_mbps_to_mbs):
            # require strict integer literals so a future speedtest-cli/json
            # change returning notation like '1.2e8' or an error string can't
            # flow into shell or python contexts.
            if ! [[ "$_NET_DL_MBPS" =~ ^[0-9]+$ && "$_NET_UL_MBPS" =~ ^[0-9]+$ ]]; then
                _NET_DL_MBPS=""
                _NET_UL_MBPS=""
                return 1
            fi
            return 0
        fi
    fi
    rm -f "$tmpfile"
    return 1
}

# -----------------------------------------------------------------------------
# net_check_tcp_port <port> — DEPRECATED: probe a TCP port on the public IP.
# Uses `nc -z $PUBLIC_IP $port`, which depends on hairpin NAT and conflates
# "is the port reachable from the internet?" with "is anything listening
# locally?" Prefer net_check_tcp_port_external for forwarding checks, or
# net_is_port_locally_bound for local availability checks.
# Kept for back-compat with tests/unit/stage2-ports.sh which redefines it.
# Returns 0 (open) or 1 (closed/error).
# -----------------------------------------------------------------------------
net_check_tcp_port() {
    local port="$1"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        [[ "$port" == "6881" || "$port" == "80" || "$port" == "443" ]] && return 0
        return 1
    fi
    [[ -z "$_NET_PUBLIC_IP" ]] && return 1
    nc -z -w5 "$_NET_PUBLIC_IP" "$port" 2>/dev/null
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

# -----------------------------------------------------------------------------
# net_port_status_label <port> — colored status string for display
# Returns: "✓ open" (green) | "✗ closed" (yellow) | "UDP (unverifiable)" (gray)
# -----------------------------------------------------------------------------
net_port_status_label() {
    local port="$1"
    local status="${_NET_PORT_STATUS[$port]:-unknown}"
    case "$status" in
        open)             echo -e "${GREEN}${_G_CHECK} open${NC}" ;;
        closed)           echo -e "${YELLOW}${_G_CROSS} closed${NC}" ;;
        udp-unverifiable) echo -e "${GRAY}UDP (unverifiable)${NC}" ;;
        *)                echo -e "${GRAY}? unknown${NC}" ;;
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
    local jellyfin_a jellyseerr_a apex_a

    jellyfin_a=$(_stage2_dns_lookup_a "jellyfin.${domain}" || true)
    jellyseerr_a=$(_stage2_dns_lookup_a "jellyseerr.${domain}" || true)

    if [[ -z "$jellyfin_a" && -z "$jellyseerr_a" ]]; then
        apex_a=$(_stage2_dns_lookup_a "$domain" || true)
        if [[ -n "$apex_a" ]]; then
            printf 'apex-only'
            return 1
        fi
        printf 'no-a'
        return 1
    fi

    if [[ -z "$jellyfin_a" || -z "$jellyseerr_a" ]]; then
        printf 'no-a'
        return 1
    fi
    if stage2_ip_in_cloudflare_v4 "$jellyfin_a" || stage2_ip_in_cloudflare_v4 "$jellyseerr_a"; then
        printf 'cloudflare'
        return 1
    fi
    if [[ "$jellyfin_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$jellyfin_a"
        return 1
    fi
    if [[ "$jellyseerr_a" != "$public_ip" ]]; then
        printf 'mismatch:%s' "$jellyseerr_a"
        return 1
    fi

    printf 'ok'
    return 0
}

stage2_dynu_validate_response() {
    local response="$1"
    local mode="${2:-token}"
    local token="${response%%[[:space:]]*}"

    case "$token" in
        good|nochg)
            printf 'ok'
            return 0
            ;;
        badauth)
            if [[ "$mode" == "message" ]]; then
                printf "wrong IP-update password (not your account password -- your IP-update password from Dynu's IP Update Settings page)"
            else
                printf 'badauth'
            fi
            return 1
            ;;
        nohost|abuse|notfqdn|numhost|dnserr|911|unknown|servererror|!donator)
            printf '%s' "$token"
            return 1
            ;;
        *)
            printf 'unknown'
            return 1
            ;;
    esac
}

stage2_dynu_preflight() {
    local hostname="$1" username="$2" password="$3"
    local response
    response=$(curl -fsS --max-time 15 --get "https://api.dynu.com/nic/update" \
        --data-urlencode "hostname=${hostname}" \
        --data-urlencode "username=${username}" \
        --data-urlencode "password=${password}" 2>/dev/null) || {
        printf 'network'
        return 1
    }
    stage2_dynu_validate_response "$response"
}

stage2_check_http_ports() {
    local port80="closed" port443="closed" unavailable=()
    # Accept both rc=0 (verified open) and rc=4 (existing-bound, probed open
    # but verification skipped) as "open" for the wizard's LE attempt — if
    # the existing service is actually wrong-host'd, the LE attempt itself
    # will fail and the wizard's existing retry loop catches it.
    case $(net_check_tcp_port_external 80; echo "rc:$?") in
        rc:0|rc:4) port80="open" ;;
        rc:2) port80="probe-unavailable"; unavailable+=("80") ;;
    esac
    case $(net_check_tcp_port_external 443; echo "rc:$?") in
        rc:0|rc:4) port443="open" ;;
        rc:2) port443="probe-unavailable"; unavailable+=("443") ;;
    esac

    if (( ${#unavailable[@]} > 0 )); then
        printf 'probe-unavailable:%s' "$(IFS=,; echo "${unavailable[*]}")"
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
    (( port < 1024 )) && sudo_cmd="sudo"

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
' "$port" > "$marker_file" 2>&1 &
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
        if (( rc == 0 )) && (( saw_connection == 0 )); then
            return 3
        fi
    elif (( rc == 0 )); then
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
    [[ -z "$ip" ]] && { printf 2; return 0; }

    # 1. portchecker.io
    if resp=$(curl -sf --max-time 12 "https://portchecker.io/api/${ip}/${port}" 2>/dev/null); then
        case "$(printf '%s' "$resp" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            true)  printf 0; return 0 ;;
            false) printf 1; return 0 ;;
        esac
    fi

    # 2. canyouseeme.org — GET form is documented and scriptable; POST also
    #    works in current testing but GET is what the docs recommend.
    if resp=$(curl -sf --max-time 15 "https://canyouseeme.org/?port=${port}" 2>/dev/null); then
        if [[ "$resp" == *'<b>Success:</b>'* ]]; then printf 0; return 0; fi
        if [[ "$resp" == *'<b>Error:</b>'* ]];   then printf 1; return 0; fi
    fi

    # 3. yougetsignal.com
    if resp=$(curl -sf --max-time 12 https://ports.yougetsignal.com/check-port.php \
        -d "remoteAddress=${ip}" -d "portNumber=${port}" 2>/dev/null); then
        if [[ "$resp" == *'flag_green'* || "$resp" == *'alt="Open"'* ]];   then printf 0; return 0; fi
        if [[ "$resp" == *'flag_red'*   || "$resp" == *'alt="Closed"'* ]]; then printf 1; return 0; fi
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
                closed:80|closed:443|closed:80,443) printf '%s' "$port_state" ;;
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
#   streaming   → server IP, Jellyfin/Jellyseerr/Homepage only
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
            # 5055 Jellyseerr, 6767 Bazarr, 7359/udp Jellyfin auto-discovery, 7878 Radarr,
            # 8000 DDNS, 8080 qBittorrent, 8090 Beszel, 8096 Jellyfin, 8191 FlareSolverr,
            # 8989 Sonarr, 9000 Portainer, 9117 Jackett. 51821 (wg-easy admin) excluded.
            local ports=(80/tcp 81/tcp 443/tcp 3000/tcp 3001/tcp 5055/tcp 6767/tcp \
                7359/udp 7878/tcp 8000/tcp 8080/tcp 8090/tcp 8096/tcp 8191/tcp \
                8989/tcp 9000/tcp 9117/tcp)
            local entries=() p
            for p in "${ports[@]}"; do entries+=("${server_ip}:${p}"); done
            local IFS=,; printf '%s' "${entries[*]}"
            ;;
        streaming)
            [[ -z "$server_ip" ]] && return 1
            printf '%s:8096/tcp,%s:5055/tcp,%s:3000/tcp' "$server_ip" "$server_ip" "$server_ip"
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
        server|containers|streaming)
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

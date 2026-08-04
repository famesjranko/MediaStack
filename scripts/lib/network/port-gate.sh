# Owns: Stage 2 HTTP port-gate classification and external reachability probes.
# Sources: scripts/lib/network.sh state plus curl, ss, python3, sudo, and standard host utilities.
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


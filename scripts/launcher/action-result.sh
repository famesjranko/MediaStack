#!/usr/bin/env bash
# Owns: Shared launcher state, banner, stack-management actions, and action results.
# Sources: launcher globals, .env state, scripts/lib/ui.sh, network.sh, storage.sh, and compose helpers.

_cached_public_ip() {
    if ((_MS_PUBLIC_IP_CHECKED == 0)); then
        if net_detect_public_ip 2>/dev/null; then
            _MS_PUBLIC_IP="$_NET_PUBLIC_IP"
        else
            _MS_PUBLIC_IP=""
        fi
        # Cache the result either way — a FAILED detection is sticky ("not detected")
        # until "Refresh status" clears the flag. Deliberate: net_detect_public_ip is a
        # ~10s curl, so retrying it every render would freeze the menu on an offline box.
        _MS_PUBLIC_IP_CHECKED=1
    fi
    printf '%s' "$_MS_PUBLIC_IP"
}

_docker_reachable() {
    command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

_detect_lan_ip() { ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

_detect_gateway() { ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'; }

render_banner() {
    local hostname_short
    hostname_short=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    # Prime the session public-IP cache in THIS shell, then read the global. Reading
    # it via public_ip=$(_cached_public_ip) would run the getter in a $() subshell and
    # discard the warm _MS_PUBLIC_IP_CHECKED flag, re-running the (slow) curl every render.
    local public_ip
    _cached_public_ip >/dev/null
    public_ip="$_MS_PUBLIC_IP"

    # Network block shown in both states: LAN IP is how you actually reach your
    # services; Router is the gateway you open to set up port forwarding; Public
    # IP is your WAN address. Shown only when detected (graceful if offline).
    local lan_ip gateway net_lines=()
    lan_ip=$(_detect_lan_ip)
    gateway=$(_detect_gateway)
    [[ -n "$lan_ip" ]] && net_lines+=("LAN IP:      ${lan_ip}")
    [[ -n "$gateway" ]] && net_lines+=("Router:      ${gateway}")
    net_lines+=("Public IP:   ${public_ip:-not detected}")

    # Probe Docker reachability ONCE — render_banner is the every-menu-loop hot path
    # and _docker_reachable is an un-memoized `docker info`; both the DDNS line and
    # the status line below need it.
    local _dockup=0
    is_installed && _docker_reachable && _dockup=1

    # DDNS status — shown ONLY when a provider is configured AND its container is
    # running (the status helper returns off/stopped otherwise, which we skip). The
    # IP is coloured green only when it matches the WAN IP (record is confirmed). The
    # box measures visible width by stripping REAL escape bytes, so derive real-ESC
    # colours via printf %b (the $GREEN/$NC literals would inflate the width math and
    # mis-pad the box); both go empty when colour is disabled.
    if ((_dockup)); then
        local _rgn="" _ryl="" _rnc=""
        [[ -n "${GREEN:-}" ]] && {
            printf -v _rgn '%b' "$GREEN"
            printf -v _ryl '%b' "${YELLOW:-}"
            printf -v _rnc '%b' "${NC:-}"
        }
        local _dst
        _dst=$(_ddns_status "$public_ip")
        case "$_dst" in
            ok:*) net_lines+=("DDNS:        ${_rgn}${_dst#ok:}${_rnc}") ;;
            stale:*) net_lines+=("DDNS:        ${_ryl}${_dst#stale:}${_rnc} (propagating?)") ;;
            unresolved) net_lines+=("DDNS:        ${DOMAIN:-domain} not resolving yet") ;;
            *) ;; # off / stopped -> no DDNS line
        esac
    fi

    local lines=()
    if is_installed; then
        if ((_dockup)); then
            local summary
            if summary=$(_compose_running_summary); then
                lines+=("Status:      Running   ${summary} containers")
            else
                lines+=("Status:      Installed (stack not running)")
            fi
        else
            lines+=("Status:      Installed (Docker not reachable)")
        fi
        if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]]; then
            lines+=("Domain:      ${DOMAIN}")
        fi
        lines+=("Host:        ${hostname_short}")
        lines+=("${net_lines[@]}")
    else
        lines+=("Status:      Not yet installed")
        lines+=("Host:        ${hostname_short}")
        lines+=("${net_lines[@]}")
    fi

    ui_box "MediaStack - Turnkey Media Server" "${lines[@]}"
}

_stack_system_lines() {
    local summary
    if summary=$(_compose_running_summary); then
        ui_kv "Stack" "${summary} containers running"
    else
        ui_kv "Stack" "not running"
    fi
    local _tc _gpu="${JELLYFIN_GPU:-none}"
    case "$_gpu" in
        nvidia)
            _tc="NVIDIA NVENC"
            local _drv
            _drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
            [[ -n "$_drv" ]] && _tc+=" — driver ${_drv}"
            [[ -n "${NVIDIA_DRIVER_MODE:-}" ]] && _tc+=" (${NVIDIA_DRIVER_MODE})"
            ;;
        intel) _tc="Intel QSV" ;;
        amd) _tc="AMD VAAPI" ;;
        *) _tc="Software (no GPU acceleration)" ;;
    esac
    ui_kv "Transcoding" "$_tc"
    local _remote
    case "${REMOTE_WEB_STATE:-}" in
        ready)
            _remote="Ready"
            [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]] && _remote+=" — ${DOMAIN}"
            ;;
        skipped) _remote="LAN only (remote skipped)" ;;
        *) _remote="LAN only" ;;
    esac
    ui_kv "Remote access" "$_remote"
    if _ddns_configured; then
        local _dprov="${DDNS_PROVIDER:-unknown}" _dval _dstat
        # _ddns_status already carries the resolved IP (ok:<ip> / stale:<ip>) — parse it
        # out rather than re-resolving, so this box digs the record once, not twice.
        _dstat=$(_ddns_status "$(_cached_public_ip)")
        case "$_dstat" in
            ok:*) _dval="${_dprov} · ${_dstat#ok:} (up to date)" ;;
            stale:*) _dval="${_dprov} · ${_dstat#stale:} (propagating?)" ;;
            unresolved) _dval="${_dprov} · not resolving yet" ;;
            stopped) _dval="${_dprov} · updater stopped" ;;
            *) _dval="${_dprov}" ;;
        esac
        ui_kv "DDNS" "$_dval"
    fi
    ui_kv "Updates" "${IMAGE_CHANNEL:-stable} channel"
    local _data="${DATA_DIR:-/data}" _free
    _free=$(df -h --output=avail "$_data" 2>/dev/null | tail -1 | tr -d ' ')
    local _dataline="$_data"
    [[ -n "$_free" ]] && _dataline+=" — ${_free} free"
    ui_kv "Data" "$_dataline"
}

_render_service_list() {
    local profiles=()
    _build_profile_args profiles
    local rows
    rows=$(docker compose "${profiles[@]}" ps --format json 2>/dev/null | python3 -c '
import sys, json, re
def uptime(status):
    m = re.search(r"Up\s+(.*?)(?:\s+\(|$)", status or "")
    if not m:
        return ""
    txt = m.group(1)
    num = re.search(r"(\d+)", txt)
    n = num.group(1) if num else "1"
    for unit, sfx in (("second","s"),("minute","m"),("hour","h"),
                      ("day","d"),("week","w"),("month","mo"),("year","y")):
        if unit in txt:
            return n + sfx
    return txt
rows = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    for it in (d if isinstance(d, list) else [d]):
        name = it.get("Service") or it.get("Name") or "?"
        health = (it.get("Health") or "").strip()
        state = (it.get("State") or "").strip()
        up = uptime(it.get("Status"))
        if health == "healthy" or (not health and state == "running"):
            status, cls = ("healthy" if health else "running"), "ok"
        elif health == "starting" or state == "restarting":
            status, cls = (health or state), "warn"
        elif health == "unhealthy" or state in ("exited", "dead"):
            status, cls = (health or state), "err"
        else:
            status, cls = (state or "unknown"), "dim"
        seen = set(); ports = []
        for p in (it.get("Publishers") or []):
            pp = p.get("PublishedPort") or 0
            if not pp:
                continue
            proto = p.get("Protocol") or "tcp"
            if (pp, proto) in seen:
                continue
            seen.add((pp, proto))
            ports.append((pp, "" if proto == "tcp" else "/" + proto))
        ports.sort()
        rows.append((name, cls, status, up, ", ".join(f"{pp}{sfx}" for pp, sfx in ports)))
rows.sort()
for r in rows:
    print("\x1f".join(r))
' 2>/dev/null)

    if [[ -z "$rows" ]]; then
        docker compose "${profiles[@]}" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true
        return 0
    fi

    # Split on \x1f (unit separator), not tab: tab is IFS-whitespace so bash
    # would coalesce consecutive tabs and drop empty fields — a restarting
    # container (empty uptime, non-empty ports) would then render its ports in
    # the uptime column. \x1f preserves empty fields.
    local maxn=0 _n
    while IFS=$'\x1f' read -r _n _ _ _ _; do
        ((${#_n} > maxn)) && maxn=${#_n}
    done <<<"$rows"

    # Pad the status glyph to a fixed visible width so the status/uptime/ports
    # columns align across rows of differing health. ASCII tags vary 4-7 cols
    # ([OK]..[ERROR]) -> pad to 7; unicode icons are 1 col (multibyte, so width 1
    # means %-*s never byte-pads them and the output is identical to before).
    local cls name st up pt tok color glyph up_disp gw=1
    [[ "$_G_UNICODE" == 1 ]] || gw=7
    while IFS=$'\x1f' read -r name cls st up pt; do
        case "$cls" in
            ok)
                tok=ok
                color="$GREEN"
                ;;
            warn)
                tok=warn
                color="$YELLOW"
                ;;
            err)
                tok=error
                color="$RED"
                ;;
            *)
                tok=info
                color="$GRAY"
                ;;
        esac
        glyph="$(_ui_status_token "$tok")"
        up_disp=""
        [[ -n "$up" ]] && up_disp="up $up"
        printf "  %-*s ${color}%-*s %-10s${NC} ${GRAY}%-8s${NC} ${GRAY}%s${NC}\n" \
            "$maxn" "$name" "$gw" "$glyph" "$st" "$up_disp" "$pt"
    done <<<"$rows"
}

_show_action_result() {
    local rc="$1" label="$2" outcome="${3:-}" strict="${4:-0}"
    echo ""
    case "$outcome" in
        completed) ui_log ok "${label} completed successfully." ;;
        reboot-pending) ui_log warn "Reboot to finish — hardware transcoding activates after you reboot." ;;
        aborted) ui_log info "${label} aborted — no changes were made." ;;
        unchanged) ui_log info "No changes were made." ;;
        failed) ui_log error "${label} did not complete. Review the errors above and retry." ;;
        *)
            if ((rc != 0)); then
                ui_log error "${label} exited with code ${rc}."
            elif ((strict)); then
                ui_log warn "${label} did not complete — nothing was finished. Re-run when you're ready."
            else
                ui_log ok "${label} completed successfully."
            fi
            ;;
    esac
}

_run_setup_return() {
    local strict="$1" label="$2"
    shift 2
    local rc=0 outcome="" result_file=""
    # setup.sh reports its real outcome (completed / aborted / unchanged) by
    # writing a one-word token to this file; without it the launcher can only
    # guess from the exit code. No-op for direct setup.sh runs (var unset). If
    # mktemp itself fails, a strict action with a bare exit 0 falls back to "did
    # not complete" — a safe under-claim, never a false "completed".
    result_file=$(mktemp 2>/dev/null) || result_file=""
    [[ -n "$result_file" ]] && export MEDIASTACK_LAUNCHER_RESULT="$result_file"
    "$SCRIPT_DIR/setup.sh" "$@" || rc=$?
    if [[ -n "$result_file" ]]; then
        [[ -s "$result_file" ]] && outcome=$(<"$result_file")
        rm -f "$result_file"
        unset MEDIASTACK_LAUNCHER_RESULT
    fi
    _show_action_result "$rc" "$label" "$outcome" "$strict"
    pause_for_menu
    exec "$SCRIPT_DIR/mediastack"
}

action_service_stop() {
    echo ""
    local svcs=()
    mapfile -t svcs < <(docker compose ps --filter status=running --format '{{.Name}}' 2>/dev/null || true)
    if ((${#svcs[@]} == 0)); then
        ui_log info "No services are running."
        pause_for_menu
        return 0
    fi
    svcs+=("Back")
    local choice rc=0
    choice=$(ui_choose "Stop which service?" "${svcs[@]}")
    [[ "$choice" == "Back"* ]] && return 0
    docker compose stop "$choice" 2>&1 || rc=$?
    _show_action_result "$rc" "Stop $choice"
    pause_for_menu
}

action_service_start() {
    echo ""
    local svcs=()
    mapfile -t svcs < <(docker compose ps --filter status=exited --format '{{.Name}}' 2>/dev/null || true)
    if ((${#svcs[@]} == 0)); then
        ui_log info "No stopped services."
        pause_for_menu
        return 0
    fi
    svcs+=("Back")
    local choice rc=0
    choice=$(ui_choose "Start which service?" "${svcs[@]}")
    [[ "$choice" == "Back"* ]] && return 0
    if ! storage_guard_before_start; then
        pause_for_menu
        return 0
    fi
    docker compose start "$choice" 2>&1 || rc=$?
    _show_action_result "$rc" "Start $choice"
    pause_for_menu
}

action_stack_stop() {
    echo ""
    # Precondition check: if no containers exist for this project, calling
    # `down` would either be a no-op or fail with a confusing rc=1 +
    # invalid-spec error if .env is incomplete. Bail early. Capture-then-test
    # avoids the SIGPIPE+pipefail race that motivated C1: piping into
    # `grep -q .` reads false when grep's early exit SIGPIPEs compose.
    local ids
    ids=$(docker compose ps -q 2>/dev/null || true)
    if [[ -z "$ids" ]]; then
        ui_log info "No MediaStack services are running - nothing to stop."
        pause_for_menu
        return 0
    fi
    if ! ui_confirm "Stop all MediaStack services now?" no; then
        ui_log info "Left services running."
        pause_for_menu
        return 0
    fi
    ui_log info "Stopping all MediaStack services..."
    # Pass profile args so optional services (npm, bazarr, wireguard, autoheal)
    # actually stop. `--profile all` is a literal name, not a wildcard, so
    # without explicit profile args those containers survive `down`.
    # No --remove-orphans: the profile set is now disk-fresh (shared
    # _build_profile_args), so plain `down` stops exactly the selected services
    # without risking removal of containers that look orphaned to a stale profile.
    local profiles=()
    _build_profile_args profiles
    local rc=0
    docker compose "${profiles[@]}" down 2>&1 || rc=$?
    _show_action_result "$rc" "Stop stack"
    pause_for_menu
}

action_stack_start() {
    echo ""
    if ! storage_guard_before_start; then
        pause_for_menu
        return 0
    fi
    ui_log info "Starting MediaStack services..."
    # Pass profile args so optional services (npm, bazarr, wireguard, autoheal)
    # come back up — not just default-profile ones.
    local profiles=()
    _build_profile_args profiles
    local rc=0
    docker compose "${profiles[@]}" up -d 2>&1 || rc=$?
    _show_action_result "$rc" "Start stack"
    pause_for_menu
}

action_stack_logs() {
    echo ""
    ui_log info "Tailing logs from all active profiles (Ctrl-C to return to menu)..."
    echo ""
    # Ignore SIGINT in the launcher itself — `trap - INT` would reset to
    # default which in non-interactive bash exits the whole shell on Ctrl-C.
    # `trap '' INT` makes bash drop the signal; the docker child still
    # receives it via the process group and exits cleanly.
    trap '' INT
    local profiles=()
    _build_profile_args profiles
    docker compose "${profiles[@]}" logs -f --tail=200 2>&1 || true
    trap 'echo; echo "  Goodbye."; exit 0' INT
    echo ""
    ui_log info "Logs stream ended."
    pause_for_menu
}

submenu_manage_stack() {
    while true; do
        clear
        if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null 2>&1; then
            ui_box "MediaStack - Manage Stack" "$(ui_kv 'Stack' 'Docker not available')"
            echo ""
        else
            # Box banner carries the system state; the per-service list (health,
            # uptime, ports) sits below it — folds the old "Show service status"
            # view into this one screen.
            local _sys=()
            mapfile -t _sys < <(_stack_system_lines)
            ui_box "MediaStack - Manage Stack" "${_sys[@]}"
            echo ""
            _render_service_list
            echo ""
        fi
        local choice
        choice=$(ui_choose "Manage stack:" \
            "Stop a service" \
            "Start a service" \
            "Stop all services" \
            "Start all services" \
            "Tail logs (live)" \
            "Back")

        case "$choice" in
            "Stop a service"*) action_service_stop ;;
            "Start a service"*) action_service_start ;;
            "Stop all services"*) action_stack_stop ;;
            "Start all services"*) action_stack_start ;;
            "Tail logs"*) action_stack_logs ;;
            *) return 0 ;;
        esac
    done
}

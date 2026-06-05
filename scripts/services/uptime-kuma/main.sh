# =============================================================================
# Uptime Kuma — auto-provision HTTP monitors + status page
# =============================================================================
# Runs an ephemeral Node.js container on the mediastack network to configure
# Uptime Kuma v2 via socket.io-client (direct Socket.IO). No npm packages on the host.

configure_uptime_kuma() {
    echo ""
    echo -e "${BOLD}Configuring Uptime Kuma...${NC}"

    local admin_user="${JELLYFIN_ADMIN_USER:-admin}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-changeme}"

    # Build list of running service containers and their health URLs
    local running
    running=$(docker compose ps --format '{{.Names}}' 2>/dev/null)

    local monitors_json
    monitors_json=$(RUNNING="$running" python3 -c '
import os, json

running = set(os.environ["RUNNING"].split())

monitor_map = {
    "jellyfin":     {"name": "Jellyfin",      "url": "http://jellyfin:8096/health"},
    "sonarr":       {"name": "Sonarr",         "url": "http://sonarr:8989/ping"},
    "radarr":       {"name": "Radarr",         "url": "http://radarr:7878/ping"},
    "jackett":      {"name": "Jackett",        "url": "http://jackett:9117"},
    "qbittorrent":  {"name": "qBittorrent",    "url": "http://qbittorrent:8080"},
    "jellyseerr":   {"name": "Jellyseerr",     "url": "http://jellyseerr:5055"},
    "bazarr":       {"name": "Bazarr",         "url": "http://bazarr:6767"},
    "flaresolverr": {"name": "FlareSolverr",   "url": "http://flaresolverr:8191/health"},
    "homepage":     {"name": "Homepage",       "url": "http://homepage:3000"},
    "npm":          {"name": "NPM",            "url": "http://npm:81"},
    "portainer":    {"name": "Portainer",      "url": "http://portainer:9000"},
    "wireguard":    {"name": "WireGuard",      "url": "http://wireguard:51821"},
    "ddns-updater": {"name": "DDNS Updater",   "url": "http://ddns-updater:8000"},
    "beszel":       {"name": "Beszel",         "url": "http://beszel:8090/api/health"},
}

monitors = []
for container, info in monitor_map.items():
    if container in running:
        monitors.append(info)

print(json.dumps(monitors))
')

    if [[ -z "$monitors_json" || "$monitors_json" == "[]" ]]; then
        log_warn "No running services found to monitor"
        return 0
    fi

    # Pre-pull so the timeout budget covers configuration, not image download.
    docker pull node:22-slim >/dev/null 2>&1 || true

    local kuma_err="/tmp/kuma-configure.err"
    local _kuma_envfile
    _kuma_envfile=$(mktemp)
    printf 'KUMA_USER=%s\nKUMA_PW=%s\n' "$admin_user" "$admin_pw" > "$_kuma_envfile"
    local result
    result=$(timeout 120 docker run --rm --network mediastack \
        --env-file "$_kuma_envfile" \
        -e MONITORS_JSON="$monitors_json" \
        node:22-slim sh -c '
cd /tmp && npm install --no-audit --no-fund --loglevel=error socket.io-client >&2 || { echo "{\"error\": \"npm install failed\"}" ; exit 1; }
node -e "
const { io } = require(\"socket.io-client\");
const user = process.env.KUMA_USER;
const pw = process.env.KUMA_PW;
const monitorsInput = JSON.parse(process.env.MONITORS_JSON);
function connect() {
    return new Promise((resolve, reject) => {
        const s = io(\"http://uptime-kuma:3001\", { transports: [\"websocket\"], reconnection: false });
        const timer = setTimeout(() => { s.disconnect(); reject(new Error(\"connect timeout\")); }, 20000);
        s.on(\"connect\", () => { clearTimeout(timer); resolve(s); });
        s.on(\"connect_error\", (err) => { clearTimeout(timer); s.disconnect(); reject(err); });
    });
}

function emit(socket, event, ...args) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(event + \" timeout\")), 30000);
        socket.emit(event, ...args, (res) => { clearTimeout(timer); resolve(res); });
    });
}

(async () => {
    let socket, needSetup;
    for (let attempt = 1; attempt <= 3; attempt++) {
        try {
            socket = await connect();
            needSetup = await emit(socket, \"needSetup\");
            break;
        } catch (e) {
            if (socket) socket.disconnect();
            if (attempt === 3) { console.log(JSON.stringify({ error: e.message })); process.exit(1); }
            await new Promise(r => setTimeout(r, 3000));
        }
    }

    try {
        if (needSetup) {
            const setupRes = await emit(socket, \"setup\", user, pw);
            if (!setupRes || !setupRes.ok) {
                throw new Error(\"Setup failed: \" + ((setupRes && setupRes.msg) || \"unknown\"));
            }
        }

        let monitorListTimedOut = false;
        const monitorListP = new Promise((resolve) => {
            const timer = setTimeout(() => { monitorListTimedOut = true; resolve({}); }, 10000);
            socket.once(\"monitorList\", (list) => { clearTimeout(timer); resolve(list); });
        });
        const loginRes = await emit(socket, \"login\", { username: user, password: pw });
        if (!loginRes.ok) throw new Error(\"Auth failed: \" + (loginRes.msg || \"unknown\"));
        const existingMonitors = await monitorListP;

        await emit(socket, \"setSettings\", { checkUpdate: false }, pw);

        const existingUrls = new Set();
        for (const id of Object.keys(existingMonitors)) {
            const m = existingMonitors[id];
            if (m && m.url) existingUrls.add(m.url);
        }

        const created = [], skipped = [], errors = [];
        if (monitorListTimedOut) errors.push(\"monitorList event timed out - duplicate monitors possible on re-run\");
        for (const mon of monitorsInput) {
            if (existingUrls.has(mon.url)) { skipped.push(mon.name); continue; }
            try {
                const r = await emit(socket, \"add\", {
                    type: \"http\", name: mon.name, url: mon.url, method: \"GET\",
                    interval: 60, retryInterval: 60, maxretries: 3, maxredirects: 0,
                    accepted_statuscodes: [\"200-299\", \"300-399\"],
                    notificationIDList: {}, conditions: []
                });
                if (r && r.ok) created.push(mon.name);
                else errors.push(mon.name + \": \" + ((r && r.msg) || \"add failed\"));
            } catch (e) { errors.push(mon.name + \": \" + e.message); }
        }

        const refreshP = new Promise((resolve) => {
            const timer = setTimeout(() => { errors.push(\"monitorList refresh timed out\"); resolve({}); }, 10000);
            socket.once(\"monitorList\", (list) => { clearTimeout(timer); resolve(list); });
        });
        await emit(socket, \"getMonitorList\");
        const allMonitors = await refreshP;

        const managedUrls = new Set(monitorsInput.map((m) => m.url));
        const managedIds = Object.keys(allMonitors).filter((id) => {
            const m = allMonitors[id];
            return m && m.url && managedUrls.has(m.url);
        }).map(Number);

        try { await emit(socket, \"addStatusPage\", \"MediaStack\", \"mediastack\"); } catch (e) {}
        try {
            const spRes = await emit(socket, \"saveStatusPage\", \"mediastack\",
                { slug: \"mediastack\", title: \"MediaStack\", theme: \"auto\", published: true,
                  showTags: false, showPoweredBy: true, showCertificateExpiry: false,
                  showOnlyLastHeartbeat: false, analyticsType: null,
                  domainNameList: [] }, \"\", [{
                name: \"Services\",
                monitorList: managedIds.map((id) => ({ id }))
            }]);
            if (spRes && !spRes.ok) errors.push(\"Status page: \" + (spRes.msg || \"save failed\"));
        } catch (e) { errors.push(\"Status page: \" + e.message); }

        socket.disconnect();
        console.log(JSON.stringify({ created, skipped, errors }));
    } catch (e) {
        socket.disconnect();
        console.log(JSON.stringify({ error: e.message }));
        process.exit(1);
    }
})();
"
' 2>"$kuma_err")
    rm -f "$_kuma_envfile"

    if [[ -z "$result" ]]; then
        log_warn "Uptime Kuma configuration returned no output"
        [[ -s "$kuma_err" ]] && log_warn "$(tail -5 "$kuma_err")"
        return 0
    fi

    # Check for top-level error
    local err
    err=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
    if [[ -n "$err" ]]; then
        log_warn "Uptime Kuma: $err"
        return 0
    fi

    # Parse results
    local created skipped_list error_list
    created=$(echo "$result" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('created',[])))" 2>/dev/null)
    skipped_list=$(echo "$result" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('skipped',[])))" 2>/dev/null)
    error_list=$(echo "$result" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('errors',[])))" 2>/dev/null)

    if [[ -n "$created" ]]; then
        log_ok "Monitors created: $created"
    fi
    if [[ -n "$skipped_list" ]]; then
        log_skip "Monitors already exist: $skipped_list"
    fi
    if [[ -n "$error_list" ]]; then
        log_warn "Monitor errors: $error_list"
    fi
    if [[ -z "$created" && -z "$skipped_list" && -z "$error_list" ]]; then
        log_ok "Uptime Kuma configured"
    fi
}

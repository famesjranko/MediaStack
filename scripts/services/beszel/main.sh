# =============================================================================
# Beszel — system resource monitoring (hub + agent) via PocketBase REST API
# =============================================================================
# Hub auto-creates a user from USER_EMAIL/USER_PASSWORD env vars on first start.
# This configurator authenticates, retrieves the agent SSH key, saves it to .env,
# recreates the agent container to pick up the key, and registers this host as a
# monitored system.
#
# The agent listens on a unix socket, not a TCP port (docker-compose.yml): it
# runs on the host network, where a port would be open on every host interface.
# Beszel documents this for a hub and agent on one host: the agent's LISTEN
# value may be a socket path, and the hub takes that path as the system's
# "Host / IP" (https://beszel.dev/guide/agent-installation#connecting-to-a-local-agent;
# agent: internal/agent/server.go GetNetwork(), addresses starting with "/" are
# unix). The socket directory is ./config/beszel/socket, which the hub already
# sees under its /beszel_data mount.

_BESZEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck source=scripts/lib/http.sh
source "$_BESZEL_LIB_DIR/http.sh"

BESZEL_LOCAL_SOCKET="/beszel_data/socket/beszel.sock"

# Logs in to the hub as the shared admin and sets BESZEL_TOKEN and
# BESZEL_USER_ID. Returns 1 (after logging why) when it cannot.
# Usage: _beszel_login <hub_url> <email> <password>
_beszel_login() {
    local hub_url="$1" admin_email="$2" admin_pw="$3"
    local auth_body auth_resp token user_id
    BESZEL_TOKEN="" BESZEL_USER_ID=""
    auth_body=$(B_EMAIL="$admin_email" B_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"identity": os.environ["B_EMAIL"], "password": os.environ["B_PW"]}))
' 2>/dev/null) || {
        log_warn "Failed to build auth payload"
        return 1
    }

    auth_resp=$(http_json_request "Beszel login" POST "$hub_url/api/collections/users/auth-with-password" \
        "$auth_body" "" "" token:string record.id:string) || return 1
    token=$(json_get token <<<"$auth_resp")
    user_id=$(json_path record.id <<<"$auth_resp")
    if [[ -z "$token" || -z "$user_id" ]]; then
        log_warn "Beszel login returned an empty token or user id"
        return 1
    fi
    BESZEL_TOKEN="$token" BESZEL_USER_ID="$user_id"
    return 0
}

# Reads a systems list from stdin and prints "<state> <id>" for the record named
# MediaStack: none, current (the socket), legacy (exactly MediaStack's old
# host.docker.internal:45876) or other (anything else, which is user state).
_beszel_local_system_state() {
    BESZEL_SOCKET="$BESZEL_LOCAL_SOCKET" python3 -c '
import os, sys, json
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    print("unreadable -")
    sys.exit(0)
for it in items:
    if not all(it.get(k) for k in ("id", "name", "host")):
        print("unreadable -")
        sys.exit(0)
    if it.get("name") != "MediaStack":
        continue
    host, port = it.get("host"), str(it.get("port"))
    if host == os.environ["BESZEL_SOCKET"]:
        state = "current"
    elif host == "host.docker.internal" and port == "45876":
        state = "legacy"
    else:
        state = "other"
    print(state, it.get("id", ""))
    break
else:
    print("none -")
' 2>/dev/null || echo "unreadable -"
}

# Registers this host in the hub, or moves MediaStack's own old TCP entry to the
# socket. A MediaStack entry with any other host or port is the user's: reported
# as drift, never rewritten. Needs a prior _beszel_login.
# Usage: beszel_sync_local_system <hub_url>
beszel_sync_local_system() {
    local hub_url="$1" systems_resp state record_id
    systems_resp=$(http_json_request "Beszel systems list" GET "$hub_url/api/collections/systems/records" \
        "" Authorization "Bearer $BESZEL_TOKEN" 'items[].id:string' 'items[].name:string' 'items[].host:string' 'items[].port:string') || return 1
    read -r state record_id < <(_beszel_local_system_state <<<"$systems_resp")

    local body
    case "$state" in
        current)
            log_skip "Beszel system 'MediaStack' already registered"
            return 0
            ;;
        other)
            log_drift "Beszel system 'MediaStack' was changed outside MediaStack - left as is (the local agent listens on $BESZEL_LOCAL_SOCKET)"
            return 0
            ;;
        legacy)
            body=$(B_SOCKET="$BESZEL_LOCAL_SOCKET" python3 -c '
import os, json
print(json.dumps({"host": os.environ["B_SOCKET"]}))' 2>/dev/null)
            if http_json_request "Beszel system migration" PATCH "$hub_url/api/collections/systems/records/$record_id" \
                "$body" Authorization "Bearer $BESZEL_TOKEN" >/dev/null; then
                log_ok "Beszel system 'MediaStack' moved from host.docker.internal:45876 to the agent's unix socket"
                BESZEL_SYSTEM_MOVED=true
                return 0
            fi
            log_warn "Beszel system migration failed"
            return 1
            ;;
        none) ;;
        *)
            log_warn "Could not parse the Beszel systems list - system 'MediaStack' left unchanged"
            return 1
            ;;
    esac

    body=$(B_USER_ID="$BESZEL_USER_ID" B_SOCKET="$BESZEL_LOCAL_SOCKET" python3 -c '
import os, json
print(json.dumps({
    "name": "MediaStack",
    "host": os.environ["B_SOCKET"],
    "users": [os.environ["B_USER_ID"]],
}))' 2>/dev/null)
    if http_json_request "Beszel system registration" POST "$hub_url/api/collections/systems/records" \
        "$body" Authorization "Bearer $BESZEL_TOKEN" id:string name:string >/dev/null; then
        log_ok "Beszel system 'MediaStack' registered"
        return 0
    fi
    log_warn "Beszel system registration failed"
    return 1
}

# Day-2 convergence (scripts/launcher/converge.sh): an existing install keeps
# its host.docker.internal:45876 entry across an update, and the agent no longer
# listens there. Moves that entry to the socket; touches nothing else.
beszel_converge_local_system() {
    if ! docker inspect beszel >/dev/null 2>&1; then
        log_skip "Beszel is not installed - its local system entry was not checked"
        return 0
    fi
    if [[ -z "${NPM_ADMIN_EMAIL:-}" || -z "${JELLYFIN_ADMIN_PASSWORD:-}" ]]; then
        log_warn "Cannot check the Beszel system entry: admin credentials (NPM_ADMIN_EMAIL, JELLYFIN_ADMIN_PASSWORD) are not set."
        return 1
    fi
    local hub_url health
    hub_url="$(service_local_url beszel)"
    # A hub recreated a moment ago can still be starting.
    for _ in $(seq 1 30); do
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' beszel 2>/dev/null || true)
        [[ -z "$health" || "$health" == "healthy" ]] && break
        sleep 2
    done
    _beszel_login "$hub_url" "$NPM_ADMIN_EMAIL" "$JELLYFIN_ADMIN_PASSWORD" || return 1
    BESZEL_SYSTEM_MOVED=false
    beszel_sync_local_system "$hub_url" || return 1
    [[ "$BESZEL_SYSTEM_MOVED" == true ]] || return 0
    # The hub keeps the old record's dead TCP connection and reports the system
    # down for minutes; a restart makes it dial the socket at once.
    if docker restart beszel >/dev/null 2>&1; then
        log_ok "Restarted the Beszel hub so it connects through the socket"
        return 0
    fi
    log_warn "Could not restart the Beszel hub after moving its system entry - run: docker restart beszel"
    return 1
}

configure_beszel() {
    echo ""
    echo -e "${BOLD}Configuring Beszel...${NC}"

    local hub_url
    hub_url="$(service_local_url beszel)"
    local admin_email="${NPM_ADMIN_EMAIL:-}"
    local admin_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$admin_email" || -z "$admin_pw" ]]; then
        log_warn "Admin credentials not set - skipping Beszel"
        return 0
    fi

    # --- 0. Ensure superuser exists (Homepage widget requires superuser auth) ---
    # The hub creates the superuser from USER_EMAIL/USER_PASSWORD on first
    # start, so probe over the API first and fall back to the CLI only when the
    # record is missing or its password has drifted. That fallback is the one
    # place the shared password still reaches a process argv: beszel's
    # PocketBase CLI accepts it only as a positional argument, and the hub image
    # is built FROM scratch, so there is no in-container shell to expand it from
    # the environment instead. Probing keeps that path out of every normal run.
    local su_body su_rc=0
    su_body=$(http_json_body identity "$admin_email" password "$admin_pw")
    if http_json_request "Beszel superuser login" POST "$hub_url/api/collections/_superusers/auth-with-password" \
        "$su_body" "" "" token:string record.id:string >/dev/null; then
        log_skip "Beszel superuser already present"
    else
        su_rc=$?
        # Schema drift must not trigger a credential repair through the CLI.
        ((su_rc == 2)) && return 1
        if docker exec beszel /beszel superuser upsert "$admin_email" "$admin_pw" >/dev/null 2>&1; then
            log_ok "Beszel superuser ensured"
        else
            log_warn "Could not upsert Beszel superuser"
            return 1
        fi
    fi

    # --- 1. Authenticate to hub ---
    _beszel_login "$hub_url" "$admin_email" "$admin_pw" || return 1
    log_ok "Beszel hub authenticated"

    # --- 2. Get SSH key from hub ---
    local key_resp hub_key
    key_resp=$(http_json_request "Beszel agent key" GET "$hub_url/api/beszel/getkey" \
        "" Authorization "Bearer $BESZEL_TOKEN" key:string) || return 1
    hub_key=$(echo "$key_resp" | json_get key)

    if [[ -z "$hub_key" ]]; then
        log_warn "Could not retrieve Beszel agent key"
        return 1
    fi

    # --- 3. Save key to .env if changed ---
    local current_key="${BESZEL_AGENT_KEY:-}"
    if [[ "$current_key" == "$hub_key" ]]; then
        log_skip "Beszel agent key already in .env"
    else
        env_save_api_key "BESZEL_AGENT_KEY" "$hub_key" || return 1
    fi

    # A previous run may have saved KEY and failed before the recreate. Compose
    # leaves an unchanged agent alone and retries any pending configuration.
    if ! docker compose up -d beszel-agent >/dev/null 2>&1; then
        log_warn "Could not recreate Beszel agent - run: docker compose up -d beszel-agent"
        return 1
    fi
    log_ok "Beszel agent is running with the hub key"

    # --- 5. Register this host as a monitored system (or move the old entry) ---
    beszel_sync_local_system "$hub_url"
}

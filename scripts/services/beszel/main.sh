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

BESZEL_LOCAL_SOCKET="/beszel_data/socket/beszel.sock"

# Logs in to the hub as the shared admin and sets BESZEL_TOKEN and
# BESZEL_USER_ID. Returns 1 (after logging why) when it cannot.
# Usage: _beszel_login <hub_url> <email> <password>
_beszel_login() {
    local hub_url="$1" admin_email="$2" admin_pw="$3"
    local auth_body auth_resp auth_code
    BESZEL_TOKEN="" BESZEL_USER_ID=""
    auth_body=$(B_EMAIL="$admin_email" B_PW="$admin_pw" python3 -c '
import os, json
print(json.dumps({"identity": os.environ["B_EMAIL"], "password": os.environ["B_PW"]}))
' 2>/dev/null) || {
        log_warn "Failed to build auth payload"
        return 1
    }

    auth_resp=$(curl_data_stdin "$auth_body" \
        -sS -X POST "$hub_url/api/collections/users/auth-with-password" \
        -H "Content-Type: application/json" -w "\n%{http_code}" 2>/dev/null) || {
        log_warn "Beszel hub not reachable - skipping"
        return 1
    }

    auth_code="${auth_resp##*$'\n'}"
    auth_resp="${auth_resp%$'\n'*}"

    if [[ ! "$auth_code" =~ ^2 ]]; then
        log_warn "Beszel auth failed (HTTP $auth_code) - hub may still be initializing"
        return 1
    fi

    BESZEL_TOKEN=$(echo "$auth_resp" | json_get token)
    BESZEL_USER_ID=$(echo "$auth_resp" | json_path record.id)
    if [[ -z "$BESZEL_TOKEN" ]]; then
        log_warn "Beszel auth returned no token"
        return 1
    fi
    return 0
}

# Reads a systems list from stdin and prints "<state> <id>" for the record named
# MediaStack: none, current (the socket), legacy (exactly MediaStack's old
# host.docker.internal:45876) or other (anything else, which is user state).
_beszel_local_system_state() {
    BESZEL_SOCKET="$BESZEL_LOCAL_SOCKET" python3 -c '
import os, sys, json
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    print("unreadable -")
    sys.exit(0)
for it in items:
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
    systems_resp=$(curl_header_stdin "Authorization" "Bearer $BESZEL_TOKEN" -sS "$hub_url/api/collections/systems/records" \
        2>/dev/null)
    read -r state record_id < <(_beszel_local_system_state <<<"$systems_resp")

    local body code out
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
            out=$(curl_header_data_stdin "Authorization" "Bearer $BESZEL_TOKEN" "$body" \
                -sS -X PATCH "$hub_url/api/collections/systems/records/$record_id" \
                -H "Content-Type: application/json" \
                -w "\n%{http_code}" 2>/dev/null)
            code="${out##*$'\n'}"
            if [[ "$code" =~ ^2 ]]; then
                log_ok "Beszel system 'MediaStack' moved from host.docker.internal:45876 to the agent's unix socket"
                BESZEL_SYSTEM_MOVED=true
                return 0
            fi
            log_warn "Beszel system migration returned HTTP $code: ${out:0:200}"
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
    out=$(curl_header_data_stdin "Authorization" "Bearer $BESZEL_TOKEN" "$body" \
        -sS -X POST "$hub_url/api/collections/systems/records" \
        -H "Content-Type: application/json" \
        -w "\n%{http_code}" 2>/dev/null)
    code="${out##*$'\n'}"
    if [[ "$code" =~ ^2 ]]; then
        log_ok "Beszel system 'MediaStack' registered"
        return 0
    fi
    out="${out%$'\n'*}"
    log_warn "Beszel system registration returned HTTP $code: ${out:0:200}"
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
    local su_body su_code
    su_body=$(http_json_body identity "$admin_email" password "$admin_pw")
    su_code=$(curl_data_stdin "$su_body" -s -o /dev/null -w "%{http_code}" \
        -X POST "$hub_url/api/collections/_superusers/auth-with-password" \
        -H "Content-Type: application/json" 2>/dev/null || echo "000")
    if [[ "$su_code" == "200" ]]; then
        log_skip "Beszel superuser already present"
    elif docker exec beszel /beszel superuser upsert "$admin_email" "$admin_pw" >/dev/null 2>&1; then
        log_ok "Beszel superuser ensured"
    else
        log_warn "Could not upsert Beszel superuser"
    fi

    # --- 1. Authenticate to hub ---
    _beszel_login "$hub_url" "$admin_email" "$admin_pw" || return 0
    log_ok "Beszel hub authenticated"

    # --- 2. Get SSH key from hub ---
    local key_resp hub_key
    key_resp=$(curl_header_stdin "Authorization" "Bearer $BESZEL_TOKEN" -sS "$hub_url/api/beszel/getkey" \
        2>/dev/null)
    hub_key=$(echo "$key_resp" | json_get key)

    if [[ -z "$hub_key" ]]; then
        log_warn "Could not retrieve Beszel agent key"
        return 0
    fi

    # --- 3. Save key to .env if changed ---
    local current_key="${BESZEL_AGENT_KEY:-}"
    if [[ "$current_key" == "$hub_key" ]]; then
        log_skip "Beszel agent key already in .env"
    else
        env_save_api_key "BESZEL_AGENT_KEY" "$hub_key"

        # --- 4. Recreate agent so it picks up the new KEY ---
        log_info "Recreating beszel-agent with SSH key..."
        docker compose up -d beszel-agent >/dev/null 2>&1
        log_ok "Beszel agent restarted with key"
    fi

    # --- 5. Register this host as a monitored system (or move the old entry) ---
    beszel_sync_local_system "$hub_url" || true
}

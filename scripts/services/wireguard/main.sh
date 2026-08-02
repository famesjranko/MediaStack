# =============================================================================
# WireGuard (wg-easy v15) — initial peer + per-client firewall configuration
# =============================================================================

configure_wireguard() {
    if ! container_running wireguard; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}Configuring WireGuard...${NC}"

    local wg_url
    wg_url="$(service_local_url wireguard)"
    local wg_user="${JELLYFIN_ADMIN_USER:-admin}"
    local wg_pw="${JELLYFIN_ADMIN_PASSWORD:-}"
    local per_client_fw_raw="${WG_PER_CLIENT_FIREWALL:-true}"
    local per_client_fw="true"
    local access_tier="${WG_ACCESS_TIER:-full-lan}"
    local lan_cidr="${WG_LAN_CIDR:-}"
    local server_lan_ip="${WG_SERVER_LAN_IP:-${HOST_ADDRESS:-}}"

    if [[ -z "$wg_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set in .env - skipping WireGuard"
        return 0
    fi

    case "${per_client_fw_raw,,}" in
        false) per_client_fw="false" ;;
        true | "") per_client_fw="true" ;;
        *)
            log_warn "WG_PER_CLIENT_FIREWALL='$per_client_fw_raw' is not valid; defaulting to true so access tiers stay enforced."
            per_client_fw="true"
            ;;
    esac

    # Sanity check: WG_PER_CLIENT_FIREWALL=false is the documented escape hatch
    # for users who set WG_INIT_ALLOWED_IPS='0.0.0.0/0, ::/0' to enable full
    # tunnel. Pairing it with a restrictive tier silently neutralizes the
    # tier's server-side enforcement, which is almost certainly user error.
    if [[ "$per_client_fw" == "false" && "$access_tier" != "full-lan" ]]; then
        log_warn "WG_PER_CLIENT_FIREWALL=false with tier '$access_tier' disables server-side enforcement - peers reach more than the tier implies."
        log_warn "For a full tunnel, set WG_INIT_ALLOWED_IPS='0.0.0.0/0, ::/0' instead."
    fi

    # Readiness probe. v15 has no /api/health; use GET /api/client with Basic
    # Auth. 200 = initialized + creds correct. 401 = initialized but UI password
    # was changed (do not auto-reconcile). Anything else = not ready yet.
    local probe_code attempts=0 max_attempts=30
    while ((attempts < max_attempts)); do
        probe_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "$wg_user:$wg_pw" "$wg_url/api/client" 2>/dev/null || echo "000")
        case "$probe_code" in
            200) break ;;
            401)
                log_warn "wg-easy rejected Basic Auth for '$wg_user' - UI password may have been changed; skipping configurator"
                return 0
                ;;
            *)
                sleep 2
                attempts=$((attempts + 1))
                ;;
        esac
    done
    if [[ "$probe_code" != "200" ]]; then
        log_warn "wg-easy did not become ready within $((max_attempts * 2))s - skipping configurator"
        return 0
    fi

    if [[ "$per_client_fw" == "true" ]]; then
        _wg_ensure_firewall_enabled "$wg_url" "$wg_user" "$wg_pw" || return 1
    fi

    local clients_json peer_id
    clients_json=$(curl -sf -u "$wg_user:$wg_pw" "$wg_url/api/client" 2>/dev/null || echo "[]")
    peer_id=$(echo "$clients_json" | WG_PEER="$wg_user" python3 -c '
import os, sys, json
peer = os.environ["WG_PEER"]
try:
    clients = json.load(sys.stdin)
except Exception:
    clients = []
for c in clients:
    if c.get("name") == peer:
        print(c.get("id", ""))
        break
' 2>/dev/null || echo "")

    if [[ -n "$peer_id" ]]; then
        log_skip "WireGuard peer '$wg_user' already exists"
    else
        peer_id=$(_wg_create_peer "$wg_url" "$wg_user" "$wg_pw" "$wg_user") || peer_id=""
        if [[ -z "$peer_id" ]]; then
            log_warn "WireGuard peer creation failed"
            return 0
        fi
        log_ok "WireGuard peer '$wg_user' created (manage at http://<lan-ip>:51821)"
    fi

    # Per-client firewall on by default. Initial peer's firewallIps come from
    # the access tier chosen during the Stage-2 wizard (full-lan / server /
    # containers). The streaming / streaming-requests tiers are README copy-paste
    # templates for family peers added in the wg-easy UI, not initial-peer tiers.
    if [[ "$per_client_fw" == "true" && -n "$peer_id" ]]; then
        local tier_ips
        if tier_ips=$(wg_firewall_ips_for_tier "$access_tier" "$lan_cidr" "$server_lan_ip"); then
            _wg_set_peer_firewall_ips "$wg_url" "$wg_user" "$wg_pw" "$peer_id" "$tier_ips" || return 1
        else
            log_warn "WG_ACCESS_TIER='$access_tier' missing required env - initial peer left restricted."
            log_warn "Set WG_LAN_CIDR (full-lan) or WG_SERVER_LAN_IP (other tiers) in .env, then re-run."
            return 1
        fi
    fi
}

_wg_ensure_firewall_enabled() {
    local url="$1" user="$2" pw="$3"
    local current already

    current=$(curl -sf -u "$user:$pw" "$url/api/admin/interface" 2>/dev/null || echo "{}")
    already=$(echo "$current" | python3 -c '
import sys, json
try: print("yes" if json.load(sys.stdin).get("firewallEnabled") else "no")
except: print("unknown")
' 2>/dev/null)
    if [[ "$already" == "yes" ]]; then
        log_skip "wg-easy per-client firewall already enabled"
        return 0
    fi

    local body http
    body=$(python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
d["firewallEnabled"] = True
print(json.dumps(d))' <<<"$current")
    http=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$user:$pw" -X POST "$url/api/admin/interface" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null || echo "000")

    # v15.3.0 can return 500 here while still persisting firewallEnabled=true
    # (ip6tables touched during firewall chain setup even with DISABLE_IPV6).
    # Always re-read state; classify on read-back, not on the POST exit code.
    sleep 1
    current=$(curl -sf -u "$user:$pw" "$url/api/admin/interface" 2>/dev/null || echo "{}")
    already=$(echo "$current" | python3 -c '
import sys, json
try: print("yes" if json.load(sys.stdin).get("firewallEnabled") else "no")
except: print("unknown")
' 2>/dev/null)

    case "$http:$already" in
        2*:yes) log_ok "wg-easy per-client firewall enabled" ;;
        *:yes) log_warn "wg-easy per-client firewall enable returned HTTP $http but state persisted as enabled" ;;
        *)
            log_warn "wg-easy per-client firewall enable failed (HTTP $http, state=$already)"
            return 1
            ;;
    esac
}

_wg_create_peer() {
    local url="$1" user="$2" pw="$3" name="$4"
    local body resp_file http peer_id

    body=$(WG_PEER="$name" python3 -c '
import os, json
print(json.dumps({"name": os.environ["WG_PEER"], "expiresAt": None}))')
    resp_file=$(mktemp)
    http=$(curl -s -o "$resp_file" -w "%{http_code}" \
        -u "$user:$pw" -X POST "$url/api/client" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null || echo "000")

    case "$http" in
        200 | 201)
            peer_id=$(RESP_FILE="$resp_file" python3 -c '
import os
import json, sys
try:
    with open(os.environ["RESP_FILE"]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    pid = d.get("id") or (d.get("client", {}) if isinstance(d.get("client"), dict) else {}).get("id", "")
    if pid:
        print(pid)
' 2>/dev/null || true)
            rm -f "$resp_file"
            if [[ -n "$peer_id" ]]; then
                printf '%s\n' "$peer_id"
                return 0
            fi
            # Some v15 builds return success without the created client id.
            # Fall through to the same read-back path used for committed 500s.
            ;;
        *)
            rm -f "$resp_file"
            ;;
    esac

    # When the per-client firewall is enabled, v15.3.0 may persist the peer and
    # then fail while rebuilding firewall rules. Other successful responses may
    # omit the created id. Read back by name in both cases so committed state is
    # not treated as a hard failure.
    sleep 1
    curl -sf -u "$user:$pw" "$url/api/client" 2>/dev/null | WG_PEER="$name" python3 -c '
import os, sys, json
peer = os.environ["WG_PEER"]
try:
    clients = json.load(sys.stdin)
except Exception:
    clients = []
for c in clients:
    if c.get("name") == peer:
        pid = c.get("id", "")
        if pid != "":
            print(pid)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null && return 0
    return 1
}

_wg_set_peer_firewall_ips() {
    local url="$1" user="$2" pw="$3" peer_id="$4" firewall_ips="$5"
    local current body desired_json http persisted

    current=$(curl -sf -u "$user:$pw" "$url/api/client/$peer_id" 2>/dev/null) || {
        log_warn "Could not read peer $peer_id to set firewallIps"
        return 1
    }

    desired_json=$(IPS="$firewall_ips" python3 -c '
import os, json
entries = [x.strip() for x in os.environ["IPS"].split(",") if x.strip()]
print(json.dumps(entries))')

    body=$(IPS_JSON="$desired_json" python3 -c '
import os, sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit("bad json from peer GET")
d["firewallIps"] = json.loads(os.environ["IPS_JSON"])
print(json.dumps(d))' <<<"$current")

    http=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$user:$pw" -X POST "$url/api/client/$peer_id" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null || echo "000")

    sleep 1
    current=$(curl -sf -u "$user:$pw" "$url/api/client/$peer_id" 2>/dev/null || echo "{}")
    persisted=$(IPS_JSON="$desired_json" python3 -c '
import os, sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("unknown")
    sys.exit(0)
want = json.loads(os.environ["IPS_JSON"])
got = d.get("firewallIps") or []
# Exact set equality, not subset — a stray broader entry (0.0.0.0/0, race with
# UI edit, future API merge semantics) would silently neutralize the tier.
print("yes" if set(got) == set(want) else "no")
' <<<"$current" 2>/dev/null || echo "unknown")

    case "$http:$persisted" in
        2*:yes) log_ok "Initial peer firewallIps set to '$firewall_ips'" ;;
        *:yes) log_warn "Setting initial peer firewallIps returned HTTP $http but state persisted" ;;
        *)
            log_warn "Setting initial peer firewallIps failed (HTTP $http, state=$persisted)"
            return 1
            ;;
    esac
}

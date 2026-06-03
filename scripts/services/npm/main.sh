# =============================================================================
# 8. Nginx Proxy Manager — seed admin, create proxy hosts for all services
# =============================================================================

# --- Cert identity vs cert usability -------------------------------------
#
# NPM's certificate table can list a row whose certbot run failed mid-flight,
# leaving "issued in NPM but never on disk." Publishing a proxy host with
# such a cert_id returns 2xx from the API but produces no `proxy_host/N.conf`
# and no nginx vhost — surfacing as "TLS unrecognized name" on the public
# hostname. So "what NPM knows about" and "what we can actually serve" are
# different questions, and we keep them as separate helpers.
#
#   _npm_api_cert_id_by_fqdn    — pure NPM/API view (highest non-deleted id)
#   _npm_cert_material_ready    — disk truth (key + chain present?)
#   _npm_usable_cert_id_by_fqdn — composition (use this for target_cert_id)
#
# Anywhere we pick `target_cert_id`, prefer the composition. The narrower
# helpers are reserved for places that genuinely need only one view, and
# named loudly so future readers don't accidentally trust DB-only state.

if ! type npm_remote_hosts_ready >/dev/null 2>&1; then
    source "$SCRIPT_DIR/scripts/lib/npm_remote.sh"
fi

# ALL non-deleted cert ids matching this FQDN, NEWEST FIRST. Used by
# _npm_usable_cert_id_by_fqdn to iterate from newest down to oldest. The
# max-id-only variant masks a usable older cert when a newer not-yet-on-disk
# row has been allocated — i.e. exactly the "first POST is still finishing,
# someone POSTed again, NPM allocated a new id, our adopt-newest-only
# helper now hides the ready cert and we POST a third time" amplifier.
#
# Returns:
#   0 + ids on stdout (one per line, may be empty)
#   2 if the API call itself failed (timeout / connection / 5xx) — caller
#     MUST distinguish this from "no matching certs" and not assume the
#     fqdn has no certs in flight.
_npm_api_cert_ids_by_fqdn() {
    npm_remote_api_cert_ids_by_fqdn "$@"
}

# Highest cert id NPM knows about for this FQDN, regardless of whether the
# key+chain are on disk yet. Used to detect "a cert request is in flight"
# when we have to decide whether to POST another one.
# Same return convention as _npm_api_cert_ids_by_fqdn (rc=2 on API error).
_npm_latest_cert_id_by_fqdn() {
    local _ids _rc
    _ids=$(_npm_api_cert_ids_by_fqdn "$@")
    _rc=$?
    (( _rc == 2 )) && return 2
    echo "$_ids" | head -n1
}

_npm_cert_material_ready() {
    npm_remote_cert_material_ready "$@"
}

# Highest-id cert for this FQDN whose key+chain are on disk. Iterates newest
# first; never masks an older usable cert behind a newer in-flight one.
# Returns rc=2 on API error so callers can refuse to POST while blind.
_npm_usable_cert_id_by_fqdn() {
    npm_remote_usable_cert_id_by_fqdn "$@"
}

# Is certbot currently running inside the NPM container? Used to refuse
# starting a second issuance for the same FQDN while one is in flight.
# We check the global certbot lock (/var/lib/letsencrypt/.certbot.lock).
# Stale lock files would be a false-positive risk, but on the NPM image
# the lock is opened with flock() and released on process exit, so a
# leftover file that's not actually locked is treated as "busy" too —
# which is the safe default for our use case (we'd rather wait an extra
# poll than burn an LE cert).
_npm_certbot_busy() {
    docker exec npm test -e /var/lib/letsencrypt/.certbot.lock >/dev/null 2>&1
}

# Long poll: wait up to ~max_polls × interval seconds for a cert with
# disk material to appear for FQDN. Defaults: 120 × 10s = 20 min.
# Returns 0 + cert_id on stdout when found; rc=1 on timeout.
# Critically, rc=2 means the API was unreachable for the entire window,
# so caller knows nothing about whether a cert is in flight.
_npm_wait_usable_cert() {
    local _token="$1" _api="$2" _fqdn="$3"
    local _max="${4:-120}" _interval="${5:-10}"
    local _i _id _rc _api_ok=0
    for _i in $(seq 1 "$_max"); do
        _id=$(_npm_usable_cert_id_by_fqdn "$_token" "$_api" "$_fqdn")
        _rc=$?
        if (( _rc == 0 )); then
            _api_ok=1
            if [[ -n "$_id" && "$_id" != "0" ]]; then
                echo "$_id"
                return 0
            fi
        fi
        sleep "$_interval"
    done
    (( _api_ok == 0 )) && return 2
    return 1
}

# --- Proxy-host rendered-state truth -------------------------------------
#
# NPM accepts publication API calls (PUT/POST proxy-hosts) with a cert_id
# that has no key+chain on disk: the API returns 2xx but does not write
# `proxy_host/$id.conf`, leaving an "enabled in DB, invisible to nginx"
# host that survives every idempotent re-run because the row matches the
# desired JSON. The truth source we actually trust is the rendered .conf
# under config/npm/data/nginx/proxy_host/. _npm_proxy_conf_renders verifies
# the file exists and references the (FQDN, cert_id) we expect.

_npm_proxy_conf_renders() {
    npm_remote_proxy_conf_renders "$@"
}

# Wait for NPM to render `proxy_host/$host_id.conf` with the expected
# (FQDN, cert_id). NPM writes asynchronously after API returns 2xx.
_npm_wait_proxy_conf() {
    local _host_id="$1" _fqdn="$2" _cert_id="${3:-0}"
    local _max="${4:-15}" _interval="${5:-1}"
    local _i
    for _i in $(seq 1 "$_max"); do
        if _npm_proxy_conf_renders "$_host_id" "$_fqdn" "$_cert_id"; then
            return 0
        fi
        sleep "$_interval"
    done
    return 1
}

_npm_cert_status_path() {
    printf '%s\n' "$SCRIPT_DIR/config/state/npm-cert-status-last.json"
}

_npm_cert_status_init() {
    local _domain="$1" _path
    _path=$(_npm_cert_status_path)
    mkdir -p "$(dirname "$_path")"
    DOMAIN_NAME="$_domain" STATUS_PATH="$_path" python3 -c '
import json
import os
import pathlib
import time

path = pathlib.Path(os.environ["STATUS_PATH"])
data = {
    "version": 1,
    "domain": os.environ["DOMAIN_NAME"],
    "started_at": int(time.time()),
    "hosts": [],
}
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
'
}

_npm_cert_status_record() {
    local _fqdn="$1" _post_attempted="$2" _post_http="$3" _latest_cert_id="$4" _target_cert_id="$5" _usable_cert="$6" _proxy_published="$7" _host_id="$8" _outcome="$9"
    local _path
    _path=$(_npm_cert_status_path)
    mkdir -p "$(dirname "$_path")"
    STATUS_PATH="$_path" FQDN="$_fqdn" POST_ATTEMPTED="$_post_attempted" POST_HTTP="$_post_http" \
        LATEST_CERT_ID="$_latest_cert_id" TARGET_CERT_ID="$_target_cert_id" USABLE_CERT="$_usable_cert" \
        PROXY_PUBLISHED="$_proxy_published" HOST_ID="$_host_id" OUTCOME="$_outcome" python3 -c '
import json
import os
import pathlib
import time

path = pathlib.Path(os.environ["STATUS_PATH"])
try:
    data = json.loads(path.read_text())
except Exception:
    data = {"version": 1, "hosts": []}

fqdn = os.environ["FQDN"]
record = {
    "fqdn": fqdn,
    "recorded_at": int(time.time()),
    "post_attempted": os.environ["POST_ATTEMPTED"] == "true",
    "post_http": os.environ["POST_HTTP"],
    "latest_cert_id": os.environ["LATEST_CERT_ID"],
    "target_cert_id": os.environ["TARGET_CERT_ID"],
    "usable_cert": os.environ["USABLE_CERT"] == "true",
    "proxy_published": os.environ["PROXY_PUBLISHED"] == "true",
    "host_id": os.environ["HOST_ID"],
    "outcome": os.environ["OUTCOME"],
}
hosts = [h for h in data.get("hosts", []) if h.get("fqdn") != fqdn]
hosts.append(record)
data["hosts"] = hosts
data["updated_at"] = int(time.time())
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
'
}

# Disable a proxy host in NPM: enabled=False, cert_id=0. Used as the
# postcondition rollback when a publish call returns 2xx but the .conf
# never materialises (orphan cert_id with no key+chain on disk).
_npm_disable_host() {
    local _token="$1" _api="$2" _host_id="$3" _host_json="${4:-}"
    if [[ -z "$_host_json" ]]; then
        _host_json=$(curl -sf --max-time 10 -H "Authorization: Bearer $_token" \
            "$_api/nginx/proxy-hosts/$_host_id" 2>/dev/null) || return 1
    fi
    local _body
    _body=$(echo "$_host_json" | python3 -c '
import sys, json
h = json.load(sys.stdin)
h["enabled"] = False
h["certificate_id"] = 0
h["ssl_forced"] = False
h["http2_support"] = False
for k in ("id","created_on","modified_on","owner_user_id","owner",
          "use_default_location","ipv6"):
    h.pop(k, None)
print(json.dumps(h))
' 2>/dev/null)
    curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X PUT \
        "$_api/nginx/proxy-hosts/$_host_id" \
        -H "Authorization: Bearer $_token" \
        -H "Content-Type: application/json" \
        -d "$_body"
}

# Wait until NPM's API responds quickly (i.e. it isn't blocked on a synchronous
# certbot run). NPM serves API requests from the same Node process that drives
# certbot, so a previous cert request can leave the API "warm but slow". A
# cheap GET /api before the next POST keeps cert issuances from overlapping.
_npm_wait_idle() {
    local _token="$1" _api="$2" _max="${3:-12}"
    local _i
    for _i in $(seq 1 "$_max"); do
        if curl -sf --max-time 3 -H "Authorization: Bearer $_token" \
            "$_api" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

_npm_container_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' npm 2>/dev/null || echo false)" == "true" ]]
}

_npm_host_path_from_container_path() {
    local _container_path="$1"
    case "$_container_path" in
        /etc/letsencrypt/*)
            printf '%s\n' "$SCRIPT_DIR/config/npm/letsencrypt/${_container_path#/etc/letsencrypt/}"
            ;;
        /data/*)
            printf '%s\n' "$SCRIPT_DIR/config/npm/data/${_container_path#/data/}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Pre-flight self-heal for proxy_host/N.conf vs cert-disk drift.
#
# The corruption signal is `docker exec npm nginx -t` failing — NOT API
# slowness (that's _npm_wait_idle's domain). Drift sources include: a cert
# row deleted while proxy_host still references it, a configure.sh aborted
# mid-cert-issue, an OOM kill, or a VM reboot during a certbot run.
#
# Repair is keyed on affected proxy_host id (the .conf file references a
# missing cert path), not on "deleted cert row" — the durable symptom is the
# disk reference itself, regardless of why the cert is gone.
#
# Order: API-side repair first (cheaper, idempotent). If that doesn't heal
# nginx -t, stop NPM once, patch sqlite + move broken .conf aside, start NPM.
# One restart max. .conf files are archived (not deleted) for forensics.
# The drift scan uses the host-mounted letsencrypt/data paths so we can still
# recover when the NPM container is stopped or crash-looping.
_npm_ensure_healthy() {
    local _email="$1" _pw="$2"
    local _npm_running="false"

    # Use sudo for read/write to the NPM data tree only when we are not
    # already root. NPM writes its files as root from inside the container,
    # so on a normal host (configure.sh as a regular user) we need sudo to
    # archive the .conf and patch the sqlite DB. In environments where the
    # caller is already root (the DinD test runner, container-based setups,
    # systemd-services running as root), `sudo` is often not even installed.
    local _sudo=""
    [[ $(id -u) -ne 0 ]] && _sudo="sudo"

    # Fast path: nginx config valid → nothing to do.
    if _npm_container_running; then
        _npm_running="true"
        if docker exec npm nginx -t >/dev/null 2>&1; then
            return 0
        fi
    else
        log_warn "NPM container is not running — checking for proxy_host config drift before restart"
    fi

    log_warn "NPM nginx -t failing — checking for proxy_host config drift"

    local _data_dir="$SCRIPT_DIR/config/npm/data"
    local _affected=()
    local _conf _ref _host_id _host_ref

    # Each .conf is keyed by host_id.conf. Find the ones that reference cert
    # files missing from the host-mounted letsencrypt tree.
    for _conf in "$_data_dir"/nginx/proxy_host/*.conf; do
        [[ -f "$_conf" ]] || continue
        _host_id=$(basename "$_conf" .conf)
        local _has_missing="false"
        while IFS= read -r _ref; do
            [[ -z "$_ref" ]] && continue
            if ! _host_ref=$(_npm_host_path_from_container_path "$_ref"); then
                log_warn "  host $_host_id references unmanaged path $_ref"
                continue
            fi
            if ! $_sudo test -f "$_host_ref" 2>/dev/null; then
                _has_missing="true"
                log_info "  host $_host_id references missing $_ref ($_host_ref)"
            fi
        done < <($_sudo grep -oP "ssl_certificate(_key)?\s+\K[^;]+" "$_conf" 2>/dev/null | sort -u)
        [[ "$_has_missing" == "true" ]] && _affected+=("$_host_id")
    done

    if (( ${#_affected[@]} == 0 )); then
        log_error "NPM nginx -t failing but no proxy_host/*.conf has missing cert refs"
        log_error "Unknown corruption — inspect: docker exec npm nginx -t"
        log_error "Forensic: $_data_dir/nginx/proxy_host/"
        return 1
    fi

    log_warn "Drifted host(s): ${_affected[*]} — attempting API repair first"

    # Stage 1: API repair. PUT each affected host to enabled=false cert=0.
    # NPM regenerates the .conf on PUT, so this is usually enough.
    local _token
    _token=""
    if [[ "$_npm_running" == "true" ]]; then
        _token=$(curl -sf --max-time 5 -X POST "http://localhost:81/api/tokens" \
            -H "Content-Type: application/json" \
            -d "$(json_body identity "$_email" secret "$_pw")" 2>/dev/null | json_get token)
    fi

    if [[ -n "$_token" ]]; then
        local _host_json _body _hc
        for _host_id in "${_affected[@]}"; do
            _host_json=$(curl -sf --max-time 10 \
                -H "Authorization: Bearer $_token" \
                "http://localhost:81/api/nginx/proxy-hosts/$_host_id" 2>/dev/null)
            [[ -z "$_host_json" ]] && continue
            _body=$(echo "$_host_json" | python3 -c '
import sys, json
h = json.load(sys.stdin)
h["enabled"] = False
h["certificate_id"] = 0
h["ssl_forced"] = False
h["http2_support"] = False
for k in ("id","created_on","modified_on","owner_user_id","owner",
          "use_default_location","ipv6"):
    h.pop(k, None)
print(json.dumps(h))
' 2>/dev/null)
            _hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X PUT \
                "http://localhost:81/api/nginx/proxy-hosts/$_host_id" \
                -H "Authorization: Bearer $_token" \
                -H "Content-Type: application/json" \
                -d "$_body")
            log_info "  API: host $_host_id PUT enabled=false cert=0 (HTTP $_hc)"
        done
        if docker exec npm nginx -t >/dev/null 2>&1; then
            log_ok "NPM healed via API repair (nginx -t passes)"
            return 0
        fi
        log_warn "API repair didn't heal nginx — falling back to offline patch"
    else
        if [[ "$_npm_running" == "true" ]]; then
            log_warn "No NPM API token available — skipping API repair, going offline"
        else
            log_warn "NPM container not running — skipping API repair, going offline"
        fi
    fi

    # Stage 2: offline repair. Stop NPM, patch sqlite via host python3, archive
    # broken .conf, start NPM exactly once.
    log_warn "Stopping NPM for offline sqlite patch"
    (cd "$SCRIPT_DIR" && docker compose stop npm) >/dev/null 2>&1

    local _db="$_data_dir/database.sqlite"
    if [[ ! -f "$_db" ]]; then
        log_error "$_db not found — cannot patch DB"
        (cd "$SCRIPT_DIR" && docker compose start npm) >/dev/null 2>&1
        return 1
    fi

    # Patch sqlite via python3 stdlib — no host sqlite3 binary required, no
    # docker image pull. NPM image does not ship the sqlite3 CLI either, so
    # this is the most portable path. NPM's database.sqlite is owned by root
    # (the container writes as root), so we need sudo to open it for write.
    local _ids_csv
    _ids_csv=$(IFS=,; echo "${_affected[*]}")
    if ! $_sudo python3 -c '
import sqlite3, sys

db_path = sys.argv[1]
ids = [int(x) for x in sys.argv[2].split(",") if x]
if not ids:
    raise SystemExit("no host ids supplied")

placeholders = ",".join("?" for _ in ids)
con = sqlite3.connect(db_path)
try:
    found = {
        row[0]
        for row in con.execute(f"SELECT id FROM proxy_host WHERE id IN ({placeholders})", ids)
    }
    missing = [host_id for host_id in ids if host_id not in found]
    if missing:
        raise SystemExit(f"missing proxy_host row(s): {missing}")

    con.execute(
        f"UPDATE proxy_host SET enabled=0, certificate_id=0, ssl_forced=0, http2_support=0 "
        f"WHERE id IN ({placeholders})",
        ids,
    )
    con.commit()

    rows = list(
        con.execute(
            f"SELECT id, enabled, certificate_id, ssl_forced, http2_support "
            f"FROM proxy_host WHERE id IN ({placeholders})",
            ids,
        )
    )
    bad = [row for row in rows if tuple(row[1:]) != (0, 0, 0, 0)]
    if bad:
        raise SystemExit(f"post-update verification failed: {bad}")
    if len(rows) != len(ids):
        raise SystemExit(f"expected {len(ids)} rows after update, got {len(rows)}")

    print(f"rows_verified={len(rows)}", file=sys.stderr)
finally:
    con.close()
' "$_db" "$_ids_csv"
    then
        log_error "sqlite patch via python3 failed (need sudo for $_db)"
        (cd "$SCRIPT_DIR" && docker compose start npm) >/dev/null 2>&1
        return 1
    fi
    log_info "  sqlite: host(s) ${_affected[*]} → enabled=0 cert=0"

    # Archive the broken .conf for forensics; do not delete.
    local _ts _archive
    _ts=$(date +%Y%m%d-%H%M%S)
    _archive="$_data_dir/nginx/proxy_host.broken-$_ts"
    $_sudo mkdir -p "$_archive" 2>/dev/null
    for _host_id in "${_affected[@]}"; do
        local _src="$_data_dir/nginx/proxy_host/$_host_id.conf"
        if [[ -f "$_src" ]]; then
            $_sudo mv "$_src" "$_archive/" 2>/dev/null && \
                log_info "  archived $_host_id.conf → $_archive/"
        fi
    done

    log_info "Starting NPM"
    (cd "$SCRIPT_DIR" && docker compose start npm) >/dev/null 2>&1

    # Both green before we let configure_npm proceed. The /api/tokens probe
    # specifically exercises the express backend (POST + body parse + auth
    # router) — `GET /api` alone can succeed via nginx while express is still
    # initialising, which then surfaces as HTTP 502 on the very next call.
    # We accept any non-5xx response (200, 400, 401) as "express is alive".
    local _i _probe_http
    for _i in $(seq 1 30); do
        if docker exec npm nginx -t >/dev/null 2>&1; then
            _probe_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
                -X POST "http://localhost:81/api/tokens" \
                -H "Content-Type: application/json" \
                -d '{"identity":"_probe","secret":"_probe"}' 2>/dev/null)
            if [[ -n "$_probe_http" && "$_probe_http" =~ ^[1-4] ]]; then
                log_ok "NPM healed (nginx -t clean, express alive — probe HTTP $_probe_http)"
                return 0
            fi
        fi
        sleep 2
    done

    log_error "NPM still unhealthy after offline repair — manual review needed"
    log_error "Forensic: $_archive"
    return 1
}

_npm_warn_stale_managed_hosts() {
    local _npm_token="$1" _npm_api="$2" _domain="$3" _existing_hosts="$4"
    : "$_npm_token" "$_npm_api"
    [[ -z "$_domain" || "$_domain" == "example.com" ]] && return 0

    local _stale_hosts
    _stale_hosts=$(echo "$_existing_hosts" | DOMAIN="$_domain" python3 -c '
import sys, json, os
domain = os.environ["DOMAIN"]
try:
    hosts = json.load(sys.stdin)
except Exception:
    hosts = []
stale = []
for host in hosts:
    for name in host.get("domain_names", []) or []:
        if not (name.startswith("jellyfin.") or name.startswith("jellyseerr.")):
            continue
        suffix = name.split(".", 1)[1] if "." in name else ""
        if suffix and suffix != domain:
            stale.append(name)
if stale:
    print(", ".join(sorted(set(stale))))
' 2>/dev/null)

    if [[ -n "$_stale_hosts" ]]; then
        log_warn "NPM has proxy hosts for a different domain. MediaStack will warn only and will not delete or rewrite them automatically. Stale managed hosts: $_stale_hosts"
    fi
    return 0
}

configure_npm() {
    echo ""
    echo -e "${BOLD}Configuring Nginx Proxy Manager...${NC}"

    local npm_api="http://localhost:81/api"
    local npm_email="${NPM_ADMIN_EMAIL:-}"
    local npm_pw="${JELLYFIN_ADMIN_PASSWORD:-}"

    if [[ -z "$npm_email" ]]; then
        log_warn "NPM_ADMIN_EMAIL not set in .env — skipping NPM."
        return 0
    fi
    if [[ -z "$npm_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set in .env — skipping NPM."
        return 0
    fi

    # Pre-flight: heal nginx-config drift left by prior interrupted runs.
    # No-op on healthy NPM; bounded recovery (one restart max) when broken.
    _npm_ensure_healthy "$npm_email" "$npm_pw" || {
        log_error "NPM is in an unrecoverable state — aborting NPM configuration"
        return 1
    }

    # NPM ships with an EMPTY user table on first boot. The well-known
    # 'admin@example.com / changeme' pair only exists after someone completes
    # the UI first-run flow. An unauthenticated POST /api/users succeeds
    # while no users exist — we use that to seed the admin directly with
    # the rotated credentials, so defaults are never active.

    # Build the create-user body via python json.dumps so special characters in
    # the password (", \, control chars) are escaped correctly. The previous
    # envsubst-into-template pattern was unsafe because envsubst substitutes
    # literally — a password containing " would have produced invalid JSON.
    local create_body create_http
    create_body=$(NPM_EMAIL="$npm_email" NPM_PW="$npm_pw" python3 -c '
import os, json
print(json.dumps({
    "name": "Administrator",
    "nickname": "Admin",
    "email": os.environ["NPM_EMAIL"],
    "roles": ["admin"],
    "is_disabled": False,
    "auth": {"type": "password", "secret": os.environ["NPM_PW"]},
}))')
    create_http=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$npm_api/users" \
        -H "Content-Type: application/json" \
        -d "$create_body")

    if [[ "$create_http" == "201" ]]; then
        log_ok "NPM admin created: $npm_email (password from .env)"
    elif [[ "$create_http" == "404" || "$create_http" == "409" || "$create_http" == "422" ]]; then
        # User exists — NPM returns 404 (endpoint closed after first user),
        # 409 (conflict), or 422 (validation) depending on version. Try to
        # rotate from the well-known defaults. If those are also rejected, we
        # assume the admin already has non-default credentials and skip.
        log_info "NPM admin already exists (HTTP $create_http). Checking rotation..."
        local default_token
        default_token=$(curl -sf -X POST "$npm_api/tokens" \
            -H "Content-Type: application/json" \
            -d "@$SCRIPT_DIR/scripts/services/npm/templates/token-default.json" 2>/dev/null | \
            json_get token)

        if [[ -z "$default_token" ]]; then
            log_skip "NPM admin already has non-default credentials"
        else
            local user_update_body rotate_body
            user_update_body=$(json_body name Administrator nickname Admin email "$npm_email")
            curl -sf -X PUT "$npm_api/users/me" \
                -H "Authorization: Bearer $default_token" \
                -H "Content-Type: application/json" \
                -d "$user_update_body" \
                >/dev/null 2>&1 || true

            rotate_body=$(json_body type password current changeme secret "$npm_pw")
            if curl -sf -X PUT "$npm_api/users/me/auth" \
                -H "Authorization: Bearer $default_token" \
                -H "Content-Type: application/json" \
                -d "$rotate_body" \
                >/dev/null 2>&1; then
                log_ok "NPM admin rotated from defaults to credentials in .env"
            else
                log_error "NPM password rotation FAILED - default creds may still work"
                return 1
            fi
        fi
    else
        log_error "NPM admin creation failed unexpectedly (HTTP $create_http) — re-run configure.sh"
        return 1
    fi

    # Authenticate to get a token for proxy host management.
    local npm_token tokens_body
    tokens_body=$(json_body identity "$npm_email" secret "$npm_pw")
    npm_token=$(curl -sf -X POST "$npm_api/tokens" \
        -H "Content-Type: application/json" \
        -d "$tokens_body" 2>/dev/null | \
        json_get token)
    if [[ -n "$npm_token" ]]; then
        log_ok "Verified: NPM admin credentials accepted"
    else
        log_error "NPM credentials not accepted post-setup — defaults may still be active"
        return 1
    fi

    # --- Default landing page hardening ---
    # NPM's default "Congratulations" page leaks that NPM is in use. Switch to 404.
    local default_site_settings default_site_value
    if default_site_settings=$(api_fetch "NPM settings" \
        -H "Authorization: Bearer $npm_token" "$npm_api/settings"); then
        default_site_value=$(echo "$default_site_settings" | python3 -c '
import sys, json
for s in json.load(sys.stdin):
    if s.get("id") == "default-site":
        print(s.get("value", ""))
        break
' 2>/dev/null)
        if [[ "$default_site_value" == "congratulations" ]]; then
            local ds_body ds_http
            ds_body=$(python3 -c 'import json; print(json.dumps({"value": "404", "meta": {}}))')
            ds_http=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "$npm_api/settings/default-site" \
                -H "Authorization: Bearer $npm_token" \
                -H "Content-Type: application/json" \
                -d "$ds_body")
            if [[ "$ds_http" =~ ^2 ]]; then
                log_ok "NPM default site: changed from 'congratulations' to '404'"
            else
                log_warn "NPM default site: PUT failed (HTTP $ds_http)"
            fi
        else
            log_skip "NPM default site: already set to '$default_site_value'"
        fi
    fi

    # --- Rate limiting zone (http{} context via NPM custom config) ---
    local rate_rps rate_burst
    rate_rps=$(cfg_field "rate_limiting.requests_per_second" 2>/dev/null || echo "15")
    rate_burst=$(cfg_field "rate_limiting.burst" 2>/dev/null || echo "60")

    local http_top_dir="$SCRIPT_DIR/config/npm/data/nginx/custom"
    local http_top_file="$http_top_dir/http_top.conf"
    local expected_zone="limit_req_zone \$binary_remote_addr zone=mediastack_ratelimit:10m rate=${rate_rps}r/s;"
    local http_top_created="false"

    if [[ -f "$http_top_file" ]]; then
        local current_content
        current_content=$(cat "$http_top_file")
        if [[ "$current_content" == "$expected_zone" ]]; then
            log_skip "NPM rate limit zone: ${rate_rps}r/s already configured"
        else
            log_warn "NPM rate limit zone: http_top.conf exists but content differs from config.yml (${rate_rps}r/s expected)"
        fi
    else
        # NPM container creates config/npm/data/nginx/ as root; fix ownership
        # so the non-root configure.sh user can write http_top.conf.
        if [[ -d "$http_top_dir" && ! -w "$http_top_dir" ]]; then
            sudo chown "$(id -u):$(id -g)" "$http_top_dir" 2>/dev/null || true
        fi
        if mkdir -p "$http_top_dir" 2>/dev/null && printf '%s\n' "$expected_zone" > "$http_top_file" 2>/dev/null; then
            http_top_created="true"
            log_ok "NPM rate limit zone: ${rate_rps}r/s (http_top.conf)"
        else
            log_warn "Could not create ${http_top_file} (permission denied?) — rate limiting disabled"
        fi
    fi

    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"
    local remote_ready="false"
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready="true"
    fi
    local remote_attempt_allowed="$remote_ready"
    if [[ "$remote_ready" != "true" && -n "$domain" && "$domain" != "example.com" && "${MEDIASTACK_NPM_ATTEMPT_REMOTE:-}" == "1" ]]; then
        remote_attempt_allowed="true"
        log_info "Stage 2 remote attempt allowed -- requesting/verifying public proxy hosts before REMOTE_WEB_STATE=ready"
    fi

    # Only proxy user-facing services (Jellyfin + Jellyseerr). Admin tools
    # (Sonarr, Radarr, Jackett, qBittorrent) stay LAN/VPN-only.
    # Fail2ban protects these via the NPM access log jail (401/403 responses).
    # subdomain|forward_host|forward_port|websocket(0/1)
    local proxy_hosts=(
        "jellyfin|jellyfin|8096|1"
        "jellyseerr|jellyseerr|5055|1"
    )

    local existing_hosts="[]"
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        if ! existing_hosts=$(api_fetch "NPM proxy hosts" -H "Authorization: Bearer $npm_token" "$npm_api/nginx/proxy-hosts"); then
            existing_hosts="[]"
        fi
        _npm_warn_stale_managed_hosts "$npm_token" "$npm_api" "$domain" "$existing_hosts"
    fi

    # --- Public proxy publication (requires REMOTE_WEB_STATE=ready) ---
    if [[ "$remote_attempt_allowed" == "true" ]]; then
        local fqdn_list=()
        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<< "$entry"
            fqdn_list+=("${subdomain}.${domain}")
        done

        # Disable any previously-created certless hosts before we wait on DNS or
        # attempt ACME. This closes the old exposure window on re-runs.
        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<< "$entry"
            local fqdn="${subdomain}.${domain}"
            local existing_host_json
            existing_host_json=$(echo "$existing_hosts" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
for host in json.load(sys.stdin):
    if fqdn in host.get("domain_names", []):
        print(json.dumps(host))
        break
' 2>/dev/null)
            [[ -z "$existing_host_json" ]] && continue

            local existing_cert_id existing_enabled
            existing_cert_id=$(echo "$existing_host_json" | json_get certificate_id 0)
            existing_enabled=$(echo "$existing_host_json" | json_get enabled False)
            if [[ "${existing_cert_id:-0}" == "0" && "$existing_enabled" =~ ^(True|true)$ ]]; then
                local disable_http
                disable_http=$(_npm_disable_host "$npm_token" "$npm_api" "$(echo "$existing_host_json" | json_get id)" "$existing_host_json")
                if [[ "$disable_http" =~ ^2 ]]; then
                    log_warn "Disabled certless proxy host: $fqdn until certificate issuance succeeds"
                else
                    log_warn "Could not disable certless proxy host: $fqdn (HTTP $disable_http)"
                fi
            fi
        done

        # --- DNS propagation gate ---
        # On first run the DDNS updater may not have propagated the new IP yet.
        # Let's Encrypt HTTP-01 will fail if the public hostnames still point
        # elsewhere. The gate compares getent ahosts vs the host's real public
        # IP. This is required for BOTH Let's Encrypt production and staging:
        # staging relaxes rate limits, but it still performs the normal public
        # DNS + HTTP-01 validation. Only truly custom/local ACME endpoints
        # (Pebble, internal CAs) should skip the public-DNS gate.
        local _le_server="${NPM_LE_SERVER:-}"
        local _needs_public_dns_gate="false"
        if [[ -z "$_le_server" || "$_le_server" == *"letsencrypt.org/directory" ]]; then
            _needs_public_dns_gate="true"
        fi

        local _public_ip="" _dns_ok=""
        if [[ "$_needs_public_dns_gate" != "true" ]]; then
            log_info "Custom ACME endpoint (${_le_server:-unset}) — skipping public DNS propagation gate"
        else
            _public_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null) || \
                _public_ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null) || \
                _public_ip=""
        fi

        if [[ -n "$_public_ip" ]]; then
            log_info "Public IP: $_public_ip — waiting for DNS propagation..."
            local _dns_wait=0 _dns_max=180 _dns_status_line=""
            while (( _dns_wait < _dns_max )); do
                local _all_dns_ok="yes"
                local _dns_status=()
                for fqdn in "${fqdn_list[@]}"; do
                    local _dns_ip
                    _dns_ip=$(getent ahosts "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')
                    if [[ "$_dns_ip" != "$_public_ip" ]]; then
                        _all_dns_ok=""
                        _dns_status+=("${fqdn}=${_dns_ip:-unresolvable}")
                    fi
                done
                _dns_status_line=$(IFS=', '; echo "${_dns_status[*]}")
                if [[ -n "$_all_dns_ok" ]]; then
                    _dns_ok="yes"
                    log_ok "DNS propagated: ${fqdn_list[*]} → $_public_ip (${_dns_wait}s)"
                    break
                fi
                sleep 10
                (( _dns_wait += 10 ))
                echo -ne "."
            done
            [[ -z "$_dns_ok" ]] && echo "" && \
                log_warn "DNS did not resolve to $_public_ip after ${_dns_max}s (${_dns_status_line:-unresolvable}) — public proxy hosts may be deferred"
        else
            log_info "Could not detect public IP — skipping DNS propagation check"
        fi

        # --- Certificate issuance + proxy publication ---
        _npm_cert_status_init "$domain"

        # Re-fetch after any disable operations so final writes start from fresh state.
        if ! existing_hosts=$(api_fetch "NPM proxy hosts (publish)" -H "Authorization: Bearer $npm_token" "$npm_api/nginx/proxy-hosts"); then
            existing_hosts="[]"
        fi
        local existing_certs
        if ! existing_certs=$(api_fetch "NPM certificates" -H "Authorization: Bearer $npm_token" "$npm_api/nginx/certificates"); then
            existing_certs="[]"
        fi

        for entry in "${proxy_hosts[@]}"; do
            IFS='|' read -r subdomain forward_host forward_port websocket <<< "$entry"
            local fqdn="${subdomain}.${domain}"
            local ws_val="false"
            [[ "$websocket" == "1" ]] && ws_val="true"

            local adv_config
            adv_config="limit_req zone=mediastack_ratelimit burst=${rate_burst} nodelay;
limit_req_status 429;
"'add_header X-Content-Type-Options "nosniff" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header Permissions-Policy "accelerometer=(), ambient-light-sensor=(), battery=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), microphone=()" always;'
            [[ "$subdomain" == "jellyfin" ]] && adv_config+=$'\nproxy_buffering off;'

            local host_json
            host_json=$(echo "$existing_hosts" | FQDN="$fqdn" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
for host in json.load(sys.stdin):
    if fqdn in host.get("domain_names", []):
        print(json.dumps(host))
        break
' 2>/dev/null)

            local host_id host_cert_id target_cert_id
            host_id=""
            host_cert_id="0"
            local cert_post_attempted="false" cert_post_http="" latest_cert_id="" cert_outcome="pending" proxy_published="false"
            if [[ -n "$host_json" ]]; then
                host_id=$(echo "$host_json" | json_get id)
                host_cert_id=$(echo "$host_json" | json_get certificate_id 0)
            fi

            # Site 1: existing host's cert_id. Adopt only when the cert
            # material is actually on disk — NPM may have a stale row from
            # a prior aborted issuance (orphan FK).
            target_cert_id="${host_cert_id:-0}"
            if [[ "${target_cert_id:-0}" != "0" ]] && \
               ! _npm_cert_material_ready "$target_cert_id"; then
                log_warn "Existing $fqdn cert_id=$target_cert_id has no key+chain on disk — re-issuing"
                target_cert_id="0"
            fi

            # Site 2: any pre-existing cert in NPM's list for this FQDN —
            # again gated on disk truth.
            if [[ "${target_cert_id:-0}" == "0" ]]; then
                target_cert_id=$(_npm_usable_cert_id_by_fqdn "$npm_token" "$npm_api" "$fqdn") || target_cert_id=""
            fi

            if [[ -z "$target_cert_id" || "$target_cert_id" == "0" ]]; then
                # ----------------------------------------------------------
                # Cert issuance: AT MOST ONE POST per FQDN per heal cycle.
                # ----------------------------------------------------------
                # The previous design (cert_max=5 retries × 180s reconcile
                # each) produced multi-cert burn on every flaky run: a POST
                # that "timed out" (HTTP 000) while certbot was still
                # working would trigger another POST, NPM would allocate a
                # new cert row, and so on. On LE production the rate limit
                # is 5 duplicate certs / 168h / identifier set — three POSTs
                # per heal would burn the weekly budget in two heal cycles.
                #
                # New invariant: we ask NPM for what's already in flight
                # before POSTing. If a cert row already exists for this
                # FQDN, OR certbot is currently running, we DO NOT POST.
                # We just wait long enough (up to ~20 min) for the existing
                # in-flight issuance to land disk material. Only if we know
                # for sure (a) NPM has no cert row for this FQDN and (b)
                # certbot isn't busy do we issue a POST — exactly one,
                # never retried. A second issuance attempt is a NEW heal
                # cycle, not an inner retry, and is the operator's choice.
                local cert_body
                cert_body=$(FQDN="$fqdn" python3 -c '
import os, json
print(json.dumps({
    "provider": "letsencrypt",
    "domain_names": [os.environ["FQDN"]],
    "meta": {"dns_challenge": False},
}))')

                local existing_latest existing_rc
                existing_latest=$(_npm_latest_cert_id_by_fqdn "$npm_token" "$npm_api" "$fqdn")
                existing_rc=$?
                latest_cert_id="$existing_latest"

                if (( existing_rc == 2 )); then
                    log_warn "Cert pre-flight: NPM API unreachable for $fqdn — refusing to POST (would risk duplicate issuance); deferring"
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "${target_cert_id:-0}" "false" "false" "$host_id" "npm-api-unreachable"
                    continue
                fi

                local should_post="false"
                if [[ -z "$existing_latest" || "$existing_latest" == "0" ]]; then
                    if _npm_certbot_busy; then
                        log_info "Cert pre-flight: certbot is currently running; not POSTing for $fqdn — will wait"
                    else
                        should_post="true"
                    fi
                else
                    if _npm_cert_material_ready "$existing_latest"; then
                        log_info "Cert pre-flight: NPM already has usable cert_id=$existing_latest for $fqdn — waiting on disk material instead of POSTing"
                    elif _npm_certbot_busy; then
                        log_info "Cert pre-flight: NPM has incomplete cert_id=$existing_latest for $fqdn and certbot is still running — not POSTing"
                    else
                        log_warn "Cert pre-flight: NPM has stale/incomplete cert_id=$existing_latest for $fqdn with no key+chain on disk and certbot is idle — issuing a fresh cert request"
                        should_post="true"
                    fi
                fi

                if [[ "$should_post" == "true" ]]; then
                    local cert_resp cert_http
                    cert_post_attempted="true"
                    cert_resp=$(curl -s -w "\n%{http_code}" --max-time 180 -X POST "$npm_api/nginx/certificates" \
                        -H "Authorization: Bearer $npm_token" \
                        -H "Content-Type: application/json" \
                        -d "$cert_body" 2>/dev/null)
                    cert_http=$(echo "$cert_resp" | tail -1)
                    cert_post_http="$cert_http"
                    log_info "Cert POST for $fqdn → HTTP ${cert_http:-000} (single POST per heal cycle)"
                fi

                # Wait up to ~20 min for any matching cert row to become
                # disk-usable. Iterates newest-first across all matching
                # ids, so an older ready cert isn't masked by a newer
                # not-yet-finished row.
                local found_cert_id wait_rc
                found_cert_id=$(_npm_wait_usable_cert "$npm_token" "$npm_api" "$fqdn" 120 10)
                wait_rc=$?
                if (( wait_rc == 0 )) && [[ -n "$found_cert_id" && "$found_cert_id" != "0" ]]; then
                    target_cert_id="$found_cert_id"
                    latest_cert_id="${latest_cert_id:-$found_cert_id}"
                else
                    case "$wait_rc" in
                        2) log_warn "Cert wait: NPM API unreachable throughout the window for $fqdn — public proxy host deferred" ;;
                        *) log_warn "Cert wait: no usable cert for $fqdn after ~20 min — public proxy host deferred" ;;
                    esac
                    cert_outcome="cert-wait-failed"
                    [[ "$wait_rc" == "2" ]] && cert_outcome="npm-api-unreachable"
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "${target_cert_id:-0}" "false" "false" "$host_id" "$cert_outcome"
                    continue
                fi
            fi

            # Idempotent skip MUST verify rendered state on disk, not just
            # DB field match. A historical orphan (DB row matches desired
            # JSON, but no proxy_host/$id.conf and no cert material) would
            # otherwise survive every re-run forever — the skip path here
            # was the gap that let the GCP-staging orphan persist past
            # multiple `configure.sh --only npm` invocations.
            if [[ -n "$host_json" ]] && echo "$host_json" | \
                FQDN="$fqdn" FH="$forward_host" FP="$forward_port" WS="$ws_val" \
                ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import sys, json, os
host = json.load(sys.stdin)
matches = (
    host.get("domain_names", []) == [os.environ["FQDN"]] and
    host.get("forward_scheme") == "http" and
    host.get("forward_host") == os.environ["FH"] and
    int(host.get("forward_port", 0)) == int(os.environ["FP"]) and
    bool(host.get("allow_websocket_upgrade")) == (os.environ["WS"] == "true") and
    int(host.get("certificate_id") or 0) == int(os.environ["CERT_ID"]) and
    bool(host.get("ssl_forced")) and
    bool(host.get("http2_support")) and
    bool(host.get("enabled")) and
    (host.get("advanced_config", "") or "") == os.environ["ADV"]
)
sys.exit(0 if matches else 1)
' 2>/dev/null && _npm_proxy_conf_renders "$host_id" "$fqdn" "$target_cert_id"; then
                log_skip "Proxy host: $fqdn already published"
                _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                continue
            fi

            # Publish, then verify by host-mounted disk truth — NPM's API
            # returns 2xx even when it can't render the .conf, so we cannot
            # treat HTTP 2xx as success on its own. If the .conf doesn't
            # appear with the expected (server_name, cert_id), roll the
            # host back to enabled=False cert=0 so it doesn't sit in DB
            # forever as an "enabled but invisible" orphan.
            if [[ -n "$host_json" ]]; then
                local update_body update_http
                update_body=$(echo "$host_json" | \
                    FQDN="$fqdn" FH="$forward_host" FP="$forward_port" WS="$ws_val" \
                    ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import sys, json, os
host = json.load(sys.stdin)
host["domain_names"] = [os.environ["FQDN"]]
host["forward_scheme"] = "http"
host["forward_host"] = os.environ["FH"]
host["forward_port"] = int(os.environ["FP"])
host["block_exploits"] = True
host["allow_websocket_upgrade"] = os.environ["WS"] == "true"
host["access_list_id"] = 0
host["certificate_id"] = int(os.environ["CERT_ID"])
host["ssl_forced"] = True
host["http2_support"] = True
host["meta"] = host.get("meta") or {}
host["advanced_config"] = os.environ["ADV"]
host["locations"] = host.get("locations") or []
host["caching_enabled"] = False
host["hsts_enabled"] = False
host["hsts_subdomains"] = False
host["enabled"] = True
for k in ("id", "created_on", "modified_on", "owner_user_id", "owner",
          "use_default_location", "ipv6"):
    host.pop(k, None)
print(json.dumps(host))
' 2>/dev/null)
                update_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X PUT \
                    "$npm_api/nginx/proxy-hosts/$host_id" \
                    -H "Authorization: Bearer $npm_token" \
                    -H "Content-Type: application/json" \
                    -d "$update_body")

                if [[ "$update_http" =~ ^2 ]]; then
                    if _npm_wait_proxy_conf "$host_id" "$fqdn" "$target_cert_id"; then
                        proxy_published="true"
                        log_ok "Proxy host: $fqdn published (cert_id=$target_cert_id, SSL forced, HTTP/2)"
                    else
                        log_warn "Proxy host: $fqdn updated in NPM API but proxy_host/$host_id.conf did not render with cert_id=$target_cert_id — disabling to avoid orphan"
                        _npm_disable_host "$npm_token" "$npm_api" "$host_id" "$host_json" >/dev/null 2>&1 || true
                    fi
                else
                    log_warn "Proxy host update failed: $fqdn (HTTP $update_http)"
                fi
                if [[ "$proxy_published" == "true" ]]; then
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                else
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "false" "$host_id" "proxy-render-failed"
                fi
            else
                local proxy_body proxy_resp proxy_http new_host_id
                proxy_body=$(FQDN="$fqdn" FH="$forward_host" FP="$forward_port" \
                    WS="$ws_val" ADV="$adv_config" CERT_ID="$target_cert_id" python3 -c '
import os, json
print(json.dumps({
    "domain_names": [os.environ["FQDN"]],
    "forward_scheme": "http",
    "forward_host": os.environ["FH"],
    "forward_port": int(os.environ["FP"]),
    "block_exploits": True,
    "allow_websocket_upgrade": os.environ["WS"] == "true",
    "access_list_id": 0,
    "certificate_id": int(os.environ["CERT_ID"]),
    "ssl_forced": True,
    "http2_support": True,
    "meta": {},
    "advanced_config": os.environ["ADV"],
    "locations": [],
    "caching_enabled": False,
    "hsts_enabled": False,
    "hsts_subdomains": False,
    "enabled": True,
}))')
                # Capture the response body so we can read the new host id
                # for the disk-render postcondition check.
                proxy_resp=$(curl -s -w "\n%{http_code}" --max-time 30 -X POST \
                    "$npm_api/nginx/proxy-hosts" \
                    -H "Authorization: Bearer $npm_token" \
                    -H "Content-Type: application/json" \
                    -d "$proxy_body")
                proxy_http=$(echo "$proxy_resp" | tail -1)
                proxy_resp=$(echo "$proxy_resp" | sed '$d')
                if [[ "$proxy_http" == "201" ]]; then
                    new_host_id=$(echo "$proxy_resp" | json_get id)
                    if [[ -n "$new_host_id" ]] && \
                       _npm_wait_proxy_conf "$new_host_id" "$fqdn" "$target_cert_id"; then
                        proxy_published="true"
                        host_id="$new_host_id"
                        log_ok "Proxy host: $fqdn published (cert_id=$target_cert_id, SSL forced, HTTP/2)"
                    else
                        log_warn "Proxy host: $fqdn created in NPM API but proxy_host/${new_host_id:-?}.conf did not render with cert_id=$target_cert_id — disabling to avoid orphan"
                        [[ -n "$new_host_id" ]] && \
                            _npm_disable_host "$npm_token" "$npm_api" "$new_host_id" "" >/dev/null 2>&1 || true
                    fi
                else
                    log_warn "Proxy host create failed: $fqdn (HTTP $proxy_http)"
                fi
                if [[ "$proxy_published" == "true" ]]; then
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "true" "$host_id" "published"
                else
                    _npm_cert_status_record "$fqdn" "$cert_post_attempted" "$cert_post_http" "$latest_cert_id" "$target_cert_id" "true" "false" "${new_host_id:-$host_id}" "proxy-render-failed"
                fi
            fi
        done
    else
        log_skip "Remote web state is ${remote_state:-unset} -- skipping public proxy hosts"
        if [[ -n "$domain" && "$domain" != "example.com" ]]; then
            for entry in "${proxy_hosts[@]}"; do
                IFS='|' read -r subdomain forward_host forward_port websocket <<< "$entry"
                local fqdn="${subdomain}.${domain}"
                local existing_host_json
                existing_host_json=$(echo "$existing_hosts" | FQDN="$fqdn" FH="$forward_host" FP="$forward_port" python3 -c '
import sys, json, os
fqdn = os.environ["FQDN"]
forward_host = os.environ["FH"]
forward_port = int(os.environ["FP"])
for host in json.load(sys.stdin):
    if (
        host.get("domain_names", []) == [fqdn] and
        host.get("forward_host") == forward_host and
        int(host.get("forward_port", 0)) == forward_port
    ):
        print(json.dumps(host))
        break
' 2>/dev/null)
                [[ -z "$existing_host_json" ]] && continue

                local existing_enabled
                existing_enabled=$(echo "$existing_host_json" | json_get enabled False)
                if [[ "$existing_enabled" =~ ^(True|true)$ ]]; then
                    local host_id disable_http
                    host_id=$(echo "$existing_host_json" | json_get id)
                    if [[ "$remote_state" == "failed" ]]; then
                        local existing_cert_id
                        existing_cert_id=$(echo "$existing_host_json" | json_get certificate_id 0)
                        if [[ "${existing_cert_id:-0}" != "0" ]] && \
                           _npm_cert_material_ready "$existing_cert_id" && \
                           _npm_proxy_conf_renders "$host_id" "$fqdn" "$existing_cert_id"; then
                            log_skip "Preserved ready proxy host after failed Stage 2: $fqdn"
                            continue
                        fi
                    fi
                    disable_http=$(_npm_disable_host "$npm_token" "$npm_api" "$host_id" "$existing_host_json")
                    if [[ "$disable_http" =~ ^2 ]]; then
                        log_warn "Disabled non-ready proxy host: $fqdn"
                    else
                        log_warn "Could not disable non-ready proxy host: $fqdn (HTTP $disable_http)"
                    fi
                fi
            done
        fi
    fi

    # Reload nginx if http_top.conf was just created (on re-runs where proxy
    # hosts already existed, no API call triggered an automatic reload).
    if [[ "$http_top_created" == "true" ]]; then
        docker exec npm nginx -s reload >/dev/null 2>&1 && \
            log_ok "NPM nginx reloaded (rate limit zone active)" || \
            log_warn "Could not reload NPM nginx — rate limits active after next proxy host change"
    fi

    # Verify npm-ratelimit jail values match config.yml
    local rl_maxretry rl_findtime
    rl_maxretry=$(cfg_field "rate_limiting.ban_maxretry" 2>/dev/null || echo "10")
    rl_findtime=$(cfg_field "rate_limiting.ban_findtime" 2>/dev/null || echo "60")

    local jail_file="$SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf"
    if grep -q "\[npm-ratelimit\]" "$jail_file" 2>/dev/null; then
        local current_maxretry current_findtime
        current_maxretry=$(sed -n '/\[npm-ratelimit\]/,/^\[/{s/^maxretry = //p}' "$jail_file")
        current_findtime=$(sed -n '/\[npm-ratelimit\]/,/^\[/{s/^findtime = //p}' "$jail_file")
        if [[ "$current_maxretry" == "$rl_maxretry" && "$current_findtime" == "$rl_findtime" ]]; then
            log_skip "Fail2ban: npm-ratelimit jail matches config.yml (maxretry=$rl_maxretry, findtime=${rl_findtime}s)"
        else
            log_warn "Fail2ban: npm-ratelimit jail values differ from config.yml (jail: maxretry=$current_maxretry findtime=$current_findtime, config: maxretry=$rl_maxretry findtime=$rl_findtime)"
        fi
    else
        log_warn "Fail2ban: npm-ratelimit jail not found in $jail_file"
    fi
}

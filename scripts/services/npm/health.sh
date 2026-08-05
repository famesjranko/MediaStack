# Owns: NPM nginx drift detection and bounded self-healing.
# Sources: main.sh/rendered.sh for SCRIPT_DIR/NPM_* globals, logging, and service helpers; no hidden inputs.

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
    if npm_remote_container_running; then
        _npm_running="true"
        if docker exec npm nginx -t >/dev/null 2>&1; then
            return 0
        fi
    else
        log_warn "NPM container is not running - checking for proxy_host config drift before restart"
    fi

    log_warn "NPM nginx -t failing - checking for proxy_host config drift"

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

    if ((${#_affected[@]} == 0)); then
        log_error "NPM nginx -t failing but no proxy_host/*.conf has missing cert refs"
        log_error "Unknown corruption - inspect: docker exec npm nginx -t"
        log_error "Forensic: $_data_dir/nginx/proxy_host/"
        return 1
    fi

    log_warn "Drifted host(s): ${_affected[*]} - attempting API repair first"

    # Stage 1: API repair. PUT each affected host to enabled=false cert=0.
    # NPM regenerates the .conf on PUT, so this is usually enough.
    local _token
    _token=""
    if [[ "$_npm_running" == "true" ]]; then
        _token=$(curl -sf --max-time "$NPM_HEALTH_PROBE_TIMEOUT_SECONDS" -X POST "$(service_local_url npm)/api/tokens" \
            -H "Content-Type: application/json" \
            -d "$(http_json_body identity "$_email" secret "$_pw")" 2>/dev/null | json_get token)
    fi

    if [[ -n "$_token" ]]; then
        local _host_json _body _hc
        for _host_id in "${_affected[@]}"; do
            _host_json=$(curl -sf --max-time "$NPM_API_READ_TIMEOUT_SECONDS" \
                -H "Authorization: Bearer $_token" \
                "$(service_local_url npm)/api/nginx/proxy-hosts/$_host_id" 2>/dev/null)
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
            _hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$NPM_API_WRITE_TIMEOUT_SECONDS" -X PUT \
                "$(service_local_url npm)/api/nginx/proxy-hosts/$_host_id" \
                -H "Authorization: Bearer $_token" \
                -H "Content-Type: application/json" \
                -d "$_body")
            log_info "  API: host $_host_id PUT enabled=false cert=0 (HTTP $_hc)"
        done
        if docker exec npm nginx -t >/dev/null 2>&1; then
            log_ok "NPM healed via API repair (nginx -t passes)"
            return 0
        fi
        log_warn "API repair didn't heal nginx - falling back to offline patch"
    else
        if [[ "$_npm_running" == "true" ]]; then
            log_warn "No NPM API token available - skipping API repair, going offline"
        else
            log_warn "NPM container not running - skipping API repair, going offline"
        fi
    fi

    # Stage 2: offline repair. Stop NPM, patch sqlite via host python3, archive
    # broken .conf, start NPM exactly once.
    log_warn "Stopping NPM for offline sqlite patch"
    (cd "$SCRIPT_DIR" && docker compose stop npm) >/dev/null 2>&1

    local _db="$_data_dir/database.sqlite"
    if [[ ! -f "$_db" ]]; then
        log_error "$_db not found - cannot patch DB"
        (cd "$SCRIPT_DIR" && docker compose start npm) >/dev/null 2>&1
        return 1
    fi

    # Patch sqlite via python3 stdlib — no host sqlite3 binary required, no
    # docker image pull. NPM image does not ship the sqlite3 CLI either, so
    # this is the most portable path. NPM's database.sqlite is owned by root
    # (the container writes as root), so we need sudo to open it for write.
    local _ids_csv _sql_err _sql_rc=0
    _ids_csv=$(
        IFS=,
        echo "${_affected[*]}"
    )
    # Capture stderr so a failure's SystemExit reason lands in the log_error
    # below instead of leaking to the terminal; discard stdout. On success
    # stderr is empty.
    _sql_err=$($_sudo python3 -c '
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
finally:
    con.close()
' "$_db" "$_ids_csv" 2>&1 >/dev/null) || _sql_rc=$?
    if ((_sql_rc != 0)); then
        log_error "sqlite patch via python3 failed (need sudo for $_db)${_sql_err:+: ${_sql_err}}"
        (cd "$SCRIPT_DIR" && docker compose start npm) >/dev/null 2>&1
        return 1
    fi
    log_info "  sqlite: host(s) ${_affected[*]} -> enabled=0 cert=0"

    # Archive the broken .conf for forensics; do not delete.
    local _ts _archive
    _ts=$(date +%Y%m%d-%H%M%S)
    _archive="$_data_dir/nginx/proxy_host.broken-$_ts"
    $_sudo mkdir -p "$_archive" 2>/dev/null
    for _host_id in "${_affected[@]}"; do
        local _src="$_data_dir/nginx/proxy_host/$_host_id.conf"
        if [[ -f "$_src" ]]; then
            $_sudo mv "$_src" "$_archive/" 2>/dev/null \
                && log_info "  archived $_host_id.conf -> $_archive/"
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
    for _i in $(seq 1 "$NPM_HEALTH_REPAIR_MAX_ATTEMPTS"); do
        if docker exec npm nginx -t >/dev/null 2>&1; then
            _probe_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$NPM_HEALTH_PROBE_TIMEOUT_SECONDS" \
                -X POST "$(service_local_url npm)/api/tokens" \
                -H "Content-Type: application/json" \
                -d '{"identity":"_probe","secret":"_probe"}' 2>/dev/null)
            if [[ -n "$_probe_http" && "$_probe_http" =~ ^[1-4] ]]; then
                log_ok "NPM healed (nginx -t clean, express alive - probe HTTP $_probe_http)"
                return 0
            fi
        fi
        sleep "$NPM_HEALTH_REPAIR_SLEEP_SECONDS"
    done

    log_error "NPM still unhealthy after offline repair - manual review needed"
    log_error "Forensic: $_archive"
    return 1
}

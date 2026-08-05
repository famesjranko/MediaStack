# Owns: npm_* — NPM rendered proxy state, host rollback, and idle checks.
# Sources: main.sh for SCRIPT_DIR/NPM_* globals and npm-remote.sh for disk truth; no hidden inputs.

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
    local _max="${4:-$NPM_PROXY_CONF_WAIT_MAX_POLLS}" _interval="${5:-$NPM_PROXY_CONF_WAIT_INTERVAL_SECONDS}"
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
        _host_json=$(curl -sf --max-time "$NPM_API_READ_TIMEOUT_SECONDS" -H "Authorization: Bearer $_token" \
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
    curl -s -o /dev/null -w "%{http_code}" --max-time "$NPM_API_WRITE_TIMEOUT_SECONDS" -X PUT \
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
    local _token="$1" _api="$2" _max="${3:-$NPM_HOST_IDLE_MAX_POLLS}"
    local _i
    for _i in $(seq 1 "$_max"); do
        if curl -sf --max-time "$NPM_HOST_IDLE_REQUEST_TIMEOUT_SECONDS" -H "Authorization: Bearer $_token" \
            "$_api" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$NPM_HOST_IDLE_SLEEP_SECONDS"
    done
    return 1
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

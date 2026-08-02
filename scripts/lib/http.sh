# =============================================================================
# MediaStack HTTP helpers: service readiness polling and authenticated POSTs
# =============================================================================

[[ -n "${_MS_HTTP_SH:-}" ]] && return 0
_MS_HTTP_SH=1

_HTTP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_HTTP_LIB_DIR/common.sh"

# Build a JSON object from key/value string pairs. All values are emitted as
# strings and properly JSON-escaped (quotes, backslashes, control chars) —
# safe for user-supplied input like passwords. For nested objects, numeric
# fields, or arrays, build via python3 directly rather than extending this.
# Usage: json_body key1 value1 [key2 value2 ...]
json_body() {
    python3 -c '
import sys, json
pairs = sys.argv[1:]
if len(pairs) % 2:
    sys.exit("json_body: odd number of args")
print(json.dumps(dict(zip(pairs[0::2], pairs[1::2]))))
' "$@"
}

# Build a JSON object from key/type/value triples, for bodies json_body (all
# strings) cannot express. Types: str; int; bool ("true"/"1"/"yes"/"on" -> true,
# anything else -> false); json (a raw JSON literal for nested/array/null, e.g.
# '{}', '[1,2]', 'null'). Like json_body, values reach python via argv, so they
# are JSON-escaped and never string-formatted into the program text.
# Usage: json_obj key1 type1 value1 [key2 type2 value2 ...]
json_obj() {
    python3 -c '
import sys, json
args = sys.argv[1:]
if len(args) % 3:
    sys.exit("json_obj: args must be key type value triples")
out = {}
for k, t, v in zip(args[0::3], args[1::3], args[2::3]):
    if t == "str":
        out[k] = v
    elif t == "int":
        out[k] = int(v)
    elif t == "bool":
        out[k] = v.lower() in ("1", "true", "yes", "on")
    elif t == "json":
        out[k] = json.loads(v)
    else:
        sys.exit("json_obj: unknown type " + t)
print(json.dumps(out))
' "$@"
}

# Perform a curl request and enforce a 2xx status. On 2xx the response body
# goes to stdout (return 0). On non-2xx the HTTP code + first 300 chars of
# body go to stderr via the specified log function and the function returns 1.
# Unlike _api_request (X-Api-Key-based *arr APIs) this helper is agnostic —
# pass any curl args including -X, -H, -d after the label.
_http_request() {
    local _log_fn="$1" label="$2"
    shift 2
    local out code
    out=$(curl -sS -w "\n%{http_code}" "$@" 2>/dev/null) \
        || {
            "$_log_fn" "$label: connection failed"
            return 1
        }
    code="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$code" =~ ^2 ]]; then
        printf '%s' "$out"
        return 0
    fi
    "$_log_fn" "$label: HTTP ${code} ${out:0:300}"
    return 1
}
# http_check: log_error on failure (strict — aborts the step).
# api_fetch:  log_warn on failure (advisory — fetch-and-compare calls).
http_check() { _http_request log_error "$@"; }
api_fetch() { _http_request log_warn "$@"; }

# Poll $url until it returns 2xx/3xx or ~90s elapses.
wait_for_service() {
    local name="$1" url="$2" max=90 i=0
    echo -ne "  Waiting for ${name}..."
    while ((i < max)); do
        if curl -sf "$url" >/dev/null 2>&1; then
            echo -e " ${GREEN}ready${NC}"
            return 0
        fi
        sleep 2
        ((i += 2))
        echo -ne "."
    done
    echo -e " ${RED}timeout${NC}"
    return 1
}

# Wait for a Docker container's healthcheck to report "healthy".
# Falls back to wait_for_service if the container has no healthcheck.
# Args: <label> <container_name> <fallback_url> [max_seconds=120]
wait_for_healthy() {
    local name="$1" container="$2" fallback_url="$3" max="${4:-120}" i=0
    local has_hc
    has_hc=$(docker inspect --format '{{if .State.Health}}yes{{end}}' "$container" 2>/dev/null || echo "")
    if [[ "$has_hc" != "yes" ]]; then
        wait_for_service "$name" "$fallback_url"
        return $?
    fi
    echo -ne "  Waiting for ${name}..."
    while ((i < max)); do
        local status
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")
        case "$status" in
            healthy)
                echo -e " ${GREEN}ready${NC}"
                return 0
                ;;
            unhealthy)
                echo -e " ${RED}unhealthy${NC}"
                return 1
                ;;
        esac
        sleep 3
        ((i += 3))
        echo -ne "."
    done
    echo -e " ${RED}timeout${NC}"
    return 1
}

# Poll an endpoint after a service restart/recreate. This helper intentionally
# does not log: callers own the operation-specific warning and keep/abort choice.
post_restart_wait() {
    local url="$1" max="${2:-60}" interval="${3:-2}" elapsed=0
    while ((elapsed < max)); do
        curl -sf --max-time 5 "$url" >/dev/null 2>&1 && return 0
        sleep "$interval"
        ((elapsed += interval))
    done
    curl -sf --max-time 5 "$url" >/dev/null 2>&1
}

# Poll Jellyfin's AuthenticateByName until it returns 200 (or fails fast on 401).
# Catches the post-recreate window where /health responds 200 but the SQLite-
# backed auth subsystem is still mid-WAL-replay and silently 5xxs auth requests.
# Distinguishes:
#   200            → ready, emit response body, return 0
#   401            → real cred failure, return 2 (no point waiting)
#   000 / 5xx / "" → not ready yet, keep polling
# Args: <jf_url> <auth_header> <auth_body> [max_seconds=30]
wait_for_jellyfin_auth() {
    local url="$1" hdr="$2" body="$3" max="${4:-30}" i=0
    local code resp_file
    resp_file=$(mktemp)
    while ((i < max)); do
        code=$(curl -s -o "$resp_file" -w '%{http_code}' -X POST "$url/Users/AuthenticateByName" \
            -H "Authorization: $hdr" -H "Content-Type: application/json" -d "$body" 2>/dev/null)
        case "$code" in
            200)
                cat "$resp_file"
                rm -f "$resp_file"
                return 0
                ;;
            401)
                rm -f "$resp_file"
                return 2
                ;;
            *) ;;
        esac
        sleep 2
        ((i += 2))
    done
    rm -f "$resp_file"
    return 1
}

# POST JSON within a cookie-authenticated session and surface rejection bodies.
# Used by Seerr to connect Sonarr/Radarr — 2.7.x's *Settings schemas
# require fields like activeProfileName and silent failures leave users with a
# half-configured instance.
#
# Args: <label> <endpoint> <json-payload> <cookiejar-path>
js_post() {
    local label="$1" endpoint="$2" payload="$3" cookiejar="$4"
    local resp_file http_code
    resp_file=$(mktemp)
    http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -c "$cookiejar" -b "$cookiejar" \
        -d "$payload" 2>/dev/null || echo "000")
    case "$http_code" in
        200 | 201)
            log_ok "$label connected"
            rm -f "$resp_file"
            return 0
            ;;
        *)
            local body
            body=$(head -c 300 "$resp_file")
            log_warn "Could not connect $label (HTTP $http_code): $body"
            rm -f "$resp_file"
            return 1
            ;;
    esac
}

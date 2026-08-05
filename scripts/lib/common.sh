# =============================================================================
# MediaStack shared helpers: colors, logging, config readers, API primitives
# =============================================================================
# Sourced by scripts/configure.sh (entrypoint) and optionally by setup.sh.
# Depends on $SCRIPT_DIR and $CONFIG_FILE being exported by the caller.
# No `set` flags here — libraries must not mutate the caller's shell options.

[[ -n "${_MS_COMMON_SH:-}" ]] && return 0
_MS_COMMON_SH=1

# --- Terminal capability (colour gating) ---
# Resolve term-caps.sh from this file's own dir (BASH_SOURCE), not $SCRIPT_DIR:
# common.sh is sourced by configure.sh / setup.sh / update.sh / mediastack with
# differing $SCRIPT_DIR contracts. term-caps.sh sets no shell options.
_COMMON_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=term-caps.sh
source "$_COMMON_TC_DIR/term-caps.sh"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;94m' # bright blue: [INFO] is the highest-volume level, and 0;34 is unreadably dark on dark terminals
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Blank the palette when colour is disabled (NO_COLOR / captured output / dumb
# terminal) so [INFO]/[OK]/... never carry escape codes into a redirected log.
if ! _color_enabled; then
    # Blanked as a complete set; CYAN/BOLD (and others) are read by sibling
    # modules (configure.sh, stack.sh, services), not within common.sh.
    # shellcheck disable=SC2034
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' BOLD='' NC=''
fi

_LOG_CAPTURE=""
_LOG_COUNTS_OK=0
_LOG_COUNTS_SKIP=0
_LOG_COUNTS_WARN=0
_LOG_COUNTS_ERROR=0

_log_emit() {
    local line="$1"
    if [[ -n "$_LOG_CAPTURE" ]]; then
        echo -e "$line" >>"$_LOG_CAPTURE"
    else
        # Write to stderr so log output stays visible when the caller is
        # inside a command substitution (e.g. validators run inside
        # `_WIZ_X=$(ui_input_validated ...)` would otherwise swallow the
        # ui_log warn/info that explains why a prompt is re-asking).
        echo -e "$line" >&2
    fi
}

# Marker via _ui_status_token (term-caps.sh): the ASCII bracket tag [INFO]/[OK]/...
# when glyphs are unavailable (byte-identical to the historical output), or the
# matching icon (•/✓/!/✗/→) when the terminal can render it — same vocabulary as
# the wizard's ui_log, so a single run never mixes bracket and glyph "languages".
log_info() { _log_emit "${BLUE}$(_ui_status_token info)${NC} $1"; }
log_ok() {
    ((_LOG_COUNTS_OK++)) || true
    _log_emit "${GREEN}$(_ui_status_token ok)${NC} $1"
}
log_warn() {
    ((_LOG_COUNTS_WARN++)) || true
    _log_emit "${YELLOW}$(_ui_status_token warn)${NC} $1"
}
log_error() {
    ((_LOG_COUNTS_ERROR++)) || true
    _log_emit "${RED}$(_ui_status_token error)${NC} $1"
}
log_skip() {
    ((_LOG_COUNTS_SKIP++)) || true
    _log_emit "${GRAY}$(_ui_status_token skip)${NC} $1"
}
# Advisory drift notice (invariant: re-runs warn on drift, never auto-reconcile).
# Renders identically to log_warn but does not bump _LOG_COUNTS_WARN, so a
# drift notice on a healthy service never flips its configure-summary badge
# to WARN (see _record_configure_result in configure.sh).
log_drift() { _log_emit "${YELLOW}$(_ui_status_token warn)${NC} $1"; }

log_capture_start() {
    _LOG_CAPTURE=$(mktemp)
    _LOG_COUNTS_OK=0
    _LOG_COUNTS_SKIP=0
    _LOG_COUNTS_WARN=0
    _LOG_COUNTS_ERROR=0
}

log_capture_stop() {
    echo "$_LOG_CAPTURE"
    _LOG_CAPTURE=""
}

log_capture_summary() {
    local parts=()
    [[ "$_LOG_COUNTS_OK" -gt 0 ]] && parts+=("${_LOG_COUNTS_OK} ok")
    [[ "$_LOG_COUNTS_SKIP" -gt 0 ]] && parts+=("${_LOG_COUNTS_SKIP} skipped")
    [[ "$_LOG_COUNTS_WARN" -gt 0 ]] && parts+=("${_LOG_COUNTS_WARN} warnings")
    [[ "$_LOG_COUNTS_ERROR" -gt 0 ]] && parts+=("${_LOG_COUNTS_ERROR} errors")
    local IFS=", "
    echo "${parts[*]:-done}"
}

# =============================================================================
# Config reader — one parametrised YAML reader (was nine near-identical readers)
# =============================================================================
# Every input (config path, dotted key, mode, optional default) reaches python
# via argv — never string-formatted into the program text — so a key or path
# with special characters can never corrupt the source. The public cfg_* names
# below are thin adapters over cfg_read; they are kept as separate functions
# because the unit tests stub them by name.
cfg_read() {
    # cfg_read <mode> <key> [default]   — reads $CONFIG_FILE (via argv).
    # default: json mode = fallback JSON; value mode = absent-key fallback
    # (empty string = emit nothing, rc 0).
    python3 - "$CONFIG_FILE" "$@" <<'PY' 2>/dev/null
import sys, json, yaml

config_file, mode = sys.argv[1], sys.argv[2]
key = sys.argv[3] if len(sys.argv) > 3 else ""
default = sys.argv[4] if len(sys.argv) > 4 else None

with open(config_file) as f:
    data = yaml.safe_load(f)

def walk(root, dotted):
    node = root
    for k in dotted.split('.'):
        node = node[int(k)] if isinstance(node, list) else node[k]
    return node

if mode == "value":
    try:
        node = walk(data, key)
    except (KeyError, IndexError, TypeError):
        if default is None:
            sys.exit(1)
        node = None
    # Absent (or present-but-null) key: with a default, emit it (empty
    # default = emit nothing) and succeed. Without a default, an absent key
    # keeps the non-zero rc; a legitimate null value still prints "None".
    if default is not None and node is None:
        if default:
            print(default)
        sys.exit(0)
    if isinstance(node, list):
        for item in node:
            print(' '.join(str(x) for x in item.values()) if isinstance(item, dict) else item)
    else:
        print(node)
elif mode == "pairs":
    # A null/non-string value (e.g. a blank category path) fails the whole
    # read before anything is printed (rc 1, like the pre-refactor readers'
    # TypeError) — never emit "name:None" for a caller to configure verbatim.
    items = walk(data, key).items()
    if any(not isinstance(val, str) for _, val in items):
        sys.exit(1)
    for name, val in items:
        print(f"{name}:{val}")
elif mode == "json":
    try:
        node = walk(data, key)
    except (KeyError, IndexError, TypeError):
        node = None
    if default is not None and not node:
        print(default)
    elif node is None:
        sys.exit(1)
    else:
        print(json.dumps(node))
elif mode == "indexers":
    for idx in data.get('indexers', []):
        print(idx['id'] + ':' + idx.get('type', 'general'))
elif mode == "jf_libraries":
    for lib in data['jellyfin']['libraries']:
        print(lib['name'] + ':' + lib['type'] + ':' + lib['path'])
else:
    sys.exit("cfg_read: unknown mode " + mode)
PY
}

# Adapters — each pins the mode + key/default so call sites stay unchanged.
# Scalar/leaf read (auto-iterates a list value, e.g. bazarr languages).
cfg_field() { cfg_read value "$1"; }
# Indexer list as id:type pairs (type defaults to "general").
cfg_indexers() { cfg_read indexers ""; }
# quality_profile.<app>_qualities as a JSON array; empty + non-zero rc if absent.
cfg_quality_ids() { cfg_read json "quality_profile.${1}_qualities"; }
# quality_definitions.<app> as a JSON object; {} when the section is absent.
cfg_quality_definitions() { cfg_read json "quality_definitions.$1" '{}'; }
# custom_formats (name→score) as a JSON object; {} when absent.
cfg_custom_format_scores() { cfg_read json custom_formats '{}'; }
# qBittorrent categories as name:path pairs.
cfg_qbt_categories() { cfg_read pairs qbittorrent.categories; }
# Bazarr languages, one per line; empty + rc 0 when the key is absent.
cfg_bazarr_languages() { cfg_read value bazarr.languages ""; }
# Jellyfin libraries as name:type:path.
cfg_jf_libraries() { cfg_read jf_libraries ""; }

# =============================================================================
# API key helpers
# =============================================================================

# API primitives — capture HTTP code + body so failures surface actionable
# error messages instead of silent empty output.  On 2xx the body goes to
# stdout and we return 0.  On anything else the code + first 300 chars of
# body go to stderr and we return 1.  Callers that already redirect
# 2>/dev/null are unaffected; callers that *don't* now get visibility for free.
_api_request() {
    local _caller="$1" _method="$2" _url="$3" _key="$4" _data="${5:-}"
    # --max-time 45 caps any single curl wall time. Most *arr endpoints answer
    # in <1s; the indexer save path can stall on Sonarr/Radarr's synchronous
    # caps fetch through Jackett to a Cloudflare-protected tracker. 45s exceeds
    # Sonarr's own ~30s internal timeout but lets us recover from a truly hung
    # call instead of waiting curl-default-forever. Retry wrappers (e.g.
    # _add_indexer's 2 attempts) still get a second chance on transient timeout.
    local _args=(-sS --max-time 45 -H "X-Api-Key: $_key" -H "Content-Type: application/json")
    [[ "$_method" != "GET" ]] && _args+=(-X "$_method")
    [[ -n "$_data" ]] && _args+=(-d "$_data")
    _args+=(-w "\n%{http_code}")
    local _out _code
    _out=$(curl "${_args[@]}" "$_url" 2>/dev/null) \
        || {
            echo "$_caller $_url: connection failed" >&2
            return 1
        }
    _code="${_out##*$'\n'}"
    _out="${_out%$'\n'*}"
    if [[ "$_code" =~ ^2 ]]; then
        printf '%s' "$_out"
    else
        echo "$_caller $_url: HTTP ${_code} ${_out:0:300}" >&2
        return 1
    fi
}
api_get() { _api_request api_get GET "$1" "$2"; }
api_post() { _api_request api_post POST "$1" "$2" "$3"; }
api_put() { _api_request api_put PUT "$1" "$2" "$3"; }

get_api_key() {
    [[ -f "$1" ]] && grep -oP '<ApiKey>\K[^<]+' "$1" 2>/dev/null || echo ""
}

get_jackett_api_key() {
    local f="$SCRIPT_DIR/config/jackett/Jackett/ServerConfig.json"
    [[ -f "$f" ]] && python3 -c "import json; print(json.load(open('$f')).get('APIKey',''))" 2>/dev/null || echo ""
}

# .env-writing concern (atomic key/value rewrite, save_api_key) lives in its
# own file — see env-update.sh's header for what it owns.
# shellcheck source=env-update.sh
source "$_COMMON_TC_DIR/env-update.sh"

# =============================================================================
# Container state
# =============================================================================

# True iff a container named EXACTLY $1 exists and is running. One semantic for
# the "is it up?" question that was open-coded across services in three divergent
# idioms (`docker inspect .State.Running`, substring `docker ps --filter name=`,
# project-scoped `docker compose ps`). Host-scoped and cwd-independent (unlike
# `docker compose ps`), exact-match (unlike a bare `grep -q`), and safe when
# docker is absent (inspect errors are swallowed → false). health.sh keeps its
# own batch/health-aware probes (_health_svc_healthy, _health_f2b_running) —
# those answer "running AND healthy", a different question.
container_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

# =============================================================================
# Service HTTP endpoints
# =============================================================================

# HTTP UI/API ports only. Do not use these for non-HTTP service ports such as
# NPM 80/443, WireGuard UDP, qBittorrent peer traffic, or the Beszel agent.
readonly -A _MS_SERVICE_HTTP_PORT=(
    ["bazarr"]=6767
    ["beszel"]=8090
    ["ddns-updater"]=8000
    ["flaresolverr"]=8191
    ["homepage"]=3000
    ["jackett"]=9117
    ["jellyfin"]=8096
    ["npm"]=81
    ["portainer"]=9000
    ["qbittorrent"]=8080
    ["radarr"]=7878
    ["seerr"]=5055
    ["sonarr"]=8989
    ["uptime-kuma"]=3001
    ["wireguard"]=51821
)

service_http_port() {
    local svc="${1:-}" port
    port="${_MS_SERVICE_HTTP_PORT[$svc]:-}"
    [[ -n "$port" ]] || return 1
    printf '%s' "$port"
}

service_local_url() {
    local svc="$1" port
    port=$(service_http_port "$svc") || return 1
    printf 'http://localhost:%s' "$port"
}

service_internal_url() {
    local svc="$1" port
    port=$(service_http_port "$svc") || return 1
    printf 'http://%s:%s' "$svc" "$port"
}

service_http_ports_json() {
    local svc args=()
    for svc in "${!_MS_SERVICE_HTTP_PORT[@]}"; do
        args+=("$svc" "${_MS_SERVICE_HTTP_PORT[$svc]}")
    done
    python3 - "${args[@]}" <<'PY'
import json
import sys

pairs = sys.argv[1:]
print(json.dumps({k: int(v) for k, v in zip(pairs[0::2], pairs[1::2])}))
PY
}

service_internal_urls_json() {
    local svc args=()
    for svc in "${!_MS_SERVICE_HTTP_PORT[@]}"; do
        args+=("$svc" "$(service_internal_url "$svc")")
    done
    python3 - "${args[@]}" <<'PY'
import json
import sys

pairs = sys.argv[1:]
print(json.dumps(dict(zip(pairs[0::2], pairs[1::2]))))
PY
}

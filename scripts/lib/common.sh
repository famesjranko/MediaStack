# =============================================================================
# MediaStack shared helpers: colors, logging, config readers, API primitives
# =============================================================================
# Sourced by scripts/configure.sh (entrypoint) and optionally by setup.sh.
# Depends on $SCRIPT_DIR and $CONFIG_FILE being exported by the caller.
# No `set` flags here — libraries must not mutate the caller's shell options.

# --- Terminal capability (colour gating) ---
# Resolve term_caps.sh from this file's own dir (BASH_SOURCE), not $SCRIPT_DIR:
# common.sh is sourced by configure.sh / setup.sh / update.sh / mediastack with
# differing $SCRIPT_DIR contracts. term_caps.sh sets no shell options.
_COMMON_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=term_caps.sh
source "$_COMMON_TC_DIR/term_caps.sh"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;94m'   # bright blue: [INFO] is the highest-volume level, and 0;34 is unreadably dark on dark terminals
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
        echo -e "$line" >> "$_LOG_CAPTURE"
    else
        # Write to stderr so log output stays visible when the caller is
        # inside a command substitution (e.g. validators run inside
        # `_WIZ_X=$(ui_input_validated ...)` would otherwise swallow the
        # ui_log warn/info that explains why a prompt is re-asking).
        echo -e "$line" >&2
    fi
}

# Marker via _ui_status_token (term_caps.sh): the ASCII bracket tag [INFO]/[OK]/...
# when glyphs are unavailable (byte-identical to the historical output), or the
# matching icon (•/✓/!/✗/→) when the terminal can render it — same vocabulary as
# the wizard's ui_log, so a single run never mixes bracket and glyph "languages".
log_info()  { _log_emit "${BLUE}$(_ui_status_token info)${NC} $1"; }
log_ok()    { ((_LOG_COUNTS_OK++)) || true;    _log_emit "${GREEN}$(_ui_status_token ok)${NC} $1"; }
log_warn()  { ((_LOG_COUNTS_WARN++)) || true;  _log_emit "${YELLOW}$(_ui_status_token warn)${NC} $1"; }
log_error() { ((_LOG_COUNTS_ERROR++)) || true; _log_emit "${RED}$(_ui_status_token error)${NC} $1"; }
log_skip()  { ((_LOG_COUNTS_SKIP++)) || true;  _log_emit "${GRAY}$(_ui_status_token skip)${NC} $1"; }

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
    [[ "$_LOG_COUNTS_OK" -gt 0 ]]    && parts+=("${_LOG_COUNTS_OK} ok")
    [[ "$_LOG_COUNTS_SKIP" -gt 0 ]]  && parts+=("${_LOG_COUNTS_SKIP} skipped")
    [[ "$_LOG_COUNTS_WARN" -gt 0 ]]  && parts+=("${_LOG_COUNTS_WARN} warnings")
    [[ "$_LOG_COUNTS_ERROR" -gt 0 ]] && parts+=("${_LOG_COUNTS_ERROR} errors")
    local IFS=", "
    echo "${parts[*]:-done}"
}

# =============================================================================
# Config reader (simple YAML parser via python3 - always available on Debian)
# =============================================================================

cfg() {
    python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
keys = '$1'.split('.')
v = c
for k in keys:
    if isinstance(v, list):
        v = v[int(k)]
    else:
        v = v[k]
if isinstance(v, list):
    for item in v:
        if isinstance(item, dict):
            print(' '.join(str(x) for x in item.values()))
        else:
            print(item)
else:
    print(v)
" 2>/dev/null
}

# Get a specific field from indexed list items
cfg_field() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
keys = '$1'.split('.')
v = c
for k in keys:
    if isinstance(v, list):
        v = v[int(k)]
    else:
        v = v[k]
print(v)
" 2>/dev/null
}

# Get indexer list as id:type pairs
cfg_indexers() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
for idx in c.get('indexers', []):
    print(idx['id'] + ':' + idx.get('type', 'general'))
" 2>/dev/null
}

# Get quality IDs as a JSON array string (e.g. "[4,5,6]")
cfg_quality_ids() {
    local app="$1"
    python3 -c "
import yaml, json
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
ids = c['quality_profile']['${app}_qualities']
print(json.dumps(list(ids)))
" 2>/dev/null
}

# Get quality_definitions.<app> as a JSON object string. Returns {} if the
# section is absent — callers should treat that as "skip, use upstream defaults".
cfg_quality_definitions() {
    local app="$1"
    python3 -c "
import yaml, json
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f) or {}
d = (c.get('quality_definitions') or {}).get('$app') or {}
print(json.dumps(d))
" 2>/dev/null
}

# Get custom_formats section as a JSON object (name→score). Returns {} if absent.
cfg_custom_format_scores() {
    python3 -c "
import yaml, json
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f) or {}
d = c.get('custom_formats') or {}
print(json.dumps(d))
" 2>/dev/null
}

# Get qBittorrent categories as name:path pairs
cfg_qbt_categories() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
cats = c['qbittorrent']['categories']
for name, path in cats.items():
    print(name + ':' + path)
" 2>/dev/null
}

# Get Bazarr languages as a list of language names
cfg_bazarr_languages() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
for lang in c.get('bazarr', {}).get('languages', []):
    print(lang)
" 2>/dev/null
}

# Get Jellyfin libraries as name:type:path
cfg_jf_libraries() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    c = yaml.safe_load(f)
for lib in c['jellyfin']['libraries']:
    print(lib['name'] + ':' + lib['type'] + ':' + lib['path'])
" 2>/dev/null
}

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
        || { echo "$_caller $_url: connection failed" >&2; return 1; }
    _code="${_out##*$'\n'}"
    _out="${_out%$'\n'*}"
    if [[ "$_code" =~ ^2 ]]; then
        printf '%s' "$_out"
    else
        echo "$_caller $_url: HTTP ${_code} ${_out:0:300}" >&2
        return 1
    fi
}
api_get()  { _api_request api_get  GET  "$1" "$2"; }
api_post() { _api_request api_post POST "$1" "$2" "$3"; }
api_put()  { _api_request api_put  PUT  "$1" "$2" "$3"; }

get_api_key() {
    [[ -f "$1" ]] && grep -oP '<ApiKey>\K[^<]+' "$1" 2>/dev/null || echo ""
}

get_jackett_api_key() {
    local f="$SCRIPT_DIR/config/jackett/Jackett/ServerConfig.json"
    [[ -f "$f" ]] && python3 -c "import json; print(json.load(open('$f')).get('APIKey',''))" 2>/dev/null || echo ""
}

# General-purpose, hardened "rewrite a KEY=value line in .env" primitive.
#
#   _env_write_kv <env_file> <key> <value>
#
# Single-quotes the value (so spaces, $, \, #, =, ", and leading/trailing
# whitespace round-trip byte-exact when the file is re-sourced), rewrites the
# matching key in place (or appends if absent) via an atomic temp-file replace
# that preserves the file mode, and leaves every unrelated line untouched.
# Refuses values containing a single quote or a newline (which cannot be safely
# single-quoted) and refuses an invalid key name — in those cases the file is
# left exactly as it was. Echoes a status word and returns non-zero on failure:
#   changed | unchanged                              -> rc 0
#   invalid-key | invalid-newline | invalid-quote
#   read-error:<reason> | write-error:<reason>       -> rc 1
# Side-effect-free beyond the file write: it does NOT log or export — callers
# decide how to surface the outcome. This is the one .env-mutation writer; both
# save_api_key and the launcher's _set_env_var route through it (no second
# hand-rolled, unquoted implementation).
_env_write_kv() {
    local env_file="$1" key="$2" value="$3"
    MEDIASTACK_ENV_WRITE_VALUE="$value" python3 - "$env_file" "$key" <<'PY'
import os
import pathlib
import re
import shlex
import stat
import sys
import tempfile

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = os.environ.get("MEDIASTACK_ENV_WRITE_VALUE", "")

if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
    print("invalid-key")
    sys.exit(2)
if "\n" in value or "\r" in value:
    print("invalid-newline")
    sys.exit(3)
if "'" in value:
    print("invalid-quote")
    sys.exit(4)

encoded = f"{key}='{value}'\n"

try:
    original = env_path.read_text()
    env_stat = env_path.stat()
except OSError as exc:
    print(f"read-error:{exc.strerror or exc.__class__.__name__}")
    sys.exit(5)

lines = original.splitlines(keepends=True)
changed = False
found = False
new_lines = []

for line in lines:
    body = line[:-1] if line.endswith("\n") else line
    if body.startswith(f"{key}="):
        found = True
        raw_current = body.split("=", 1)[1]
        try:
            parsed = shlex.split(raw_current, posix=True)
            current = parsed[0] if parsed else ""
        except ValueError:
            current = None

        if current == value and line == encoded:
            new_lines.append(line)
        else:
            new_lines.append(encoded)
            changed = True
    else:
        new_lines.append(line)

if not found:
    if new_lines and not new_lines[-1].endswith("\n"):
        new_lines[-1] += "\n"
    new_lines.append(encoded)
    changed = True

if not changed:
    print("unchanged")
    sys.exit(0)

tmp_name = ""
try:
    fd, tmp_name = tempfile.mkstemp(
        prefix=f"{env_path.name}.tmp.",
        dir=str(env_path.parent),
        text=True,
    )
    with os.fdopen(fd, "w") as tmp:
        os.fchmod(tmp.fileno(), stat.S_IMODE(env_stat.st_mode) or 0o600)
        tmp.writelines(new_lines)
    os.replace(tmp_name, env_path)
except OSError as exc:
    if tmp_name:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
    print(f"write-error:{exc.strerror or exc.__class__.__name__}")
    sys.exit(6)

print("changed")
PY
}

# Map an _env_write_kv failure status to a user-facing log_warn line. Shared by
# the writer's callers so the refusal/error messages stay consistent.
_env_write_kv_warn() {
    local key_name="$1" status="$2"
    case "$status" in
        invalid-key)
            log_warn "Refusing to save invalid .env key name: ${key_name}"
            ;;
        invalid-newline)
            log_warn "Refusing to save ${key_name} to .env: value contains a newline"
            ;;
        invalid-quote)
            log_warn "Refusing to save ${key_name} to .env: value contains a single quote"
            ;;
        read-error:*|write-error:*)
            log_warn "Failed to save ${key_name} to .env (${status#*:})"
            ;;
        *)
            log_warn "Failed to save ${key_name} to .env"
            ;;
    esac
}

save_api_key() {
    local key_name="$1" key_value="$2" env_file="$SCRIPT_DIR/.env"
    [[ -f "$env_file" ]] || return

    local writer_status
    if ! writer_status=$(_env_write_kv "$env_file" "$key_name" "$key_value"); then
        _env_write_kv_warn "$key_name" "$writer_status"
        return 1
    fi

    if [[ "$writer_status" == "changed" ]]; then
        log_ok "Saved ${key_name} to .env"
    fi
    # Export to the live shell too — later steps in the same configure.sh
    # invocation can then read the value without needing to re-source .env.
    export "${key_name}=${key_value}"
}

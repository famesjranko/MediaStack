# =============================================================================
# MediaStack JSON helpers: stdin-based field extraction and array queries
# =============================================================================
# Sourced by lib/common.sh and callers that only need JSON helpers. Each function reads JSON
# from stdin. Required fields fail explicitly; optional application defaults
# must be chosen by a caller after the response has been validated.

# Extract a required scalar. Absence, null, containers and malformed JSON fail;
# a real false, zero or empty string remains a value, never a default.
json_get() { json_path "$@"; }
json_path() {
    [[ $# == 1 ]] || {
        echo "json_path: expected one required path" >&2
        return 1
    }
    python3 -c '
import json, sys
path = sys.argv[1]
try:
    value = json.load(sys.stdin)
    for key in path.split("."):
        value = value[key]
    if value is None or isinstance(value, (dict, list)):
        raise ValueError
except (ValueError, KeyError, TypeError):
    sys.exit("invalid or missing required JSON field " + path)
print(value)
' "$1"
}

# Exit 0 if any object in a JSON array on stdin has a matching field value.
# Usage: echo "$arr" | json_has_name <value> [--field name] [--key nested] [-i]
json_has_name() {
    local value="" field="name" nested_key="" insensitive=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field)
                field="$2"
                shift 2
                ;;
            --key)
                nested_key="$2"
                shift 2
                ;;
            -i)
                insensitive="1"
                shift
                ;;
            *)
                value="$1"
                shift
                ;;
        esac
    done
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    key = sys.argv[1]
    items = d.get(key, d) if isinstance(d, dict) and key else d
    if not isinstance(items, list): items = []
    val, ci, field = sys.argv[2], bool(sys.argv[3]), sys.argv[4]
    if ci: val = val.lower()
    for item in items:
        v = str(item.get(field, ''))
        if ci: v = v.lower()
        if v == val: sys.exit(0)
except Exception: pass
sys.exit(1)" "$nested_key" "$value" "$insensitive" "$field" 2>/dev/null
}

# Exit 0 if stdin is a non-empty JSON array.
# Usage: echo "$json" | json_array_nonempty
json_array_nonempty() {
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    sys.exit(0 if isinstance(d, list) and len(d) > 0 else 1)
except Exception:
    sys.exit(1)" 2>/dev/null
}

# Validate required dot paths, with [] for array members, then pass JSON through.
# Missing/null fields fail; an explicitly empty array is valid. Errors name only
# the path, never response values (which can contain credentials).
# Append :string to require a string value.
# A field ending in ? is optional in the upstream API; validate it when present.
# Usage: json_require token:string record.id:string 'items[].name:string'
json_require() {
    python3 -c '
import json, sys

def require(value, parts, path, kind):
    if not parts:
        if value is None and kind not in ("nullable", "nullable-array", "nullable-number"):
            raise ValueError("null required field " + path)
        types = {"string": str, "object": dict, "array": list, "boolean": bool,
                 "integer": int, "number": (int, float), "nullable": object,
                 "nullable-array": (list, type(None)), "nullable-number": (int, float, type(None))}
        if kind and (not isinstance(value, types[kind]) or
                     (kind in ("number", "integer", "nullable-number") and isinstance(value, bool))):
            raise ValueError("unexpected type at required field " + path)
        return
    part, *rest = parts
    array = part.endswith("[]")
    key = part[:-2] if array else part
    optional = key.endswith("?")
    key = key[:-1] if optional else key
    if key == "*":
        if not isinstance(value, dict):
            raise ValueError("expected object at required field " + path)
        for item in value.values():
            require(item, rest, path, kind)
        return
    if key and (not isinstance(value, dict) or key not in value):
        if optional and isinstance(value, dict):
            return
        raise ValueError("missing required field " + path)
    child = value[key] if key else value
    if array:
        if not isinstance(child, list):
            raise ValueError("expected array at required field " + path)
        for item in child:
            require(item, rest, path, kind)
    else:
        require(child, rest, path, kind)

try:
    raw = sys.stdin.read()
    data = json.loads(raw)
except (ValueError, UnicodeError):
    sys.exit("invalid JSON response")
try:
    for spec in sys.argv[1:]:
        path, _, kind = spec.partition(":")
        if kind not in ("", "string", "object", "array", "boolean", "integer", "number", "nullable", "nullable-array", "nullable-number"):
            raise ValueError("invalid required field type")
        require(data, path.split(".") if path else [], path or "response", kind)
except ValueError as error:
    sys.exit(str(error))
sys.stdout.write(raw)
' "$@"
}

# Validate a read before deciding whether to create/update state. Error output
# contains the operation and field path, never the response or its credentials.
json_check() {
    local label="$1" error
    shift
    if ! error=$(json_require "$@" 2>&1 >/dev/null); then
        if declare -F log_warn >/dev/null; then
            log_warn "$label: $error"
        else
            echo "$label: $error" >&2
        fi
        return 1
    fi
}

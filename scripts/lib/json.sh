# =============================================================================
# MediaStack JSON helpers: stdin-based field extraction and array queries
# =============================================================================
# Sourced by lib/http.sh and callers that only need JSON helpers. Each function reads JSON
# from stdin. The legacy extractors keep their default-value behavior;
# json_require rejects incomplete responses before a caller uses those extractors.

# Extract a top-level key from JSON on stdin.
# Usage: echo "$json" | json_get <key> [default]
json_get() {
    python3 -c "
import sys, json
try:
    v = json.load(sys.stdin).get(sys.argv[1])
    print(sys.argv[2] if v is None else v)
except Exception:
    print(sys.argv[2])" "$1" "${2:-}" 2>/dev/null
}

# Extract a nested value via dot-separated path from JSON on stdin.
# Usage: echo "$json" | json_path <dot.path> [default]
json_path() {
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split('.'):
        d = d.get(k, {}) if isinstance(d, dict) else {}
    print(sys.argv[2] if isinstance(d, (dict, list)) or d is None else d)
except Exception:
    print(sys.argv[2])" "$1" "${2:-}" 2>/dev/null
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
# Usage: json_require token:string record.id:string 'items[].name:string'
json_require() {
    python3 -c '
import json, sys

def require(value, parts, path, kind):
    if not parts:
        if value is None:
            raise ValueError("null required field " + path)
        if kind == "string" and not isinstance(value, str):
            raise ValueError("expected string at required field " + path)
        return
    part, *rest = parts
    array = part.endswith("[]")
    key = part[:-2] if array else part
    if not isinstance(value, dict) or key not in value:
        raise ValueError("missing required field " + path)
    child = value[key]
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
        if kind not in ("", "string"):
            raise ValueError("invalid required field type")
        require(data, path.split("."), path, kind)
except ValueError as error:
    sys.exit(str(error))
sys.stdout.write(raw)
' "$@"
}

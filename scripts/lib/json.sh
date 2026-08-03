# =============================================================================
# MediaStack JSON helpers: stdin-based field extraction and array queries
# =============================================================================
# Sourced by scripts/configure.sh after lib/http.sh. Each function reads JSON
# from stdin, prints a result (or exits 0/1 for predicates), and swallows
# parse errors silently — matching the existing inline python3 -c behavior.

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

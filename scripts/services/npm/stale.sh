# Owns: npm_* — NPM stale-managed-host detection and warning-only drift reporting.
# Sources: main.sh for logging helpers; it performs no mutation and has no hidden inputs.

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
        if not (name.startswith("jellyfin.") or name.startswith("seerr.")):
            continue
        suffix = name.split(".", 1)[1] if "." in name else ""
        if suffix and suffix != domain:
            stale.append(name)
if stale:
    print(", ".join(sorted(set(stale))))
' 2>/dev/null)

    if [[ -n "$_stale_hosts" ]]; then
        log_warn "NPM has proxy hosts for a different domain (kept, not auto-changed). Stale: $_stale_hosts"
    fi
    return 0
}

# =============================================================================
# Seerr — default permissions + request quotas
# =============================================================================
# Sourced by seerr/main.sh. Depends on helpers already loaded by
# configure.sh: cfg_field, api_fetch, log_ok/log_skip/log_warn.

# Seerr merges POST /settings/main into its stored settings. Omitting a quota,
# or sending `{}` for it, therefore keeps the old limit (verified on Seerr
# 3.5.1). A quota is cleared by sending quotaLimit 0 explicitly. A limit of 0
# means unlimited, so its day value is irrelevant when states are compared.
#
# Modes (stdin: GET /settings/main; argv: mode movie_limit movie_days tv_limit tv_days):
#   plan   exit 0 = already matches; exit 10 = update needed, POST body on stdout
#   verify exit 0 = matches; exit 1 = differs
# Exit 2 = config values invalid; exit 3 = response unusable. Config values
# arrive through argv only, never in the Python source.
_SEERR_QUOTA_PY='
import json, sys

mode, raw = sys.argv[1], sys.argv[2:6]
want, body = {}, {"defaultPermissions": 32, "defaultQuotas": {}}
try:
    for kind, (lim, days) in zip(("movie", "tv"), (raw[0:2], raw[2:4])):
        if not (lim.isascii() and lim.isdigit() and days.isascii() and days.isdigit()):
            raise ValueError(kind)
        lim, days = int(lim), int(days)
        if lim > 0 and days == 0:
            raise ValueError(kind)
        want[kind] = (lim, days) if lim > 0 else (0, 0)
        body["defaultQuotas"][kind] = {"quotaLimit": lim, "quotaDays": days}
except ValueError:
    sys.exit(2)

try:
    settings = json.load(sys.stdin)
    quotas = settings["defaultQuotas"]
    if not isinstance(quotas, dict):
        raise TypeError
    have = {}
    for kind in ("movie", "tv"):
        q = quotas.get(kind) or {}
        lim, days = q.get("quotaLimit") or 0, q.get("quotaDays") or 0
        if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in (lim, days)):
            raise TypeError
        have[kind] = (lim, days) if lim > 0 else (0, 0)
    perms = settings.get("defaultPermissions")
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit(3)

same = perms == 32 and have == want
if mode == "verify":
    sys.exit(0 if same else 1)
if same:
    sys.exit(0)
print(json.dumps(body))
sys.exit(10)
'

# Args: <seerr_url> <cookiejar> <main-settings JSON, empty when the GET failed>
reconcile_seerr_quotas() {
    local seerr_url="$1" cookiejar="$2" current_settings="$3"
    local movie_limit movie_days tv_limit tv_days
    movie_limit=$(cfg_field "seerr.quotas.movie.limit" 2>/dev/null || echo "10")
    movie_days=$(cfg_field "seerr.quotas.movie.days" 2>/dev/null || echo "7")
    tv_limit=$(cfg_field "seerr.quotas.tv.limit" 2>/dev/null || echo "10")
    tv_days=$(cfg_field "seerr.quotas.tv.days" 2>/dev/null || echo "7")
    local args=("$movie_limit" "$movie_days" "$tv_limit" "$tv_days")

    local settings_body rc=0
    settings_body=$(python3 -I -c "$_SEERR_QUOTA_PY" plan "${args[@]}" <<<"$current_settings") || rc=$?
    case "$rc" in
        0)
            log_skip "Seerr permissions + quotas already match config.yml"
            return 0
            ;;
        10) ;;
        2)
            log_warn "seerr.quotas in config.yml must be whole numbers (days at least 1 when limit is above 0); Seerr quotas not changed"
            return 0
            ;;
        *)
            log_warn "Could not read Seerr quota settings; Seerr quotas not changed"
            return 0
            ;;
    esac

    if ! curl -fsS -X POST "$seerr_url/api/v1/settings/main" \
        -H "Content-Type: application/json" \
        -c "$cookiejar" -b "$cookiejar" \
        -d "$settings_body" >/dev/null 2>&1; then
        log_warn "Failed to set Seerr permissions/quotas"
        return 0
    fi

    # HTTP 200 does not prove the change: read the settings back.
    local after
    after=$(api_fetch "Seerr main settings" -c "$cookiejar" -b "$cookiejar" "$seerr_url/api/v1/settings/main") || after=""
    if python3 -I -c "$_SEERR_QUOTA_PY" verify "${args[@]}" <<<"$after"; then
        log_ok "Seerr: admin-approval required, quotas ${movie_limit} movies/${movie_days}d + ${tv_limit} TV/${tv_days}d"
    else
        log_warn "Seerr accepted the quota update but its settings do not match config.yml"
    fi
}

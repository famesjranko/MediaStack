#!/usr/bin/env bash
# Reusable qBittorrent live API assertion.
#
# Runs from a MediaStack checkout after the stack is up and configured. It can
# run inside DinD, on a real host, or over SSH on a remote test VM:
#   bash tests/assertions/qbittorrent-live.sh

set -uo pipefail

QBT_URL="${QBT_URL:-http://localhost:8080}"
ENV_FILE="${ENV_FILE:-.env}"
CONFIG_FILE="${CONFIG_FILE:-config.yml}"
FAIL_COUNT=0
CHECK_COUNT=0

usage() {
    cat <<'EOF'
Usage: bash tests/assertions/qbittorrent-live.sh [--url URL] [--env FILE] [--config FILE]

Outputs tab-separated records:
  PASS<TAB>label
  FAIL<TAB>label<TAB>detail
  SKIP<TAB>label<TAB>reason
EOF
}

emit_pass() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    printf 'PASS\t%s\n' "$1"
}

emit_fail() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL\t%s\t%s\n' "$1" "${2//$'\n'/ }"
}

emit_skip() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    printf 'SKIP\t%s\t%s\n' "$1" "$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            [[ $# -ge 2 ]] || {
                usage >&2
                exit 2
            }
            QBT_URL="$2"
            shift 2
            ;;
        --env)
            [[ $# -ge 2 ]] || {
                usage >&2
                exit 2
            }
            ENV_FILE="$2"
            shift 2
            ;;
        --config)
            [[ $# -ge 2 ]] || {
                usage >&2
                exit 2
            }
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

QBT_URL="${QBT_URL%/}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || emit_fail "step 1 qBittorrent: live assertion dependency available: $1" "command not found"
}

require_command curl
require_command python3
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    emit_fail "step 1 qBittorrent: live assertion dependency available: python3-yaml" "python3 cannot import yaml"
fi

if [[ ! -f "$ENV_FILE" ]]; then
    emit_fail "step 1 qBittorrent: .env readable" "$ENV_FILE not found"
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    emit_fail "step 1 qBittorrent: config.yml readable" "$CONFIG_FILE not found"
fi
if ((FAIL_COUNT > 0)); then
    exit 1
fi

env_value() {
    local key="$1" existing
    existing="${!key-}"
    if [[ -n "$existing" ]]; then
        printf '%s' "$existing"
        return 0
    fi
    python3 - "$ENV_FILE" "$key" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    name, value = line.split("=", 1)
    if name != key:
        continue
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    print(value, end="")
    break
PY
}

cfg_value() {
    local path="$1"
    python3 - "$CONFIG_FILE" "$path" <<'PY'
import sys
import yaml

config_path, dotted = sys.argv[1], sys.argv[2]
with open(config_path, encoding="utf-8") as handle:
    value = yaml.safe_load(handle) or {}
for part in dotted.split("."):
    if not isinstance(value, dict):
        value = ""
        break
    value = value.get(part, "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

cfg_categories() {
    python3 - "$CONFIG_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}
for name, path in (config.get("qbittorrent", {}).get("categories", {}) or {}).items():
    print(f"{name}\t{path}")
PY
}

json_field() {
    local json="$1" field="$2"
    JSON_DOC="$json" JSON_FIELD="$field" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ["JSON_DOC"])
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(os.environ["JSON_FIELD"], "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

category_path() {
    local json="$1" name="$2"
    JSON_DOC="$json" CATEGORY_NAME="$name" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ["JSON_DOC"])
except Exception:
    data = {}
cat = data.get(os.environ["CATEGORY_NAME"], {})
print(cat.get("savePath", ""), end="")
PY
}

limit_bytes() {
    python3 - "$1" <<'PY'
import sys

print(int(float(sys.argv[1]) * 1048576), end="")
PY
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        emit_pass "$label"
    else
        emit_fail "$label" "expected='$expected' actual='$actual'"
    fi
}

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

qbt_login() {
    local username="$1" password="$2" resp body http_code
    resp=$(curl -s -c "$COOKIE_JAR" -w "\n%{http_code}" "$QBT_URL/api/v2/auth/login" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" 2>/dev/null) || return 1
    http_code=$(printf '%s' "$resp" | tail -1 | tr -d '\r')
    body=$(printf '%s' "$resp" | sed '$d' | tr -d '\r')
    [[ "$body" == "Ok." || ("$http_code" == "204" && -z "$body") ]]
}

api_get() {
    local endpoint="$1"
    curl -sf -b "$COOKIE_JAR" "$QBT_URL$endpoint" 2>/dev/null
}

admin_user="$(env_value JELLYFIN_ADMIN_USER)"
admin_password="$(env_value JELLYFIN_ADMIN_PASSWORD)"
if [[ -z "$admin_user" || -z "$admin_password" ]]; then
    emit_fail "step 1 qBittorrent: shared admin credentials available" "JELLYFIN_ADMIN_USER or JELLYFIN_ADMIN_PASSWORD is empty"
else
    if qbt_login "$admin_user" "$admin_password"; then
        emit_pass "step 1 qBittorrent: shared admin credentials authenticate"
    else
        emit_fail "step 1 qBittorrent: shared admin credentials authenticate" "login failed for user '$admin_user'"
    fi
fi

if ((FAIL_COUNT > 0)); then
    exit 1
fi

prefs_json="$(api_get /api/v2/app/preferences || true)"
if [[ -z "$prefs_json" ]]; then
    emit_fail "step 1 qBittorrent: preferences API readable" "empty response from $QBT_URL/api/v2/app/preferences"
else
    emit_pass "step 1 qBittorrent: preferences API readable"
fi

cats_json="$(api_get /api/v2/torrents/categories || true)"
if [[ -z "$cats_json" ]]; then
    emit_fail "step 1 qBittorrent: categories API readable" "empty response from $QBT_URL/api/v2/torrents/categories"
else
    emit_pass "step 1 qBittorrent: categories API readable"
fi

if ((FAIL_COUNT > 0)); then
    exit 1
fi

assert_eq "0" "$(json_field "$prefs_json" max_ratio_act)" "step 1 qBittorrent: max_ratio_act=0 (pause, not delete)"

dl_limit_mb="$(env_value QBT_DL_LIMIT)"
ul_limit_mb="$(env_value QBT_UL_LIMIT)"
[[ -z "$dl_limit_mb" ]] && dl_limit_mb="$(cfg_value qbittorrent.dl_speed_limit)"
[[ -z "$ul_limit_mb" ]] && ul_limit_mb="$(cfg_value qbittorrent.ul_speed_limit)"
assert_eq "$(limit_bytes "${dl_limit_mb:-0}")" "$(json_field "$prefs_json" dl_limit)" "step 1 qBittorrent: download limit matches .env/config"
assert_eq "$(limit_bytes "${ul_limit_mb:-0}")" "$(json_field "$prefs_json" up_limit)" "step 1 qBittorrent: upload limit matches .env/config"

assert_eq "$(cfg_value qbittorrent.max_seeding_time)" "$(json_field "$prefs_json" max_seeding_time)" "step 1 qBittorrent: max_seeding_time matches config.yml"
assert_eq "True" "$(json_field "$prefs_json" max_seeding_time_enabled)" "step 1 qBittorrent: max_seeding_time_enabled"
assert_eq "172.16.0.0/12" "$(json_field "$prefs_json" bypass_auth_subnet_whitelist)" "step 1 qBittorrent: subnet whitelist covers Docker bridge"
assert_eq "True" "$(json_field "$prefs_json" bypass_auth_subnet_whitelist_enabled)" "step 1 qBittorrent: subnet whitelist enabled"

storage_app_wiring="$(env_value STORAGE_APP_WIRING)"
if [[ "$storage_app_wiring" == "manual" ]]; then
    emit_skip "step 1 qBittorrent: managed save/temp paths" "manual app wiring"
    emit_skip "step 1 qBittorrent: managed categories" "manual app wiring"
else
    assert_eq "$(cfg_value qbittorrent.save_path)" "$(json_field "$prefs_json" save_path)" "step 1 qBittorrent: save_path matches config.yml"
    assert_eq "$(cfg_value qbittorrent.temp_path)" "$(json_field "$prefs_json" temp_path)" "step 1 qBittorrent: temp_path matches config.yml"
    assert_eq "True" "$(json_field "$prefs_json" temp_path_enabled)" "step 1 qBittorrent: temp_path_enabled"

    category_count=0
    while IFS=$'\t' read -r category expected_path; do
        [[ -n "$category" ]] || continue
        category_count=$((category_count + 1))
        assert_eq "$expected_path" "$(category_path "$cats_json" "$category")" "step 1 qBittorrent: category $category save path"
    done < <(cfg_categories)
    if ((category_count == 0)); then
        emit_fail "step 1 qBittorrent: managed categories configured" "config.yml has no qbittorrent.categories entries"
    fi
fi

exit $((FAIL_COUNT > 0))

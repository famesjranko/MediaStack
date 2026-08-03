# tests/api-matrix/qbittorrent.sh — qBittorrent apply + day-2 limit matrix.
#
# State 1 applies the config.yml-driven qBittorrent configurator and checks its
# live preferences/categories. State 2 drives the focused day-2 speed-limit
# action and proves it changes only the two intended limits.

_qbtm_cfg_field() {
    local field="$1"
    dind_exec "bash -c 'CONFIG_FILE=/tmp/ms-qbt-matrix.yml; export CONFIG_FILE; SCRIPT_DIR=\$PWD; export SCRIPT_DIR; source scripts/lib/common.sh; cfg_field \"$field\"'"
}

_qbtm_cfg_categories() {
    dind_exec "bash -c 'CONFIG_FILE=/tmp/ms-qbt-matrix.yml; export CONFIG_FILE; SCRIPT_DIR=\$PWD; export SCRIPT_DIR; source scripts/lib/common.sh; cfg_qbt_categories'"
}

_qbtm_login() {
    local username="$1" password="$2" response body http_code
    response=$(dind_exec "rm -f /tmp/ms-qbt-matrix.cookie; curl -s -c /tmp/ms-qbt-matrix.cookie -w '\\n%{http_code}' http://localhost:8080/api/v2/auth/login --data-urlencode 'username=$username' --data-urlencode 'password=$password'") || return 1
    http_code=$(printf '%s' "$response" | tail -1 | tr -d '\r')
    body=$(printf '%s' "$response" | sed '$d' | tr -d '\r')
    [[ "$body" == "Ok." || ("$http_code" == "204" && -z "$body") ]]
}

_qbtm_preferences() {
    dind_exec "curl -sf -b /tmp/ms-qbt-matrix.cookie http://localhost:8080/api/v2/app/preferences"
}

_qbtm_categories() {
    dind_exec "curl -sf -b /tmp/ms-qbt-matrix.cookie http://localhost:8080/api/v2/torrents/categories"
}

_qbtm_json_field() {
    local json="$1" field="$2"
    QBT_MATRIX_JSON="$json" QBT_MATRIX_FIELD="$field" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["QBT_MATRIX_JSON"]).get(os.environ["QBT_MATRIX_FIELD"], "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

_qbtm_category_path() {
    local json="$1" category="$2"
    QBT_MATRIX_JSON="$json" QBT_MATRIX_CATEGORY="$category" python3 - <<'PY'
import json
import os

categories = json.loads(os.environ["QBT_MATRIX_JSON"])
print(categories.get(os.environ["QBT_MATRIX_CATEGORY"], {}).get("savePath", ""), end="")
PY
}

_qbtm_canonical_json() {
    QBT_MATRIX_JSON="$1" python3 - <<'PY'
import json
import os

print(json.dumps(json.loads(os.environ["QBT_MATRIX_JSON"]), sort_keys=True, separators=(",", ":")), end="")
PY
}

_qbtm_mb_to_bytes() {
    python3 - "$1" <<'PY'
import sys

print(int(float(sys.argv[1]) * 1048576), end="")
PY
}

_qbtm_seed_config_limits() {
    dind_exec "bash tests/api-matrix/push_qbt.sh seed-config 11 5"
}

matrix_qbittorrent() {
    local username="$1" password="$2"
    local prefs categories before_prefs before_categories after_prefs after_categories
    local field expected actual category path

    # Exercise config.yml values first, then distinct .env overrides. Zero is
    # qBittorrent's default, so it would not prove either value was applied.
    if _qbtm_seed_config_limits; then
        pass "qBittorrent api-matrix: throwaway config has non-default speed limits"
    else
        fail "qBittorrent api-matrix: throwaway config has non-default speed limits"
        skip "qBittorrent api-matrix: all remaining module assertions" "config seed failed"
        return
    fi

    # State 1: the real first-run/re-run configurator applies config.yml.
    if dind_exec "bash tests/api-matrix/push_qbt.sh apply"; then
        pass "qBittorrent api-matrix: product configurator applied"
    else
        fail "qBittorrent api-matrix: product configurator applied"
        skip "qBittorrent api-matrix: all remaining module assertions" "first apply failed"
        return
    fi

    if _qbtm_login "$username" "$password"; then
        pass "qBittorrent api-matrix: shared credentials authenticate"
    else
        fail "qBittorrent api-matrix: shared credentials authenticate"
        skip "qBittorrent api-matrix: all remaining module assertions" "login failed"
        return
    fi

    prefs=$(_qbtm_preferences) || {
        fail "qBittorrent api-matrix: preferences API readable"
        skip "qBittorrent api-matrix: all remaining module assertions" "preferences API unreadable"
        return
    }
    categories=$(_qbtm_categories) || {
        fail "qBittorrent api-matrix: categories API readable"
        skip "qBittorrent api-matrix: all remaining module assertions" "categories API unreadable"
        return
    }
    pass "qBittorrent api-matrix: preferences API readable"
    pass "qBittorrent api-matrix: categories API readable"

    for field in save_path temp_path max_ratio max_seeding_time max_active_downloads max_active_uploads max_active_torrents; do
        expected=$(_qbtm_cfg_field "qbittorrent.$field")
        actual=$(_qbtm_json_field "$prefs" "$field")
        assert_eq "$expected" "$actual" "qBittorrent api-matrix: $field matches config.yml"
    done
    assert_eq "0" "$(_qbtm_json_field "$prefs" max_ratio_act)" \
        "qBittorrent api-matrix: max_ratio_act pauses torrents"
    assert_eq "True" "$(_qbtm_json_field "$prefs" max_ratio_enabled)" \
        "qBittorrent api-matrix: max_ratio policy is enabled"
    assert_eq "True" "$(_qbtm_json_field "$prefs" max_seeding_time_enabled)" \
        "qBittorrent api-matrix: max-seeding-time policy is enabled"
    assert_eq "True" "$(_qbtm_json_field "$prefs" temp_path_enabled)" \
        "qBittorrent api-matrix: temporary path is enabled"
    assert_eq "$(_qbtm_mb_to_bytes 11)" "$(_qbtm_json_field "$prefs" dl_limit)" \
        "qBittorrent api-matrix: config.yml download limit applied"
    assert_eq "$(_qbtm_mb_to_bytes 5)" "$(_qbtm_json_field "$prefs" up_limit)" \
        "qBittorrent api-matrix: config.yml upload limit applied"

    while IFS=: read -r category path; do
        [[ -n "$category" ]] || continue
        assert_eq "$path" "$(_qbtm_category_path "$categories" "$category")" \
            "qBittorrent api-matrix: category $category matches config.yml"
    done < <(_qbtm_cfg_categories)

    # State 2: .env limits take precedence over the config.yml values above.
    env_set QBT_DL_LIMIT 17
    env_set QBT_UL_LIMIT 7
    if dind_exec "bash tests/api-matrix/push_qbt.sh apply"; then
        pass "qBittorrent api-matrix: product configurator reapplied with .env limits"
    else
        fail "qBittorrent api-matrix: product configurator reapplied with .env limits"
        skip "qBittorrent api-matrix: state 2-3 assertions" "reapply with .env limits failed"
        return
    fi
    prefs=$(_qbtm_preferences) || {
        fail "qBittorrent api-matrix: preferences readable after .env limits"
        skip "qBittorrent api-matrix: state 2-3 assertions" "preferences unreadable after .env limits"
        return
    }
    assert_eq "$(_qbtm_mb_to_bytes 17)" "$(_qbtm_json_field "$prefs" dl_limit)" \
        "qBittorrent api-matrix: .env download limit overrides config.yml"
    assert_eq "$(_qbtm_mb_to_bytes 7)" "$(_qbtm_json_field "$prefs" up_limit)" \
        "qBittorrent api-matrix: .env upload limit overrides config.yml"

    # State 3: the day-2 action may only mutate the two speed-limit fields.
    before_prefs="$prefs"
    before_categories="$categories"
    if dind_exec "bash tests/api-matrix/push_qbt.sh speedlimit 7 3"; then
        pass "qBittorrent api-matrix: day-2 speed-limit action applied"
    else
        fail "qBittorrent api-matrix: day-2 speed-limit action applied"
        skip "qBittorrent api-matrix: state 3 post-action assertions" "speed-limit action failed"
        return
    fi

    after_prefs=$(_qbtm_preferences) || {
        fail "qBittorrent api-matrix: preferences readable after speed-limit action"
        skip "qBittorrent api-matrix: state 3 post-action assertions" "preferences unreadable after speed-limit action"
        return
    }
    after_categories=$(_qbtm_categories) || {
        fail "qBittorrent api-matrix: categories readable after speed-limit action"
        skip "qBittorrent api-matrix: state 3 post-action assertions" "categories unreadable after speed-limit action"
        return
    }

    assert_eq "$(_qbtm_mb_to_bytes 7)" "$(_qbtm_json_field "$after_prefs" dl_limit)" \
        "qBittorrent api-matrix: day-2 download limit changed"
    assert_eq "$(_qbtm_mb_to_bytes 3)" "$(_qbtm_json_field "$after_prefs" up_limit)" \
        "qBittorrent api-matrix: day-2 upload limit changed"

    for field in save_path temp_path max_ratio max_ratio_act max_ratio_enabled max_seeding_time max_seeding_time_enabled; do
        assert_eq "$(_qbtm_json_field "$before_prefs" "$field")" "$(_qbtm_json_field "$after_prefs" "$field")" \
            "qBittorrent api-matrix: day-2 action preserves $field"
    done
    assert_eq "$(_qbtm_canonical_json "$before_categories")" "$(_qbtm_canonical_json "$after_categories")" \
        "qBittorrent api-matrix: day-2 action preserves categories"
}

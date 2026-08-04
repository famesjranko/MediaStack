# tests/scenarios/contract-drift.sh — live contract-drift replay.
#
# Image-bump preflight / scheduled drift-alert scenario, NOT the PR gate (see
# docs/operations/upgrades.md "Preflight a candidate image" and TARGET.md's
# "CI placement is fixed"). Brings up the same API-bearing services
# tests/scenarios/api-matrix.sh already brings up (tests/api-matrix/bringup.sh
# — one bring-up, reused, never duplicated) and runs tests/contracts/replay.py
# in live mode against all six API-bearing services' real APIs, diffing only
# the declared `reads` fields of their safe (GET, no `{id}`, declared `reads`)
# endpoints:
#
#   sonarr, radarr    X-Api-Key header — bringup.sh already extracts these.
#   qbittorrent       Cookie session (SID) — the SAME login api-matrix.sh's
#                     own qBittorrent module authenticates with, after
#                     applying the product configurator (idempotent, its own
#                     throwaway config — tests/api-matrix/push_qbt.sh).
#   jackett           `apikey` query param AND a UI session cookie — the
#                     management API rejects the apikey alone (302 ->
#                     /UI/Login; see scripts/services/jackett/main.sh's own
#                     comment on this). replay.py's `--cookie` flag carries
#                     the session alongside the `--service` apikey credential.
#   jellyfin          Authorization header, Jellyfin's own
#                     `MediaBrowser ..., Token="..."` scheme (contract's
#                     `auth.format` template) — using the permanent API key
#                     configure_jellyfin's first-run wizard creates.
#   seerr             Cookie session (connect.sid) via Jellyfin SSO, after
#                     configure_seerr signs in as the admin the Jellyfin step
#                     above created (same ordering configure.sh itself uses).
#
# Getting real credentials for the four non-*arr services means actually
# applying their product configurators here (not just bringing the
# containers up) — bringup.sh's own job stays "containers + health + *arr
# keys"; this scenario layers its own apply/login cycle on top, reusing the
# exact product-configurator entry points (tests/api-matrix/push_*.sh) and
# session-login helpers (tests/api-matrix/{qbittorrent,jackett,jellyfin,seerr}.sh)
# api-matrix.sh's own modules already use. Every configure_* entry point is
# designed to be safe to re-run (AGENTS.md's "safe to re-run"), so this never
# risks api-matrix.sh's own later re-run of the same steps in its own,
# separate bring-up.
#
# Each credential helper below WRITES its result to an output file rather
# than returning it via `$(...)` — pass/fail (tests/lib/assert.sh) echo to
# real stdout, and capturing a function's stdout via command substitution
# would swallow those `[PASS]`/`[FAIL]` lines into the "credential" itself
# (a real bug caught here: the captured `[` broke urllib's URL parser).

source tests/api-matrix/bringup.sh
source tests/api-matrix/qbittorrent.sh
source tests/api-matrix/jackett.sh
source tests/api-matrix/jellyfin.sh
source tests/api-matrix/seerr.sh

# Shared harness admin credentials this scenario's apply/login cycle uses —
# the SAME values api-matrix.sh wires in via env_set JELLYFIN_ADMIN_USER /
# JELLYFIN_ADMIN_PASSWORD (qBittorrent, Jackett, and the Jellyfin SSO admin
# Seerr signs into all key off that one shared password there too).
_CD_ADMIN_USER="matrix-admin"
_CD_ADMIN_PASSWORD="ApiMatrixQbtPassword123"

# A curl -c jar's Netscape-format lines, one field list per cookie. curl
# marks an HttpOnly cookie's line with a literal `#HttpOnly_` prefix on the
# domain field (still 7 real fields after that prefix is stripped) — every
# session cookie these services set (qBittorrent's SID, Seerr's connect.sid,
# Jackett's own) is HttpOnly, so treating a leading `#` as "always a
# comment, skip it" silently dropped every cookie this scenario needs.
_cd_cookie_fields() {
    local jar="$1"
    dind_exec "python3 -c \"
for line in open('$jar'):
    line = line.rstrip('\n')
    if line.startswith('#HttpOnly_'):
        line = line[len('#HttpOnly_'):]
    elif not line.strip() or line.startswith('#'):
        continue
    f = line.split('\t')
    if len(f) >= 7:
        print(f[5] + '\t' + f[6])
\""
}

# Every cookie in a curl -c jar, as one `Cookie:` header value — used for
# Jackett, whose session isn't exposed behind one known cookie name.
_cd_cookie_header() {
    local jar="$1"
    _cd_cookie_fields "$jar" | awk -F'\t' '{printf "%s%s=%s", (NR>1?"; ":""), $1, $2}'
}

# The value of one named cookie from a curl -c jar.
_cd_cookie_value() {
    local jar="$1" name="$2"
    _cd_cookie_fields "$jar" | awk -F'\t' -v want="$name" '$1 == want {print $2}'
}

# qBittorrent: apply, then open the session credential replay.py replays
# with, written to $1.
_cd_qbittorrent_credential() {
    local out="$1"
    if ! dind_exec "bash tests/api-matrix/push_qbt.sh apply" >/tmp/contract-drift-qbt-apply.out 2>&1; then
        fail "contract-drift: qBittorrent configurator applied"
        cat /tmp/contract-drift-qbt-apply.out
        return 1
    fi
    if ! _qbtm_login "$_CD_ADMIN_USER" "$_CD_ADMIN_PASSWORD"; then
        fail "contract-drift: qBittorrent session login"
        return 1
    fi
    # qBittorrent 5.x names its session cookie QBT_SID_<port>, not the plain
    # `SID` of older releases — see tests/contracts/qbittorrent.yml's own
    # note; this stack's WebUI port is fixed at 8080 (docker-compose.yml).
    local sid
    sid=$(_cd_cookie_value /tmp/ms-qbt-matrix.cookie QBT_SID_8080)
    [[ -n "$sid" ]] || {
        fail "contract-drift: qBittorrent session credential"
        return 1
    }
    pass "contract-drift: qBittorrent session credential"
    printf '%s' "$sid" >"$out"
}

# Jackett: apply, then the apikey ($1) plus a session cookie ($2) — replay.py
# needs the two as separate --service/--cookie values.
_cd_jackett_credential() {
    local key_out="$1" cookie_out="$2"
    if ! dind_exec "bash tests/api-matrix/push_jackett.sh apply" >/tmp/contract-drift-jackett-apply.out 2>&1; then
        fail "contract-drift: Jackett configurator applied"
        cat /tmp/contract-drift-jackett-apply.out
        return 1
    fi
    local key
    key=$(_jkm_api_key)
    if [[ -z "$key" ]] || ! _jkm_login "$_CD_ADMIN_PASSWORD"; then
        fail "contract-drift: Jackett API key / session login"
        return 1
    fi
    local cookie
    cookie=$(_cd_cookie_header /tmp/ms-jackett-matrix.cookie)
    [[ -n "$cookie" ]] || {
        fail "contract-drift: Jackett session credential"
        return 1
    }
    pass "contract-drift: Jackett API key + session credential"
    printf '%s' "$key" >"$key_out"
    printf '%s' "$cookie" >"$cookie_out"
}

# Jellyfin: apply (first-run wizard creates the admin + a permanent API key,
# saved to .env by the product configurator itself), written to $1.
_cd_jellyfin_credential() {
    local out="$1"
    if ! dind_exec "bash tests/api-matrix/push_jellyfin.sh apply" >/tmp/contract-drift-jellyfin-apply.out 2>&1; then
        fail "contract-drift: Jellyfin configurator applied (first-run wizard)"
        cat /tmp/contract-drift-jellyfin-apply.out
        return 1
    fi
    local key
    key=$(_jfm_api_key)
    [[ -n "$key" ]] || {
        fail "contract-drift: Jellyfin API key credential"
        return 1
    }
    pass "contract-drift: Jellyfin API key credential"
    printf '%s' "$key" >"$out"
}

# Seerr: apply (signs in as the Jellyfin admin the step above created — same
# ordering configure.sh itself uses), then a fresh harness session login,
# written to $1.
_cd_seerr_credential() {
    local out="$1"
    if ! dind_exec "bash tests/api-matrix/push_seerr.sh apply" >/tmp/contract-drift-seerr-apply.out 2>&1; then
        fail "contract-drift: Seerr configurator applied"
        cat /tmp/contract-drift-seerr-apply.out
        return 1
    fi
    local jar="/tmp/ms-contract-drift-seerr.cookie"
    if ! _srm_login "$_CD_ADMIN_USER" "$_CD_ADMIN_PASSWORD" "$jar"; then
        fail "contract-drift: Seerr harness session login"
        return 1
    fi
    local sid
    sid=$(_cd_cookie_value "$jar" "connect.sid")
    [[ -n "$sid" ]] || {
        fail "contract-drift: Seerr session credential"
        return 1
    }
    pass "contract-drift: Seerr session credential"
    printf '%s' "$sid" >"$out"
}

run_scenario() {
    api_matrix_bring_up || return 1

    if [[ -z "$API_MATRIX_SONARR_KEY" || -z "$API_MATRIX_RADARR_KEY" ]]; then
        fail "contract-drift: Sonarr/Radarr API keys available for replay"
        return 1
    fi

    local live_args=(
        --service "sonarr:http://localhost:8989:$API_MATRIX_SONARR_KEY"
        --service "radarr:http://localhost:7878:$API_MATRIX_RADARR_KEY"
    )

    local qbt_out="/tmp/contract-drift-qbt.cred"
    if _cd_qbittorrent_credential "$qbt_out"; then
        live_args+=(--service "qbittorrent:http://localhost:8080:$(cat "$qbt_out")")
    fi

    local jackett_key_out="/tmp/contract-drift-jackett.cred"
    local jackett_cookie_out="/tmp/contract-drift-jackett.cookie"
    if _cd_jackett_credential "$jackett_key_out" "$jackett_cookie_out"; then
        live_args+=(
            --service "jackett:http://localhost:9117:$(cat "$jackett_key_out")"
            --cookie "jackett:$(cat "$jackett_cookie_out")"
        )
    fi

    local jf_out="/tmp/contract-drift-jellyfin.cred"
    if _cd_jellyfin_credential "$jf_out"; then
        live_args+=(--service "jellyfin:http://localhost:8096:$(cat "$jf_out")")
    fi

    local seerr_out="/tmp/contract-drift-seerr.cred"
    if _cd_seerr_credential "$seerr_out"; then
        live_args+=(--service "seerr:http://localhost:5055:$(cat "$seerr_out")")
    fi

    # dind_exec runs its whole argument through `sh -c`, so any credential or
    # cookie value containing shell metacharacters (a Jackett session's `;`
    # cookie separators, in practice) must be single-quoted here rather than
    # interpolated raw.
    local quoted_args="" arg
    for arg in "${live_args[@]}"; do
        quoted_args+=" '${arg//\'/\'\\\'\'}'"
    done

    local log_path="/tmp/contract-drift-replay.out"
    if dind_exec "python3 tests/contracts/replay.py live$quoted_args" \
        >"$log_path" 2>&1; then
        pass "contract-drift: replay.py live mode (${#live_args[@]} args)"
    else
        fail "contract-drift: replay.py live mode"
        tail -80 "$log_path"
        return 1
    fi
}

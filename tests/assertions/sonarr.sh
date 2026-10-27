# shellcheck source=tests/assertions/arr-indexers.sh
source tests/assertions/arr-indexers.sh

assert_sonarr_configured() {
    local configure_log="$1"

    SONARR_KEY=$(get_api_key_from_xml "config/sonarr/config.xml")
    [[ -n "$SONARR_KEY" ]] && pass "step 3 Sonarr: API key present" || fail "step 3 Sonarr: API key present"

    local sonarr_base="http://localhost:8989/api/v3"
    local sonarr_rf sonarr_dc sonarr_qp
    sonarr_rf=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/rootfolder")
    sonarr_dc=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/downloadclient")
    sonarr_qp=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/qualityprofile")

    assert_contains "$sonarr_rf" '/data/media/tv' "step 3 Sonarr: rootfolder /data/media/tv"

    local sonarr_mm sonarr_min_free
    sonarr_mm=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/config/mediamanagement")
    sonarr_min_free=$(echo "$sonarr_mm" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("minimumFreeSpaceWhenImporting", 0))
except Exception: print(0)' 2>/dev/null)
    [[ "$sonarr_min_free" -ge 1024 ]] \
        && pass "step 3 Sonarr: disk threshold ${sonarr_min_free}MB" \
        || fail "step 3 Sonarr: disk threshold ≥1024MB" "got ${sonarr_min_free}MB"
    if echo "$sonarr_dc" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
        pass "step 3 Sonarr: qBittorrent download client"
    else
        fail "step 3 Sonarr: qBittorrent download client"
    fi
    local sonarr_dc_cleanup
    sonarr_dc_cleanup=$(echo "$sonarr_dc" | python3 -c '
import sys, json
clients = json.load(sys.stdin)
qbt = next((c for c in clients if c.get("name") == "qBittorrent"), {})
rc = qbt.get("removeCompletedDownloads")
rf = qbt.get("removeFailedDownloads")
print("ok" if rc is True and rf is True else f"completed={rc} failed={rf}")' 2>/dev/null)
    [[ "$sonarr_dc_cleanup" == "ok" ]] \
        && pass "step 3 Sonarr: download client cleanup enabled" \
        || fail "step 3 Sonarr: download client cleanup enabled" "$sonarr_dc_cleanup"

    # Live test-connection: prove Sonarr can actually authenticate to and reach the
    # qBittorrent container, not merely that the client object is shaped right. Both
    # run inside the DinD stack, so this is hermetic (unlike a live-tracker search,
    # which is deliberately out of scope). Catches an upstream image change that keeps
    # the config API stable but breaks the runtime arr->download-client contract.
    local sonarr_dc_test
    sonarr_dc_test=$(dind_exec "curl -sf -X POST -H 'X-Api-Key: $SONARR_KEY' -H 'Content-Type: application/json' -d '{}' $sonarr_base/downloadclient/testall" \
        | python3 -c "
import sys, json
try: results = json.load(sys.stdin)
except Exception: results = []
if not results:
    print('empty')
else:
    bad = [str(r.get('id')) for r in results if not r.get('isValid')]
    print('ok' if not bad else 'invalid:' + ','.join(bad))" 2>/dev/null)
    case "$sonarr_dc_test" in
        ok) pass "step 3 Sonarr: download client reachable (testall connects to qBittorrent)" ;;
        empty) fail "step 3 Sonarr: download client test-connection" "testall returned no results" ;;
        *) fail "step 3 Sonarr: download client test-connection" "$sonarr_dc_test" ;;
    esac

    local sonarr_qp_id sonarr_qp_check
    sonarr_qp_id=$(echo "$sonarr_qp" | python3 -c "
import sys,json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='1080p Balanced'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$sonarr_qp_id" ]]; then
        sonarr_qp_check=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/qualityprofile/$sonarr_qp_id" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
        [[ "$sonarr_qp_check" == "1080p Balanced" ]] \
            && pass "step 3 Sonarr: 1080p Balanced quality profile" \
            || fail "step 3 Sonarr: 1080p Balanced quality profile" "id=$sonarr_qp_id check returned '$sonarr_qp_check'"
    else
        fail "step 3 Sonarr: 1080p Balanced quality profile" "no profile named 1080p Balanced in list response"
    fi

    # Custom formats
    local sonarr_cf_count
    sonarr_cf_count=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/customformat" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [[ -n "$sonarr_cf_count" && "$sonarr_cf_count" -ge 7 ]]; then
        pass "step 3 Sonarr: custom formats created ($sonarr_cf_count)"
    else
        fail "step 3 Sonarr: custom formats created" "got $sonarr_cf_count, expected ≥7"
    fi

    # Format scores on quality profile — verify exact values from config.yml
    if [[ -n "$sonarr_qp_id" ]]; then
        local sonarr_score_check
        sonarr_score_check=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/qualityprofile/$sonarr_qp_id" \
            | python3 -c "
import sys, json
p = json.load(sys.stdin)
expected = {
    'Repack/Proper': 5, 'LQ': -100, 'No-RlsGroup': -10, 'Obfuscated': -10
}
items = {fi['name']: fi['score'] for fi in p.get('formatItems', []) if fi.get('score', 0) != 0}
wrong = []
for name, score in expected.items():
    actual = items.get(name)
    if actual != score:
        wrong.append('%s: want %d got %s' % (name, score, actual))
extra = set(items) - set(expected)
if extra:
    wrong.append('unexpected scored: %s' % ', '.join(sorted(extra)))
if wrong:
    print('FAIL|' + '; '.join(wrong))
else:
    print('OK|%d formats scored correctly' % len(expected))
" 2>/dev/null)
        case "$sonarr_score_check" in
            OK*) pass "step 3 Sonarr: format scores match config.yml (${sonarr_score_check#OK|})" ;;
            FAIL*) fail "step 3 Sonarr: format scores match config.yml" "${sonarr_score_check#FAIL|}" ;;
            *) fail "step 3 Sonarr: format scores match config.yml" "parse error" ;;
        esac
    fi

    # Indexer registration and seed criteria against the DinD fixture (fail-closed,
    # shared helper in tests/assertions/arr-indexers.sh).
    arr_assert_indexers "step 3 Sonarr" sonarr "$sonarr_base" "$SONARR_KEY" "$configure_log" "general tv" 1

    local sonarr_qd_pref
    sonarr_qd_pref=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/qualitydefinition" \
        | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        if d.get('quality', {}).get('name') == 'HDTV-720p':
            print(d.get('preferredSize', ''))
            break
except Exception: pass" 2>/dev/null)
    # config.yml ships HDTV-720p preferred=30.0, tightened from Sonarr's default
    # of 95 MB/min to deliver real 1080p WEB-DL sizes (docs/setup/quality-bounds.md).
    if [[ "$sonarr_qd_pref" == "30" || "$sonarr_qd_pref" == "30.0" ]]; then
        pass "step 3 Sonarr: HDTV-720p preferredSize tightened to 30"
    else
        fail "step 3 Sonarr: HDTV-720p preferredSize tightened to 30" "got '$sonarr_qd_pref'"
    fi

    # Jellyfin connection (library update on import)
    local sonarr_jf_conn
    sonarr_jf_conn=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/notification" \
        | python3 -c "
import sys, json
try: items = json.load(sys.stdin)
except Exception: items = []
jf = next((n for n in items if n.get('implementation') == 'MediaBrowser'), None)
if jf is None:
    print('absent')
else:
    fields = {f['name']: f.get('value') for f in jf.get('fields', [])}
    update = fields.get('updateLibrary', False)
    on_import = jf.get('onImportComplete', False)
    if update and on_import:
        print('ok')
    else:
        print('misconfigured: updateLibrary=%s onImportComplete=%s' % (update, on_import))
" 2>/dev/null)
    case "$sonarr_jf_conn" in
        ok) pass "step 3 Sonarr: Jellyfin connection (library update on import)" ;;
        absent) fail "step 3 Sonarr: Jellyfin connection" "not configured" ;;
        *) fail "step 3 Sonarr: Jellyfin connection" "$sonarr_jf_conn" ;;
    esac

    # Forms authentication
    if ! svc_stripped sonarr; then
        local sonarr_auth_method
        sonarr_auth_method=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/config/host" \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authenticationMethod",""))' 2>/dev/null | tr -d '\r\n')
        [[ "$sonarr_auth_method" == "forms" ]] \
            && pass "step 3 Sonarr: Forms authentication enabled" \
            || fail "step 3 Sonarr: Forms authentication enabled" "got '$sonarr_auth_method'"
    fi
}

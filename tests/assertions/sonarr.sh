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
    'Repack/Proper': 5, 'x264': 10, 'x265 (HD)': -25,
    'BR-DISK': -10000, 'LQ': -10000, 'No-RlsGroup': -25, 'Obfuscated': -25
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
            OK*)  pass "step 3 Sonarr: format scores match config.yml (${sonarr_score_check#OK|})" ;;
            FAIL*) fail "step 3 Sonarr: format scores match config.yml" "${sonarr_score_check#FAIL|}" ;;
            *)    fail "step 3 Sonarr: format scores match config.yml" "parse error" ;;
        esac
    fi

    # Lower-bound check: extra indexers are good news (a previously-flaky
    # tracker came back online between runs). A real regression — silent
    # config drop, broken parser, all trackers down — would push count BELOW
    # the floor, which still fails. Hardcoded `==` here was brittle: warns
    # accumulate across drift re-runs, and a tracker recovering between
    # runs flipped the equality without anything actually breaking.
    local sonarr_ix_count sonarr_ix_warned sonarr_ix_floor
    sonarr_ix_count=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/indexer" \
        | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    sonarr_ix_warned=$(sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" \
        | { grep -Ec '(Failed:.*-> Sonarr|Indexer unavailable, skipped: .* -> Sonarr)' 2>/dev/null || true; })
    # Floor = total Sonarr-eligible indexers (general+tv) in config.yml
    # minus the warned-failures observed in this run. 13 happens to be the
    # current count (14 in config.yml minus 1 movies-only). Computed from
    # config.yml so adding/removing trackers won't desync the assertion.
    local sonarr_ix_total
    sonarr_ix_total=$(python3 -c "
import yaml
with open('config.yml') as f:
    c = yaml.safe_load(f)
n = sum(1 for i in (c.get('indexers') or []) if i.get('type') in ('general','tv'))
print(n)
" 2>/dev/null)
    sonarr_ix_floor=$(( sonarr_ix_total - sonarr_ix_warned ))
    if (( sonarr_ix_count >= sonarr_ix_floor )); then
        pass "step 3 Sonarr: $sonarr_ix_count/${sonarr_ix_total} indexers configured${sonarr_ix_warned:+ ($sonarr_ix_warned upstream-blocked, floor=$sonarr_ix_floor)}"
    else
        fail "step 3 Sonarr: $sonarr_ix_floor indexers expected (floor)" "got '$sonarr_ix_count' (warned=$sonarr_ix_warned, total=$sonarr_ix_total)"
    fi

    local sonarr_seed_check
    sonarr_seed_check=$(dind_exec "curl -sf -H 'X-Api-Key: $SONARR_KEY' $sonarr_base/indexer" \
        | python3 -c "
import sys, json
indexers = json.load(sys.stdin)
if not indexers:
    print('SKIP|no indexers')
    sys.exit()
wrong = []
for ix in indexers:
    fields = {f['name']: f.get('value') for f in ix.get('fields', [])}
    name = ix['name']
    ratio = fields.get('seedCriteria.seedRatio')
    time = fields.get('seedCriteria.seedTime')
    season = fields.get('seedCriteria.seasonPackSeedTime')
    if ratio != 1.0:
        wrong.append('%s: seedRatio=%s want 1.0' % (name, ratio))
    if time != 1440:
        wrong.append('%s: seedTime=%s want 1440' % (name, time))
    if season != 2880:
        wrong.append('%s: seasonPackSeedTime=%s want 2880' % (name, season))
if wrong:
    print('FAIL|' + '; '.join(wrong[:3]))
else:
    print('OK|%d indexers checked' % len(indexers))
" 2>/dev/null)
    case "$sonarr_seed_check" in
        OK*)   pass "step 3 Sonarr: indexer seed criteria (ratio=1.0, time=24h, season=48h) (${sonarr_seed_check#OK|})" ;;
        SKIP*) skip "step 3 Sonarr: indexer seed criteria" "${sonarr_seed_check#SKIP|}" ;;
        FAIL*) fail "step 3 Sonarr: indexer seed criteria" "${sonarr_seed_check#FAIL|}" ;;
        *)     fail "step 3 Sonarr: indexer seed criteria" "parse error" ;;
    esac

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
    # config.yml ships HDTV-720p preferred=30.0 (was 67.5 before ADR-25);
    # tightened from Sonarr's default of 95 MB/min to deliver real 1080p WEB-DL
    # sizes per the recalibration in ADR-25.
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
        ok)      pass "step 3 Sonarr: Jellyfin connection (library update on import)" ;;
        absent)  fail "step 3 Sonarr: Jellyfin connection" "not configured" ;;
        *)       fail "step 3 Sonarr: Jellyfin connection" "$sonarr_jf_conn" ;;
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

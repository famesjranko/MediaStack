assert_radarr_configured() {
    local configure_log="$1"

    RADARR_KEY=$(get_api_key_from_xml "config/radarr/config.xml")
    [[ -n "$RADARR_KEY" ]] && pass "step 4 Radarr: API key present" || fail "step 4 Radarr: API key present"

    local radarr_base="http://localhost:7878/api/v3"
    local radarr_rf radarr_dc radarr_qp
    radarr_rf=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/rootfolder")
    radarr_dc=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/downloadclient")
    radarr_qp=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/qualityprofile")
    assert_contains "$radarr_rf" '/data/media/movies' "step 4 Radarr: rootfolder /data/media/movies"

    local radarr_mm radarr_min_free
    radarr_mm=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/config/mediamanagement")
    radarr_min_free=$(echo "$radarr_mm" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("minimumFreeSpaceWhenImporting", 0))
except Exception: print(0)' 2>/dev/null)
    [[ "$radarr_min_free" -ge 1024 ]] \
        && pass "step 4 Radarr: disk threshold ${radarr_min_free}MB" \
        || fail "step 4 Radarr: disk threshold ≥1024MB" "got ${radarr_min_free}MB"
    if echo "$radarr_dc" | grep -qE '"name"\s*:\s*"qBittorrent"'; then
        pass "step 4 Radarr: qBittorrent download client"
    else
        fail "step 4 Radarr: qBittorrent download client"
    fi
    local radarr_dc_cleanup
    radarr_dc_cleanup=$(echo "$radarr_dc" | python3 -c '
import sys, json
clients = json.load(sys.stdin)
qbt = next((c for c in clients if c.get("name") == "qBittorrent"), {})
rc = qbt.get("removeCompletedDownloads")
rf = qbt.get("removeFailedDownloads")
print("ok" if rc is True and rf is True else f"completed={rc} failed={rf}")' 2>/dev/null)
    [[ "$radarr_dc_cleanup" == "ok" ]] \
        && pass "step 4 Radarr: download client cleanup enabled" \
        || fail "step 4 Radarr: download client cleanup enabled" "$radarr_dc_cleanup"
    local radarr_qp_id radarr_qp_check
    radarr_qp_id=$(echo "$radarr_qp" | python3 -c "
import sys,json
try: print(next((str(p['id']) for p in json.load(sys.stdin) if p.get('name')=='1080p Balanced'),''))
except Exception: pass" 2>/dev/null)
    if [[ -n "$radarr_qp_id" ]]; then
        radarr_qp_check=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/qualityprofile/$radarr_qp_id" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
        [[ "$radarr_qp_check" == "1080p Balanced" ]] \
            && pass "step 4 Radarr: 1080p Balanced quality profile" \
            || fail "step 4 Radarr: 1080p Balanced quality profile" "id=$radarr_qp_id check returned '$radarr_qp_check'"
    else
        fail "step 4 Radarr: 1080p Balanced quality profile" "no profile named 1080p Balanced in list response"
    fi

    # Custom formats
    local radarr_cf_count
    radarr_cf_count=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/customformat" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [[ -n "$radarr_cf_count" && "$radarr_cf_count" -ge 7 ]]; then
        pass "step 4 Radarr: custom formats created ($radarr_cf_count)"
    else
        fail "step 4 Radarr: custom formats created" "got $radarr_cf_count, expected ≥7"
    fi

    # Format scores on quality profile — verify exact values from config.yml
    if [[ -n "$radarr_qp_id" ]]; then
        local radarr_score_check
        radarr_score_check=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/qualityprofile/$radarr_qp_id" \
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
        case "$radarr_score_check" in
            OK*)  pass "step 4 Radarr: format scores match config.yml (${radarr_score_check#OK|})" ;;
            FAIL*) fail "step 4 Radarr: format scores match config.yml" "${radarr_score_check#FAIL|}" ;;
            *)    fail "step 4 Radarr: format scores match config.yml" "parse error" ;;
        esac
    fi

    # Lower-bound check — see sonarr.sh for rationale.
    local radarr_ix_count radarr_ix_warned radarr_ix_floor radarr_ix_total
    radarr_ix_count=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/indexer" \
        | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    radarr_ix_warned=$(sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" \
        | { grep -Ec '(Failed:.*-> Radarr|Indexer unavailable, skipped: .* -> Radarr)' 2>/dev/null || true; })
    radarr_ix_total=$(python3 -c "
import yaml
with open('config.yml') as f:
    c = yaml.safe_load(f)
n = sum(1 for i in (c.get('indexers') or []) if i.get('type') in ('general','movies'))
print(n)
" 2>/dev/null)
    radarr_ix_floor=$(( radarr_ix_total - radarr_ix_warned ))
    if (( radarr_ix_count >= radarr_ix_floor )); then
        pass "step 4 Radarr: $radarr_ix_count/${radarr_ix_total} indexers configured${radarr_ix_warned:+ ($radarr_ix_warned upstream-blocked, floor=$radarr_ix_floor)}"
    else
        fail "step 4 Radarr: $radarr_ix_floor indexers expected (floor)" "got '$radarr_ix_count' (warned=$radarr_ix_warned, total=$radarr_ix_total)"
    fi

    local radarr_seed_check
    radarr_seed_check=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/indexer" \
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
    if ratio != 1.0:
        wrong.append('%s: seedRatio=%s want 1.0' % (name, ratio))
    if time != 1440:
        wrong.append('%s: seedTime=%s want 1440' % (name, time))
if wrong:
    print('FAIL|' + '; '.join(wrong[:3]))
else:
    print('OK|%d indexers checked' % len(indexers))
" 2>/dev/null)
    case "$radarr_seed_check" in
        OK*)   pass "step 4 Radarr: indexer seed criteria (ratio=1.0, time=24h) (${radarr_seed_check#OK|})" ;;
        SKIP*) skip "step 4 Radarr: indexer seed criteria" "${radarr_seed_check#SKIP|}" ;;
        FAIL*) fail "step 4 Radarr: indexer seed criteria" "${radarr_seed_check#FAIL|}" ;;
        *)     fail "step 4 Radarr: indexer seed criteria" "parse error" ;;
    esac

    # ADR-25 dropped Remux-1080p from config.yml entirely (real 1080p WEB-DL
    # sizes, no Remux anywhere in the stack). Use Bluray-1080p as the
    # representative tightened-from-stock check: shipped preferred=65.0 vs
    # Radarr's stock default of ~95 MB/min.
    local radarr_qd_pref
    radarr_qd_pref=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/qualitydefinition" \
        | python3 -c "
import sys, json
try:
    for d in json.load(sys.stdin):
        if d.get('quality', {}).get('name') == 'Bluray-1080p':
            print(d.get('preferredSize', ''))
            break
except Exception: pass" 2>/dev/null)
    if [[ "$radarr_qd_pref" == "65" || "$radarr_qd_pref" == "65.0" ]]; then
        pass "step 4 Radarr: Bluray-1080p preferredSize tightened to 65"
    else
        fail "step 4 Radarr: Bluray-1080p preferredSize tightened to 65" "got '$radarr_qd_pref'"
    fi

    # Jellyfin connection (library update on import)
    local radarr_jf_conn
    radarr_jf_conn=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/notification" \
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
    on_download = jf.get('onDownload', False)
    if update and on_download:
        print('ok')
    else:
        print('misconfigured: updateLibrary=%s onDownload=%s' % (update, on_download))
" 2>/dev/null)
    case "$radarr_jf_conn" in
        ok)      pass "step 4 Radarr: Jellyfin connection (library update on download)" ;;
        absent)  fail "step 4 Radarr: Jellyfin connection" "not configured" ;;
        *)       fail "step 4 Radarr: Jellyfin connection" "$radarr_jf_conn" ;;
    esac

    # Forms authentication
    if ! svc_stripped radarr; then
        local radarr_auth_method
        radarr_auth_method=$(dind_exec "curl -sf -H 'X-Api-Key: $RADARR_KEY' $radarr_base/config/host" \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authenticationMethod",""))' 2>/dev/null | tr -d '\r\n')
        [[ "$radarr_auth_method" == "forms" ]] \
            && pass "step 4 Radarr: Forms authentication enabled" \
            || fail "step 4 Radarr: Forms authentication enabled" "got '$radarr_auth_method'"
    fi
}

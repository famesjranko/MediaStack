assert_bazarr_configured() {
    local configure_log="${1:-}"

    if [[ -n "$configure_log" && -f "$configure_log" ]]; then
        local bazarr_warnings
        bazarr_warnings=$(sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" \
            | grep -E '^\[WARN\].*(Bazarr|Sonarr API key not available|Radarr API key not available|language profile)' || true)
        if [[ -z "$bazarr_warnings" ]]; then
            pass "Bazarr: configure run has no Bazarr warnings"
        else
            fail "Bazarr: configure run has no Bazarr warnings" "$bazarr_warnings"
        fi
    fi

    local bazarr_key
    if bazarr_key=$(
        docker exec -i -w /root/MediaStack "$DIND_NAME" python3 <<'PY'
import yaml

with open("config/bazarr/config/config.yaml", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
print((data.get("auth") or {}).get("apikey") or "", end="")
PY
    ); then
        if [[ -n "$bazarr_key" ]]; then
            pass "Bazarr: API key present (${bazarr_key:0:8}...)"
        else
            fail "Bazarr: API key present" "empty auth.apikey"
        fi
    else
        fail "Bazarr: API key present" "could not read config/bazarr/config/config.yaml"
        return 0
    fi

    local settings
    if settings=$(docker exec -i -w /root/MediaStack -e BAZARR_KEY="$bazarr_key" "$DIND_NAME" \
        bash -lc 'curl -sf --max-time 20 -H "X-API-KEY: $BAZARR_KEY" http://localhost:6767/api/system/settings'); then
        pass "Bazarr: /api/system/settings answers with API key"
    else
        fail "Bazarr: /api/system/settings answers with API key"
        return 0
    fi

    local sonarr_key radarr_key
    sonarr_key=$(get_api_key_from_xml "config/sonarr/config.xml")
    radarr_key=$(get_api_key_from_xml "config/radarr/config.xml")
    [[ -n "$sonarr_key" ]] && pass "Bazarr: Sonarr source API key present" || fail "Bazarr: Sonarr source API key present"
    [[ -n "$radarr_key" ]] && pass "Bazarr: Radarr source API key present" || fail "Bazarr: Radarr source API key present"

    local settings_check
    settings_check=$(
        BAZARR_SETTINGS="$settings" SONARR_KEY="$sonarr_key" RADARR_KEY="$radarr_key" python3 <<'PY'
import json
import os

data = json.loads(os.environ["BAZARR_SETTINGS"])
expected = {
    "sonarr.apikey": os.environ["SONARR_KEY"],
    "sonarr.ip": "sonarr",
    "sonarr.port": "8989",
    "radarr.apikey": os.environ["RADARR_KEY"],
    "radarr.ip": "radarr",
    "radarr.port": "7878",
}

wrong = []
for path, want in expected.items():
    section, key = path.split(".", 1)
    got = (data.get(section) or {}).get(key)
    if str(got) != str(want):
        wrong.append(f"{path}: want {want!r} got {got!r}")

for path in ("general.use_sonarr", "general.use_radarr"):
    section, key = path.split(".", 1)
    got = (data.get(section) or {}).get(key)
    if got is not True and str(got) != "True":
        wrong.append(f"{path}: want True got {got!r}")

if wrong:
    print("FAIL|" + "; ".join(wrong))
else:
    print("OK|Sonarr/Radarr connection settings match generated keys")
PY
    )
    case "$settings_check" in
        OK*) pass "Bazarr: ${settings_check#OK|}" ;;
        FAIL*) fail "Bazarr: connection settings match generated keys" "${settings_check#FAIL|}" ;;
        *) fail "Bazarr: connection settings match generated keys" "parse error" ;;
    esac

    local profile_check
    if profile_check=$(
        docker exec -i -w /root/MediaStack "$DIND_NAME" python3 <<'PY'
import json
import sqlite3
import yaml

LANG_MAP = {
    "english": {"code2": "en", "code3": "eng"},
    "spanish": {"code2": "es", "code3": "spa"},
    "french": {"code2": "fr", "code3": "fre"},
    "german": {"code2": "de", "code3": "ger"},
    "portuguese": {"code2": "pt", "code3": "por"},
    "dutch": {"code2": "nl", "code3": "dut"},
    "italian": {"code2": "it", "code3": "ita"},
    "japanese": {"code2": "ja", "code3": "jpn"},
    "chinese": {"code2": "zh", "code3": "chi"},
    "korean": {"code2": "ko", "code3": "kor"},
    "arabic": {"code2": "ar", "code3": "ara"},
    "russian": {"code2": "ru", "code3": "rus"},
    "swedish": {"code2": "sv", "code3": "swe"},
    "norwegian": {"code2": "no", "code3": "nor"},
    "danish": {"code2": "da", "code3": "dan"},
    "finnish": {"code2": "fi", "code3": "fin"},
    "polish": {"code2": "pl", "code3": "pol"},
    "turkish": {"code2": "tr", "code3": "tur"},
    "hindi": {"code2": "hi", "code3": "hin"},
}

with open("config.yml", encoding="utf-8") as fh:
    config = yaml.safe_load(fh) or {}
langs = [str(lang).strip() for lang in (config.get("bazarr") or {}).get("languages", []) if str(lang).strip()]
if not langs:
    langs = ["english"]

unknown = [lang for lang in langs if lang not in LANG_MAP]
if unknown:
    print("FAIL|unknown languages in config.yml: " + ", ".join(unknown))
    raise SystemExit(0)

expected_name = " + ".join(lang.title() for lang in langs)
expected_items = []
item_id = 1
for lang in langs:
    info = LANG_MAP[lang]
    for forced in ("True", "False"):
        expected_items.append({
            "id": item_id,
            "language": info["code2"],
            "forced": forced,
            "hi": "False",
            "audio_exclude": "False",
        })
        item_id += 1

conn = sqlite3.connect("config/bazarr/db/bazarr.db")
enabled = dict(conn.execute("SELECT code3, enabled FROM table_settings_languages").fetchall())
profiles = conn.execute("SELECT name, items FROM table_languages_profiles ORDER BY profileId").fetchall()
conn.close()

wrong = []
for lang in langs:
    code3 = LANG_MAP[lang]["code3"]
    if str(enabled.get(code3)) not in ("1", "True", "true"):
        wrong.append(f"{code3} enabled={enabled.get(code3)!r}")

matching = [(name, items) for name, items in profiles if name == expected_name]
if not matching:
    wrong.append(f"profile {expected_name!r} not found")
else:
    try:
        items = json.loads(matching[0][1])
    except Exception as exc:
        wrong.append(f"profile items invalid JSON: {exc}")
    else:
        if items != expected_items:
            wrong.append(f"profile items want {expected_items!r} got {items!r}")

if wrong:
    print("FAIL|" + "; ".join(wrong))
else:
    print(f"OK|{expected_name} language profile seeded")
PY
    ); then
        case "$profile_check" in
            OK*) pass "Bazarr: ${profile_check#OK|}" ;;
            FAIL*) fail "Bazarr: language profile seeded from config.yml" "${profile_check#FAIL|}" ;;
            *) fail "Bazarr: language profile seeded from config.yml" "parse error" ;;
        esac
    else
        fail "Bazarr: language profile seeded from config.yml" "could not inspect Bazarr database"
    fi
}

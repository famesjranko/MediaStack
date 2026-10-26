# tests/scenarios/drift-recovery.sh — recovery advice for a finished install (#105).
#
# Builds a finished install in DinD (Jellyfin, Sonarr, Radarr, qBittorrent),
# induces stale persisted configuration, and follows each instruction that the
# drift messages give: keep the live setting, reapply config.yml, or reset on
# purpose. `docker compose down -v` is not one of them: it keeps config/<service>.
#
# Needs the Jellyfin, Sonarr, Radarr and qBittorrent images (pulled in DinD).

# Test double for the app UIs: runs inside DinD and uses the apps' own HTTP APIs.
drift_install_api_helper() {
    docker exec -i -w /root/MediaStack "$DIND_NAME" sh -c 'cat >/tmp/drift-api.py' <<'PY'
import json, sys, urllib.parse, urllib.request

def env(key):
    for line in open(".env"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip("'\"")

def call(app, method, path, body=None):
    if app == "jellyfin":
        url, hdr = "http://127.0.0.1:8096" + path, {"Authorization": 'MediaBrowser Token="%s"' % env("JELLYFIN_API_KEY")}
    else:
        port = {"sonarr": 8989, "radarr": 7878}[app]
        url, hdr = "http://127.0.0.1:%d/api/v3%s" % (port, path), {"X-Api-Key": env(app.upper() + "_API_KEY")}
    data = json.dumps(body).encode() if body is not None else None
    if data:
        hdr["Content-Type"] = "application/json"
    with urllib.request.urlopen(urllib.request.Request(url, data, hdr, method=method)) as r:
        raw = r.read()
    return json.loads(raw) if raw else None

def profile(name):
    return next(p for p in call(app, "GET", "/qualityprofile") if p["name"] == name)

app, cmd, *args = sys.argv[1:]
if cmd == "root-folders":
    print(",".join(r["path"] for r in call(app, "GET", "/rootfolder")))
elif cmd == "root-folders-clear":
    for r in call(app, "GET", "/rootfolder"):
        call(app, "DELETE", "/rootfolder/%d" % r["id"])
elif cmd in ("category", "category-set"):
    field = "tvCategory" if app == "sonarr" else "movieCategory"
    dc = next(c for c in call(app, "GET", "/downloadclient") if c["name"] == "qBittorrent")
    fld = next(f for f in dc["fields"] if f["name"] == field)
    if cmd == "category":
        print(fld["value"])
    else:
        fld["value"] = args[0]
        call(app, "PUT", "/downloadclient/%d?forceSave=true" % dc["id"], dc)
elif cmd == "profiles":
    print(";".join("%d:%s:%s" % (p["id"], p["name"], p["upgradeAllowed"]) for p in call(app, "GET", "/qualityprofile")))
elif cmd == "profile-upgrade-flip":
    p = profile(args[0])
    p["upgradeAllowed"] = not p["upgradeAllowed"]
    call(app, "PUT", "/qualityprofile/%d" % p["id"], p)
elif cmd == "profile-rename":
    p = profile(args[0])
    p["name"] = args[1]
    call(app, "PUT", "/qualityprofile/%d" % p["id"], p)
elif cmd == "scores":
    print(",".join("%s=%s" % (i["name"], i["score"]) for i in profile(args[0])["formatItems"] if i["score"]))
elif cmd in ("scores-bump", "scores-zero"):
    p = profile(args[0])
    for item in p["formatItems"]:
        item["score"] = 0 if cmd == "scores-zero" else item["score"] + 7
    call(app, "PUT", "/qualityprofile/%d" % p["id"], p)
elif cmd == "libraries":
    print(";".join("%s=%s" % (v["Name"], (v["Locations"] or [""])[0]) for v in call("jellyfin", "GET", "/Library/VirtualFolders")))
elif cmd == "library-remove":
    call("jellyfin", "DELETE", "/Library/VirtualFolders?name=%s&refreshLibrary=false" % urllib.parse.quote(args[0]))
elif cmd == "episodes":
    uid = call("jellyfin", "GET", "/Users")[0]["Id"]
    q = "/Items?Recursive=true&IncludeItemTypes=Episode&Fields=Path&UserId=" + uid
    print(";".join("%s=%s" % (i["Path"], i["UserData"]["Played"]) for i in call("jellyfin", "GET", q)["Items"]))
elif cmd == "episode-play":
    uid = call("jellyfin", "GET", "/Users")[0]["Id"]
    for i in call("jellyfin", "GET", "/Items?Recursive=true&IncludeItemTypes=Episode&UserId=" + uid)["Items"]:
        call("jellyfin", "POST", "/UserPlayedItems/%s?userId=%s" % (i["Id"], uid))
elif cmd == "scan":
    call("jellyfin", "POST", "/Library/Refresh")
PY
}

# Arguments are single-quoted for the DinD shell so names with spaces stay whole.
drift_api() {
    local arg quoted=""
    for arg in "$@"; do quoted+=" '$arg'"; done
    dind_exec "python3 /tmp/drift-api.py$quoted" | tr -d '\r'
}

# Output of configure.sh for the given services, colours stripped.
drift_configure() {
    dind_exec "./scripts/configure.sh --only $1 2>&1" | sed -r 's/\x1b\[[0-9;]*m//g'
}

# Sonarr's profile names as ",a,b,"; a rename in place keeps the count, a duplicate adds one.
drift_profile_names() {
    printf ',%s' "$(drift_api sonarr profiles | tr ';' '\n' | cut -d: -f2 | sort | tr '\n' ',')"
}

# assert_profile_named <name> <count> <label>
assert_profile_named() {
    local names
    names=$(drift_profile_names)
    assert_contains "$names" ",$1," "$3: the profile is named '$1'"
    assert_eq "$2" "$(printf '%s' "$names" | tr -cd ',' | wc -c)" "$3: no duplicate profile"
}

drift_cfg_set() { # <config.yml line-anchored sed expression>
    dind_exec "sed -i '$1' config.yml"
}

drift_wait_all_healthy() {
    local svc
    for svc in qbittorrent jellyfin sonarr radarr; do
        wait_healthy "$svc" 300 || return 1
    done
}

drift_jellyfin_ready() {
    for _ in $(seq 1 30); do
        dind_exec "curl -fsS http://127.0.0.1:8096/health >/dev/null" && return 0
        sleep 2
    done
    return 1
}

# A finished install: configured services, STAGE_1_COMPLETE=1, and one watched
# episode in a TV library. /data/media/tv-new is the alternative path.
drift_build_install() {
    dind_exec "docker compose --profile '*' down -v --remove-orphans 2>/dev/null; rm -rf config/jellyfin config/sonarr config/radarr config/qbittorrent /tmp/ms-data; true"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/tv-new /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete"
    dind_exec "rm -f .env config.yml"
    create_config_dirs_in_dind
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@drift.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD drift-test-password
    env_set JELLYFIN_GPU none
    env_set DOMAIN ""
    env_set REMOTE_WEB_STATE ""
    env_set WG_INIT_PASSWORD "''"
    local show='/data/media/tv/Drift Show/Season 01/Drift Show - S01E01.mkv'
    dind_exec "mkdir -p '/tmp/ms-data/media/tv/Drift Show/Season 01' && docker run --rm -v /tmp/ms-data:/data --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg jellyfin/jellyfin:latest -v error -f lavfi -i testsrc=duration=2:size=160x120:rate=10 -c:v mpeg4 -y '$show'"
    dind_exec "cp -a '/tmp/ms-data/media/tv/Drift Show' /tmp/ms-data/media/tv-new/ && chown -R 1000:1000 /tmp/ms-data"
    dind_exec "docker compose up -d --no-deps qbittorrent jellyfin sonarr radarr >/dev/null 2>&1"
    drift_wait_all_healthy || return 1
    drift_install_api_helper
    drift_configure qbittorrent,sonarr,radarr,jellyfin >/tmp/drift-fixture.out
    env_set STAGE_1_COMPLETE 1
    drift_api jellyfin scan
    for _ in $(seq 1 20); do
        [[ "$(drift_api jellyfin episodes)" == *"Drift Show"* ]] && break
        sleep 3
    done
    drift_api jellyfin episode-play
}

drift_root_folder_cases() {
    drift_cfg_set 's#^  root_folder: "/data/media/tv"#  root_folder: "/data/media/tv-new"#'
    local out
    # Given Sonarr holds /data/media/tv while config.yml names /data/media/tv-new.
    out=$(drift_configure sonarr)
    # When the drift notice is read.
    # Then it offers keeping the live folder or reapplying config.yml, and never down -v.
    assert_contains "$out" "set sonarr.root_folder in config.yml to the live path" "root folder: notice offers the keep path"
    assert_contains "$out" "then run ./scripts/configure.sh --only sonarr" "root folder: notice offers the reapply path"
    assert_not_contains "$out" "down -v" "root folder: notice does not recommend down -v"

    # Given the keep path: config.yml names the live folder.
    drift_cfg_set 's#^  root_folder: "/data/media/tv-new"#  root_folder: "/data/media/tv"#'
    # When configuration runs again.
    out=$(drift_configure sonarr)
    # Then the folder matches and Sonarr still has its folder.
    assert_contains "$out" "root folder /data/media/tv already matches config.yml" "root folder keep path: configure matches"

    # Given the reapply path: config.yml names the new folder and the live entry is deleted.
    drift_cfg_set 's#^  root_folder: "/data/media/tv"#  root_folder: "/data/media/tv-new"#'
    drift_api sonarr root-folders-clear
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then Sonarr holds the config.yml folder and the media stays.
    assert_eq "/data/media/tv-new" "$(drift_api sonarr root-folders)" "root folder reapply path: Sonarr holds the config.yml folder"
    if dind_exec "test -f '/tmp/ms-data/media/tv/Drift Show/Season 01/Drift Show - S01E01.mkv'"; then
        pass "root folder reapply path: media files stay"
    else
        fail "root folder reapply path: media files stay"
    fi
    # And the app runs and answers.
    wait_healthy sonarr 120 && pass "root folder reapply path: Sonarr passes its health check" \
        || fail "root folder reapply path: Sonarr passes its health check"
    drift_cfg_set 's#^  root_folder: "/data/media/tv-new"#  root_folder: "/data/media/tv"#'
}

drift_category_cases() {
    local out
    # Given Sonarr holds a category that config.yml does not name.
    drift_api sonarr category-set tv-live
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the notice offers both paths.
    assert_contains "$out" "set sonarr.download_client_category in config.yml to it" "category: notice offers the keep path"
    assert_not_contains "$out" "down -v" "category: notice does not recommend down -v"

    # Given the keep path: config.yml names the live category.
    drift_cfg_set 's#^\(  download_client_category: "\)tv-sonarr"#\1tv-live"#'
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the category matches.
    assert_contains "$out" "qBittorrent category already matches config.yml (tv-live)" "category keep path: configure matches"

    # Given the reapply path: config.yml names tv-sonarr and the app is edited to match.
    drift_cfg_set 's#^\(  download_client_category: "\)tv-live"#\1tv-sonarr"#'
    drift_api sonarr category-set tv-sonarr
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the category matches again.
    assert_contains "$out" "qBittorrent category already matches config.yml (tv-sonarr)" "category reapply path: configure matches"
}

drift_profile_cases() {
    local out name count
    name=$(dind_exec "sed -n 's/^  name: \"\\(.*\\)\"/\\1/p' config.yml | head -1" | tr -d '\r')
    assert_eq "1080p Balanced" "$name" "profile: the fixture profile is the config.yml profile"
    # Given a profile whose upgrade setting differs from config.yml.
    drift_api sonarr profile-upgrade-flip "$name"
    # When configuration runs twice.
    out=$(drift_configure sonarr)
    out+=$(drift_configure sonarr)
    # Then the notice offers keeping the profile and repeats; nothing is rebuilt.
    assert_contains "$out" "To keep the live profile: do nothing; this notice repeats on each configure run" "profile: notice offers the keep path"
    assert_not_contains "$out" "down -v" "profile: notice does not recommend down -v"

    # Given the reapply path: the profile is edited in the app to match.
    drift_api sonarr profile-upgrade-flip "$name"
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the profile matches.
    assert_contains "$out" "quality profile '$name' already matches your settings" "profile reapply path: configure matches"

    # Given a profile renamed in the app and a re-push that expects the old name.
    count=$(drift_profile_names | tr -cd ',' | wc -c)
    drift_api sonarr profile-rename "$name" Renamed
    drift_cfg_set 's#^  name: "'"$name"'"#  name: "New name"#'
    # When Change quality profile re-pushes with the old name as the source.
    out=$(dind_exec "QP_RENAME_FROM='$name' ./scripts/configure.sh --only sonarr 2>&1" | sed -r 's/\x1b\[[0-9;]*m//g')
    # Then the warning offers renaming back or keeping the new name, and creates no duplicate.
    assert_contains "$out" "rename it back to '$name'" "profile rename: warning offers the retry path"
    assert_contains "$out" "set quality_profile.name in config.yml to that name first" "profile rename: warning offers the keep path"
    assert_not_contains "$out" "down -v" "profile rename: warning does not recommend down -v"
    assert_profile_named Renamed "$count" "profile rename"

    # Given the retry path: the profile is renamed back.
    drift_api sonarr profile-rename Renamed "$name"
    # When the re-push runs again.
    dind_exec "QP_RENAME_FROM='$name' ./scripts/configure.sh --only sonarr >/dev/null 2>&1"
    # Then the same profile carries the new name.
    assert_profile_named "New name" "$count" "profile rename retry path"

    # Given the keep path: config.yml names the profile under its renamed name.
    drift_api sonarr profile-rename "New name" Renamed
    drift_cfg_set 's#^  name: "New name"#  name: "Renamed"#'
    # When configuration runs, and then a re-push renames that profile again.
    out=$(drift_configure sonarr)
    drift_cfg_set 's#^  name: "Renamed"#  name: "Newer name"#'
    dind_exec "QP_RENAME_FROM=Renamed ./scripts/configure.sh --only sonarr >/dev/null 2>&1"
    # Then the renamed profile matched and the re-push renamed it in place.
    assert_contains "$out" "quality profile 'Renamed' already matches your settings" "profile rename keep path: configure matches the kept name"
    assert_profile_named "Newer name" "$count" "profile rename keep path"
    drift_api sonarr profile-rename "Newer name" "$name"
    drift_cfg_set 's#^  name: "Newer name"#  name: "'"$name"'"#'
}

drift_scores_cases() {
    local out
    # Given a custom-format score that differs from config.yml.
    drift_api sonarr scores-bump "1080p Balanced"
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the notice offers keeping the scores or zeroing them to reapply.
    assert_contains "$out" "To keep the live scores: do nothing" "scores: notice offers the keep path"
    assert_not_contains "$out" "down -v" "scores: notice does not recommend down -v"

    # Given the reapply path: every score in the profile is set to 0.
    drift_api sonarr scores-zero "1080p Balanced"
    # When configuration runs.
    out=$(drift_configure sonarr)
    # Then the config.yml scores are attached again.
    assert_contains "$out" "Format scores attached to profile" "scores reapply path: config.yml scores are attached"
    [[ -n "$(drift_api sonarr scores "1080p Balanced")" ]] && pass "scores reapply path: the profile carries scores again" \
        || fail "scores reapply path: the profile carries scores again"
}

drift_library_cases() {
    local out played
    played=$(drift_api jellyfin episodes)
    assert_contains "$played" "/data/media/tv/Drift Show/Season 01/Drift Show - S01E01.mkv=True" "library: the fixture episode is watched"
    # Given a TV library whose live path differs from config.yml.
    drift_cfg_set 's#^\(      path: "/data/media/tv\)"#\1-new"#'
    # When configuration runs.
    out=$(drift_configure jellyfin)
    # Then the notice offers both paths and names the history it loses.
    assert_contains "$out" "set that library's path in config.yml to the live path" "library: notice offers the keep path"
    assert_contains "$out" "start without watch history" "library: notice names the history it loses"
    assert_not_contains "$out" "down -v" "library: notice does not recommend down -v"

    # Given the keep path: config.yml names the live library path.
    drift_cfg_set 's#^\(      path: "/data/media/tv\)-new"#\1"#'
    # When configuration runs again.
    out=$(drift_configure jellyfin)
    # Then the drift notice is gone and the library is unchanged.
    assert_not_contains "$out" "set that library's path in config.yml to the live path" "library keep path: the drift notice is gone"
    assert_contains "$(drift_api jellyfin libraries)" "TV Shows=/data/media/tv" "library keep path: the library keeps its live path"
    assert_not_contains "$(drift_api jellyfin libraries)" "tv-new" "library keep path: the library is unchanged"

    # Given the reapply path: config.yml names the new path, the library is removed and configuration runs.
    drift_cfg_set 's#^\(      path: "/data/media/tv\)"#\1-new"#'
    drift_api jellyfin library-remove "TV Shows"
    out=$(drift_configure jellyfin)
    drift_api jellyfin scan
    for _ in $(seq 1 20); do
        [[ "$(drift_api jellyfin episodes)" == *"tv-new"* ]] && break
        sleep 3
    done
    # Then the library holds the config.yml path, the items there start unwatched, and Jellyfin is healthy.
    assert_contains "$(drift_api jellyfin libraries)" "TV Shows=/data/media/tv-new" "library reapply path: the library holds the config.yml path"
    assert_contains "$(drift_api jellyfin episodes)" "/data/media/tv-new/Drift Show/Season 01/Drift Show - S01E01.mkv=False" "library reapply path: items at the new path start unwatched"
    assert_contains "$(drift_api jellyfin libraries)" "Movies=/data/media/movies" "library reapply path: the other library stays"
    drift_jellyfin_ready && pass "library reapply path: Jellyfin passes its health check" \
        || fail "library reapply path: Jellyfin passes its health check"
}

# The advice that #105 replaced: down -v keeps config/<service>, so the finished
# install stays finished, and the completed-install route says what to do instead.
drift_down_v_cases() {
    local before after out
    before=$(dind_exec "sha256sum config/sonarr/config.xml | cut -d' ' -f1")
    # Given a finished install.
    # When the stack is brought down with -v and the installer route runs.
    dind_exec "docker compose --profile '*' down -v --remove-orphans >/dev/null 2>&1"
    out=$(dind_exec "bash -lc '
set -uo pipefail
source setup.sh
check_not_root() { :; }; check_debian() { :; }; check_disk_floor() { :; }; check_internet_reachability() { :; }; check_ram_warn() { :; }
prompt_sudo_cache() { :; }; stash_gpu_type() { GPU_TYPE=none; }; install_base_packages() { :; }; install_docker() { :; }
check_docker() { :; }; check_compose() { :; }; cleanup_post_reboot() { :; }; detect_host_memory() { HOST_MEMORY_MB=8192; }
setup_hardening() { :; }; record_pre_install_state() { :; }; setup_ufw_service_ports() { :; }; setup_samba() { :; }
print_access_info() { :; }; run_stage2() { :; }; run_stage3() { :; }
main
' </dev/null 2>&1" | sed -r 's/\x1b\[[0-9;]*m//g')
    # Then the service databases and markers survive, and the route names the supported steps.
    after=$(dind_exec "sha256sum config/sonarr/config.xml | cut -d' ' -f1")
    assert_eq "$before" "$after" "down -v: config/sonarr survives"
    dind_exec "test -s config/sonarr/sonarr.db" && pass "down -v: the Sonarr database survives" || fail "down -v: the Sonarr database survives"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "down -v: the Stage 1 marker survives"
    assert_contains "$out" "Stage 1 already complete" "install route: skips a finished install"
    assert_contains "$out" "./scripts/configure.sh" "install route: names configure.sh to reapply config.yml"
    assert_contains "$out" "Uninstall MediaStack" "install route: names Uninstall as the reset"
    assert_not_contains "$out" "down -v" "install route: does not recommend down -v"

    # Given the stack is down, the day-2 start brings it back (same service set as the fixture).
    dind_exec "docker compose up -d --no-deps qbittorrent jellyfin sonarr radarr >/dev/null 2>&1"
    # When the services start.
    # Then they pass their health checks and configuration still applies.
    drift_wait_all_healthy && pass "down -v: services start from the surviving config and pass their health checks" \
        || fail "down -v: services start from the surviving config and pass their health checks"
    out=$(drift_configure sonarr,radarr,jellyfin)
    assert_contains "$out" "Auto-configuration complete" "down -v: configure runs against the surviving config"
}

# Intentional reset: Uninstall MediaStack removes config/, .env and config.yml and
# keeps the media; a new install then starts without the old databases.
drift_reset_cases() {
    local out api_key_before
    api_key_before=$(env_get SONARR_API_KEY)
    # Given a finished install with an ownership ledger.
    dind_exec "mkdir -p /etc/mediastack && printf 'STATE_FORMAT=1\nUFW_RULES_BEFORE_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nUFW_DEFAULT_INCOMING=deny\nUFW_DEFAULT_OUTGOING=allow\nUFW_DEFAULTS_APPLIED=false\nUFW_ENABLED_BY_MEDIASTACK=false\nUFW_RULE_COUNT=0\nSYSCTL_FILE_CREATED=false\nSAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false\nSAMBA_OWNERSHIP_RECORDED=false\nSAMBA_CONFIGURED=false\n' >/etc/mediastack/install-state && chmod 0600 /etc/mediastack/install-state"
    # When Uninstall MediaStack runs with the typed confirmation.
    out=$(dind_exec "printf 'DESTROY\n' | bash -lc '
set -uo pipefail
source setup.sh
check_not_root() { :; }; check_debian() { :; }; prompt_sudo_cache() { :; }; record_launcher_outcome() { :; }
sudo() { \"\$@\"; }
uninstall_system_cleanup() { echo \"host cleanup stubbed\"; }
main --uninstall
' 2>&1" | sed -r 's/\x1b\[[0-9;]*m//g')
    # Then the service databases, .env and config.yml are gone and the media stays.
    assert_contains "$out" "config/ - all service settings & databases" "reset: the preview names the data it removes"
    assert_contains "$out" "Jellyfin watch history" "reset: the preview names the watch history"
    dind_exec "test ! -e config/sonarr/sonarr.db" && pass "reset: the Sonarr database is removed" || fail "reset: the Sonarr database is removed"
    dind_exec "test ! -e config/jellyfin" && pass "reset: the Jellyfin state is removed" || fail "reset: the Jellyfin state is removed"
    dind_exec "test ! -e .env && test ! -e config.yml" && pass "reset: .env and config.yml are removed" || fail "reset: .env and config.yml are removed"
    dind_exec "test -f '/tmp/ms-data/media/tv/Drift Show/Season 01/Drift Show - S01E01.mkv'" && pass "reset: media files stay" || fail "reset: media files stay"

    # Given the reset is done, a new install sets the services up from empty state.
    # When the fixture install runs again.
    drift_build_install || {
        fail "reset: a new install starts"
        return 1
    }
    # Then the stack is healthy, config.yml is applied, and the old API key is gone.
    out=$(drift_configure sonarr,radarr,jellyfin)
    assert_contains "$out" "Auto-configuration complete" "reset: configure succeeds on the new install"
    assert_contains "$out" "root folder /data/media/tv already matches config.yml" "reset: the stale root folder drift is gone"
    [[ "$(env_get SONARR_API_KEY)" != "$api_key_before" ]] && pass "reset: Sonarr has a new API key (dependents need it)" \
        || fail "reset: Sonarr has a new API key (dependents need it)"
}

run_scenario() {
    drift_build_install || {
        fail "fixture: a finished install starts"
        return 1
    }
    pass "fixture: a finished install starts"
    drift_root_folder_cases
    drift_category_cases
    drift_profile_cases
    drift_scores_cases
    drift_library_cases
    drift_down_v_cases
    drift_reset_cases
}

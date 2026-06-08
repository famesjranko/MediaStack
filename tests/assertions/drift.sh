assert_drift_regression() {
    echo ""
    echo "  mutating config.yml to force drift at 3 sites…"
    docker exec -i -w /root/MediaStack "$DIND_NAME" python3 <<'PY'
import shutil, yaml, pathlib
shutil.copy2("config.yml", "/tmp/config.yml.bak")
p = pathlib.Path("config.yml")
with p.open() as f: c = yaml.safe_load(f)
c["quality_profile"]["cutoff_id"] = 1001                        # was 1002 (WEB 1080p → 720p)
c["sonarr"]["download_client_category"] = "tv-sonarr-v2"        # was tv-sonarr
c["jellyfin"]["libraries"][0]["path"] = "/data/media/movies-v2" # Movies library
with p.open("w") as f: yaml.safe_dump(c, f, sort_keys=False)
PY

    local rerun_log=/tmp/configure-rerun.out
    if dind_exec "./scripts/configure.sh --only sonarr,radarr,jellyfin" >"$rerun_log" 2>&1; then
        pass "configure.sh re-run exits 0"
    else
        fail "configure.sh re-run exits 0"
        tail -40 "$rerun_log"
    fi

    local rerun_warns
    rerun_warns=$(sed -r 's/\x1b\[[0-9;]*m//g' "$rerun_log" | grep -E '^\[WARN\]' || true)
    echo "  (re-run WARN lines)"
    echo "$rerun_warns" | sed 's/^/    /' | head -20

    assert_contains "$rerun_warns" "quality profile '1080p Balanced' differs from config.yml" "drift re-run: quality profile WARN"
    assert_contains "$rerun_warns" "Sonarr qBittorrent category differs from config.yml" "drift re-run: Sonarr download-client WARN"
    assert_contains "$rerun_warns" "Jellyfin library 'Movies' path differs from config.yml" "drift re-run: Jellyfin library WARN"

    if echo "$rerun_warns" | grep -q "Sonarr root folder differs"; then
        fail "drift re-run: no false-positive Sonarr root-folder WARN" "root folder was not mutated"
    else
        pass "drift re-run: no false-positive Sonarr root-folder WARN"
    fi
    if echo "$rerun_warns" | grep -q "Radarr qBittorrent category differs"; then
        fail "drift re-run: no false-positive Radarr download-client WARN" "radarr.download_client_category was not mutated"
    else
        pass "drift re-run: no false-positive Radarr download-client WARN"
    fi

    # Restore config.yml so downstream consumers (and --keep inspection) see the original.
    docker exec -w /root/MediaStack "$DIND_NAME" cp /tmp/config.yml.bak config.yml
}

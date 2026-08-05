# Owns: configure_* — Sonarr/Radarr Jackett indexer discovery and configuration.
# Sources: scripts/lib/arr/main.sh state plus lib/common.sh, lib/json.sh, curl, and the Torznab renderer.
configure_arr_indexers() {
    local app="$1" base="$2" key="$3" fallback_categories="$4"
    local jackett_local_url jackett_internal_url
    jackett_local_url="$(service_local_url jackett)"
    jackett_internal_url="$(service_internal_url jackett)"

    local jackett_key
    jackett_key=$(api_get_jackett_key)
    if [[ -z "$jackett_key" ]]; then
        log_warn "Cannot read Jackett API key - skipping indexers"
        return 0
    fi

    local existing_indexers
    if ! existing_indexers=$(api_get "$base/indexer" "$key"); then
        log_warn "Could not fetch ${app^} indexers - skipping check"
        existing_indexers="[]"
    fi

    local fallback_cat_json
    fallback_cat_json=$(echo "$fallback_categories" | python3 -c "
import sys; cats=sys.stdin.read().strip().split(',')
print('['+','.join(c.strip() for c in cats)+']')
")

    # Per-indexer worker: caps discovery + API POST with retries.
    # Runs as a background job; writes result to a temp file for ordered reporting.
    _add_indexer() {
        local indexer_id="$1" app="$2" base="$3" key="$4"
        local jackett_key="$5" fallback_cat_json="$6" result_file="$7"
        local lib_dir="$8"

        local cat_json
        cat_json=$(curl -sf --max-time 5 \
            "${jackett_local_url}/api/v2.0/indexers/$indexer_id/results/torznab/?apikey=$jackett_key&t=caps" 2>/dev/null \
            | python3 "$lib_dir/render/torznab_caps.py" "$app" 2>/dev/null || echo "")

        if [[ -z "$cat_json" || "$cat_json" == "[]" ]]; then
            cat_json="$fallback_cat_json"
        fi

        local indexer_json
        indexer_json=$(INDEXER_NAME="$indexer_id" \
            BASE_URL="${jackett_internal_url}/api/v2.0/indexers/$indexer_id/results/torznab/" \
            APIKEY="$jackett_key" \
            CATEGORIES="$cat_json" \
            APP="$app" \
            python3 -c '
import os, json
fields = [
    {"name": "baseUrl", "value": os.environ["BASE_URL"]},
    {"name": "apiPath", "value": "/api"},
    {"name": "apiKey", "value": os.environ["APIKEY"]},
    {"name": "categories", "value": json.loads(os.environ["CATEGORIES"])},
    {"name": "minimumSeeders", "value": 1},
    {"name": "seedCriteria.seedRatio", "value": 1.0},
    {"name": "seedCriteria.seedTime", "value": 1440},
]
if os.environ["APP"] == "sonarr":
    fields.append({"name": "seedCriteria.seasonPackSeedTime", "value": 2880})
print(json.dumps({
    "name": os.environ["INDEXER_NAME"],
    "enableRss": True,
    "enableAutomaticSearch": True,
    "enableInteractiveSearch": True,
    "protocol": "torrent",
    "priority": 25,
    "implementation": "Torznab",
    "configContract": "TorznabSettings",
    "fields": fields,
}))')

        local attempt rc=1
        for attempt in 1 2; do
            if api_post "$base/indexer?forceSave=true" "$key" "$indexer_json" >/dev/null 2>&1; then
                rc=0
                break
            fi
            ((attempt < 2)) && sleep 2
        done
        if ((rc == 0)); then
            echo "ok:$attempt" >"$result_file"
        else
            echo "fail" >"$result_file"
        fi
    }

    local _results_dir _pids=() _indexer_order=()
    local _already_count=0
    _results_dir=$(mktemp -d)

    # Filter indexers by type: sonarr gets general+tv, radarr gets general+movies
    while IFS=: read -r indexer_id indexer_type; do
        if [[ "$app" == "sonarr" && "$indexer_type" == "movies" ]]; then continue; fi
        if [[ "$app" == "radarr" && "$indexer_type" == "tv" ]]; then continue; fi

        if echo "$existing_indexers" | json_has_name "$indexer_id" -i; then
            log_skip "$indexer_id already in ${app^}"
            ((_already_count++)) || true
            continue
        fi

        _indexer_order+=("$indexer_id")
        _add_indexer "$indexer_id" "$app" "$base" "$key" \
            "$jackett_key" "$fallback_cat_json" "$_results_dir/$indexer_id" "$_ARR_LIB_DIR" &
        _pids+=($!)
    done < <(cfg_indexers)

    # Stream completion lines as workers finish, rather than waiting for all
    # then reporting in a burst. The save-time caps fetch through Jackett to
    # Cloudflare-protected trackers can stall a single worker for tens of
    # seconds; without streaming the user sees a long silence and assumes the
    # wizard is hung. With streaming, each [OK]/[WARN] line lands as soon as
    # its worker writes its result file.
    if ((${#_indexer_order[@]} > 0)); then
        log_info "Adding ${#_indexer_order[@]} indexers to ${app^} (Sonarr/Radarr fetch caps from each tracker on save; Cloudflare-protected ones can be slow)..."
    fi

    local -A _seen=()
    local _emitted=0 _expected=${#_indexer_order[@]} _any_alive
    local _ok_count=0 _fail_count=0
    while ((_emitted < _expected)); do
        _any_alive=0
        for _pid in "${_pids[@]}"; do
            if kill -0 "$_pid" 2>/dev/null; then
                _any_alive=1
                break
            fi
        done

        local indexer_id
        for indexer_id in "${_indexer_order[@]}"; do
            [[ -n "${_seen[$indexer_id]:-}" ]] && continue
            local _result_file="$_results_dir/$indexer_id"
            [[ -f "$_result_file" ]] || continue
            local _result
            _result=$(cat "$_result_file" 2>/dev/null || echo "fail")
            case "$_result" in
                ok:1)
                    log_ok "Indexer -> ${app^}: $indexer_id"
                    ((_ok_count++)) || true
                    ;;
                ok:*)
                    log_ok "Indexer -> ${app^}: $indexer_id (attempt ${_result#ok:})"
                    ((_ok_count++)) || true
                    ;;
                *)
                    log_info "Indexer unavailable, skipped: $indexer_id -> ${app^}"
                    ((_fail_count++)) || true
                    ;;
            esac
            _seen[$indexer_id]=1
            ((_emitted++)) || true
        done

        if ((_emitted < _expected)); then
            # All workers exited but some result files missing — fall through
            # to the final sweep below to mark them failed.
            ((_any_alive == 0)) && break
            sleep 0.5
        fi
    done

    # Final sweep: any indexer whose worker exited without writing a result.
    local indexer_id
    for indexer_id in "${_indexer_order[@]}"; do
        [[ -n "${_seen[$indexer_id]:-}" ]] && continue
        log_info "Indexer unavailable, skipped: $indexer_id -> ${app^}"
        ((_fail_count++)) || true
    done

    # Only warn if every attempted indexer failed AND none were already present — partial
    # failures on public trackers are normal; if indexers already exist the app is configured.
    if ((_fail_count > 0 && _ok_count == 0 && _already_count == 0 && _expected > 0)); then
        log_warn "No indexers were added to ${app^} — add them manually via the ${app^} UI (Settings → Indexers)"
    fi

    # Reap straggler PIDs (most are already exited).
    for _pid in "${_pids[@]}"; do wait "$_pid" 2>/dev/null; done

    rm -rf "$_results_dir"

    # Warn-on-drift: indexers present live but no longer in config.yml for this
    # app. Compares the pre-loop snapshot (existing_indexers) against cfg_indexers
    # filtered by app type. Added indexers fall through the loop above; this tail
    # only catches removals.
    local app_expected stale
    app_expected=$(while IFS=: read -r iid itype; do
        if [[ "$app" == "sonarr" && "$itype" == "movies" ]]; then continue; fi
        if [[ "$app" == "radarr" && "$itype" == "tv" ]]; then continue; fi
        echo "$iid"
    done < <(cfg_indexers) | tr '\n' ',')
    stale=$(echo "$existing_indexers" | EXPECTED="$app_expected" python3 -c '
import sys, json, os
want = {n.strip().lower() for n in os.environ["EXPECTED"].split(",") if n.strip()}
try: items = json.load(sys.stdin)
except Exception: items = []
for n in (i.get("name","") for i in items):
    if n and n.lower() not in want:
        print(n)
' 2>/dev/null)
    if [[ -n "$stale" ]]; then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            log_drift "${app^} indexer '$name' exists but is not in config.yml. configure.sh does not remove indexers on re-run. To remove: ${app^} UI -> Settings -> Indexers -> Delete, or rebuild."
        done <<<"$stale"
    fi
}

# Check/create the root folder for a Sonarr or Radarr instance. Reads the
# desired path from config.yml, compares against the live API, and emits
# [SKIP] on match, [WARN] on drift, or [OK] after creating a missing folder.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>

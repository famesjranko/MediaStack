# =============================================================================
# MediaStack *arr shared helpers: quality profiles, Torznab indexer wiring
# =============================================================================
# Sourced by scripts/configure.sh after lib/common.sh. Both functions are
# called by services/sonarr.sh and services/radarr.sh.

# Absolute path to this lib's directory — used to locate render/ and templates/.
_ARR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Day-2 rename status channel. When the launcher's "Change quality
# profile" action drives configure.sh, it sets QP_RENAME_STATUS to a writable
# file path. We append the app name here whenever an in-place rename FAILS or is
# REFUSED (live name drifted), so the launcher can report "did not apply" instead
# of a false success. configure.sh itself stays exit-0 (its deliberate
# never-abort contract — see the header note in scripts/configure.sh). A no-op on
# normal runs, where QP_RENAME_STATUS is unset.
_qp_record_rename_failure() {
    [[ -n "${QP_RENAME_STATUS:-}" ]] && printf '%s\n' "$1" >>"$QP_RENAME_STATUS"
    return 0
}

# Create a Sonarr/Radarr quality profile named per config.yml with the chosen
# quality IDs enabled. On first run POSTs a new profile. On re-run with a
# matching-named profile already present, compares cutoff/upgrade/enabled-IDs
# against config.yml and emits [SKIP] on match, [WARN] on drift — configure.sh
# does not reconcile drift (turnkey design: rebuild is the canonical migration).
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key> <json-array-of-enabled-quality-ids>
configure_quality_profile() {
    local app="$1" base="$2" key="$3" enabled_ids_json="$4"
    local app_label="${app^}"

    local profile_name cutoff_id upgrade
    profile_name=$(cfg_field "quality_profile.name")
    cutoff_id=$(cfg_field "quality_profile.cutoff_id")
    upgrade=$(cfg_field "quality_profile.upgrade_allowed")

    local existing qp_status
    if ! existing=$(api_get "$base/qualityprofile" "$key"); then
        log_warn "Could not fetch ${app^} quality profiles - skipping check"
        existing="[]"
    fi

    # Day-2 in-place rename. The launcher's "Change quality profile"
    # action sets QP_RENAME_FROM to the OLD profile name when the user re-picks a
    # cell, so the profile name changes ("1080p Balanced" -> "1080p Large"). The
    # normal path below would find no profile under the NEW name, fall to
    # "absent", and POST a brand-new profile — orphaning the old one, which
    # existing series/movies still reference by id. Instead, locate the
    # OLD-named profile and PUT the new render onto its SAME id, so the id
    # survives, library items follow automatically, and nothing is orphaned.
    # QP_RENAME_FROM is never set on a normal configure.sh re-run, so the
    # warn-on-drift contract below is unchanged.
    local rename_from="${QP_RENAME_FROM:-}"
    if [[ -n "$rename_from" && "$rename_from" != "$profile_name" ]]; then
        local rename_plan
        rename_plan=$(echo "$existing" \
            | OLD_NAME="$rename_from" NEW_NAME="$profile_name" python3 -c '
import sys, json, os
old, new = os.environ["OLD_NAME"], os.environ["NEW_NAME"]
try: profiles = json.load(sys.stdin)
except Exception: profiles = []
names = {p.get("name") for p in profiles}
if new in names and old in names:
    print("exists_stale")                 # renamed already, but the old one lingers
elif new in names:
    print("exists")                       # already renamed -> normal match path
elif old in names:
    p = next(pp for pp in profiles if pp.get("name") == old)
    print("rename\t" + str(p.get("id")))
else:
    print("absent")                       # live name drifted -> refuse to orphan
' 2>/dev/null)
        case "${rename_plan%%$'\t'*}" in
            rename)
                local old_id="${rename_plan#*$'\t'}"
                local old_profile rendered renamed_json
                old_profile=$(echo "$existing" | OLD_ID="$old_id" python3 -c '
import sys, json, os
oid = os.environ["OLD_ID"]
profiles = json.load(sys.stdin)
p = next((pp for pp in profiles if str(pp.get("id")) == oid), None)
print(json.dumps(p) if p else "")
' 2>/dev/null)
                # Render new items/cutoff/name using the OLD profile as template,
                # then merge them onto the FULL old profile so id/language and
                # every other field survive the PUT (same as the api-matrix
                # apply_cell.py contract). Zero the formatItems scores so the
                # downstream configure_arr_format_scores re-attaches the new
                # size's scores via its "empty -> PUT" path in this same run.
                rendered=$(echo "$old_profile" \
                    | PROFILE_NAME="$profile_name" \
                        ENABLED_IDS="$enabled_ids_json" \
                        CUTOFF_ID="$cutoff_id" \
                        UPGRADE_ALLOWED="$upgrade" \
                        python3 "$_ARR_LIB_DIR/render/quality_profile.py" 2>/dev/null)
                renamed_json=$(echo "$rendered" | OLD_PROFILE="$old_profile" python3 -c '
import sys, json, os
rendered = json.load(sys.stdin)
merged = json.loads(os.environ["OLD_PROFILE"])
merged["name"] = rendered["name"]
merged["cutoff"] = rendered["cutoff"]
merged["upgradeAllowed"] = rendered["upgradeAllowed"]
merged["items"] = rendered["items"]
# Carry the reject floor so a day-2 cell switch also repairs a profile created
# by the pre-fix renderer (minFormatScore 0, which hard-rejected soft-penalized
# releases). Consistent with this branch already rewriting the profile in place.
merged["minFormatScore"] = rendered["minFormatScore"]
for it in merged.get("formatItems", []):
    it["score"] = 0
print(json.dumps(merged))
' 2>/dev/null)
                # PUT the rename, then verify it actually landed: the live
                # profile must show the new name AND every formatItems score at
                # 0. If a transient dropped write leaves any managed
                # score non-zero, the downstream configure_arr_format_scores
                # sees "drift" and — by design — only warns, so the new size's
                # scores never attach (e.g. x265 (HD) stuck at 0). Retry until
                # the zeroing persists so the "empty -> PUT" hand-off is reliable.
                local _rn_ok="" _rn_attempt
                if [[ -n "$renamed_json" && "$renamed_json" != "null" ]]; then
                    for _rn_attempt in 1 2 3; do
                        api_put "$base/qualityprofile/$old_id" "$key" "$renamed_json" >/dev/null 2>&1 \
                            || {
                                sleep "$_rn_attempt"
                                continue
                            }
                        if api_get "$base/qualityprofile/$old_id" "$key" 2>/dev/null \
                            | PROFILE_NAME="$profile_name" python3 -c '
import sys, json, os
p = json.load(sys.stdin)
ok = p.get("name") == os.environ["PROFILE_NAME"] \
    and all(fi.get("score", 0) == 0 for fi in p.get("formatItems", []))
sys.exit(0 if ok else 1)
' 2>/dev/null; then
                            _rn_ok=1
                            break
                        fi
                        sleep "$_rn_attempt"
                    done
                fi
                if [[ -n "$_rn_ok" ]]; then
                    log_ok "Quality profile renamed in place: '$rename_from' -> '$profile_name' (cutoff ID: $cutoff_id; id $old_id kept, no orphan)"
                else
                    log_warn "Failed to rename ${app_label} quality profile '$rename_from' -> '$profile_name'"
                    _qp_record_rename_failure "$app"
                fi
                return 0
                ;;
            exists_stale)
                # The new name is already live (a prior rename took), but the old
                # one is still present — a stale profile this action did not
                # create. Don't touch it; the new name matches config.yml, so the
                # fall-through SKIPs. Just surface the leftover so the user can
                # remove it. Not a failure of this change, so not recorded.
                log_drift "${app_label}: '$profile_name' already exists and the old '$rename_from' is still present (stale). Using '$profile_name'; delete '$rename_from' in ${app_label} (Settings -> Profiles) if no series/movies use it."
                ;;
            exists)
                : # new name already present -> fall through to normal match/skip
                ;;
            *)
                log_warn "${app_label}: no quality profile named '$rename_from' to rename (renamed in the ${app_label} UI?). Not creating a duplicate '$profile_name' that would orphan your in-use profile. To change: rename it back to '$rename_from' in ${app_label} (Settings -> Profiles) and retry, or rebuild (docker compose down -v && ./setup.sh --full)."
                _qp_record_rename_failure "$app"
                return 0
                ;;
        esac
    fi

    qp_status=$(echo "$existing" \
        | PROFILE_NAME="$profile_name" \
            ENABLED_IDS="$enabled_ids_json" \
            CUTOFF_ID="$cutoff_id" \
            UPGRADE_ALLOWED="$upgrade" \
            python3 -c '
import sys, json, os
name = os.environ["PROFILE_NAME"]
want_ids = set(json.loads(os.environ["ENABLED_IDS"]))
want_cutoff = int(os.environ["CUTOFF_ID"])
want_upgrade = os.environ["UPGRADE_ALLOWED"].strip().lower() == "true"
try: profiles = json.load(sys.stdin)
except Exception: profiles = []
p = next((pp for pp in profiles if pp.get("name") == name), None)
if p is None:
    print("absent"); sys.exit(0)
# Collect IDs that the render flips to allowed=true (leaf qualities inside groups).
live_ids = set()
for item in p.get("items", []):
    if "quality" in item and item.get("allowed"):
        live_ids.add(item["quality"]["id"])
    else:
        for sub in item.get("items", []):
            if sub.get("allowed") and "quality" in sub:
                live_ids.add(sub["quality"]["id"])
drift = []
if p.get("cutoff") != want_cutoff:
    drift.append("cutoff_id (live=" + str(p.get("cutoff")) + ", config.yml=" + str(want_cutoff) + ")")
if bool(p.get("upgradeAllowed")) != want_upgrade:
    drift.append("upgrade_allowed (live=" + str(p.get("upgradeAllowed")) + ", config.yml=" + str(want_upgrade) + ")")
if live_ids != want_ids:
    added = sorted(want_ids - live_ids)
    removed = sorted(live_ids - want_ids)
    parts = []
    if added:   parts.append("config.yml adds " + str(added))
    if removed: parts.append("config.yml removes " + str(removed))
    drift.append("qualities (" + ", ".join(parts) + ")")
print("drift\t" + "; ".join(drift) if drift else "match")
' 2>/dev/null)
    case "${qp_status%%$'\t'*}" in
        match)
            log_skip "$app_label quality profile '$profile_name' already matches your settings"
            return 0
            ;;
        drift)
            log_drift "$app_label quality profile '$profile_name' differs from config.yml: ${qp_status#*$'\t'}. configure.sh does not reconcile this on re-run. To change: edit the profile in the $app_label UI (Settings -> Profiles), or rebuild (docker compose down -v && ./setup.sh --full)."
            return 0
            ;;
    esac

    local default_profile
    default_profile=$(echo "$existing" | python3 -c "
import sys, json
profiles = json.load(sys.stdin)
print(json.dumps(profiles[0]) if profiles else '{}')
" 2>/dev/null || echo "{}")
    if [[ "$default_profile" == "{}" ]]; then
        log_warn "No quality profiles to use as template"
        return 0
    fi

    local profile_json
    profile_json=$(PROFILE_NAME="$profile_name" \
        ENABLED_IDS="$enabled_ids_json" \
        CUTOFF_ID="$cutoff_id" \
        UPGRADE_ALLOWED="$upgrade" \
        python3 "$_ARR_LIB_DIR/render/quality_profile.py" <<<"$default_profile" 2>/dev/null)

    if [[ -n "$profile_json" && "$profile_json" != "null" ]]; then
        if api_post "$base/qualityprofile" "$key" "$profile_json" >/dev/null 2>&1; then
            log_ok "Quality profile: $profile_name (cutoff ID: $cutoff_id)"
        else
            log_warn "Failed to create quality profile: $profile_name"
        fi
    else
        log_warn "Could not generate quality profile"
    fi
}

# Tighten per-quality file-size bounds from config.yml's quality_definitions.
# Sonarr/Radarr's upstream defaults let in 400 MB cam rips and 25 GB bloat,
# so this is a turnkey-friendly replacement applied after configure_quality_profile.
# Idempotent — reads live definitions and only PUTs the ones whose size fields
# differ from config.yml. Skips silently when the section is absent.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_quality_definitions() {
    local app="$1" base="$2" key="$3"

    local desired
    desired=$(cfg_quality_definitions "$app")
    if [[ -z "$desired" || "$desired" == "{}" ]]; then
        log_skip "No quality_definitions.$app in config.yml - keeping upstream defaults"
        return 0
    fi

    local current
    if ! current=$(api_get "$base/qualitydefinition" "$key"); then
        log_warn "Could not fetch ${app^} quality definitions - skipping"
        current="[]"
    fi
    if [[ -z "$current" || "$current" == "[]" ]]; then
        log_warn "No quality definitions returned from ${app^}"
        return 0
    fi

    # Python emits needed updates as <id>\t<put-body>; unknown quality names
    # go to stderr as WARN\t<name>. Missing entries are not fatal — Sonarr/Radarr
    # add/remove quality tiers between versions and we don't want that to break
    # the whole step.
    local plan warn_lines updated=0
    local warn_file
    warn_file="$(mktemp)"
    plan=$(DESIRED="$desired" python3 "$_ARR_LIB_DIR/render/quality_definitions.py" <<<"$current" 2>"$warn_file" || echo "")
    warn_lines=$(<"$warn_file")
    rm -f "$warn_file"

    if [[ -n "$warn_lines" ]]; then
        while IFS=$'\t' read -r _ name; do
            [[ -z "$name" ]] && continue
            log_warn "Quality '$name' not present in ${app^} - skipped"
        done <<<"$warn_lines"
    fi

    while IFS=$'\t' read -r def_id put_body; do
        [[ -z "$def_id" ]] && continue
        if api_put "$base/qualitydefinition/$def_id" "$key" "$put_body" >/dev/null 2>&1; then
            updated=$((updated + 1))
        else
            log_warn "Failed to PUT quality definition id=$def_id"
        fi
    done <<<"$plan"

    if ((updated == 0)); then
        log_skip "Quality definitions already match your settings"
    else
        log_ok "Quality definitions updated ($updated tier(s)) for ${app^}"
    fi
}

# Create curated custom format definitions in Sonarr/Radarr from the developer-
# managed custom_formats.yml. Only formats whose names appear in config.yml's
# custom_formats scores are created. Idempotent — skips formats already present.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_custom_formats() {
    local app="$1" base="$2" key="$3"
    local app_label="${app^}"

    local scores
    scores=$(cfg_custom_format_scores)
    if [[ -z "$scores" || "$scores" == "{}" ]]; then
        return 0
    fi

    local existing
    if ! existing=$(api_get "$base/customformat" "$key"); then
        log_warn "Could not fetch $app_label custom formats - skipping"
        return 0
    fi

    local plan created=0
    plan=$(echo "$existing" \
        | FORMATS_FILE="$_ARR_LIB_DIR/custom_formats.yml" \
            SCORES="$scores" \
            python3 "$_ARR_LIB_DIR/render/custom_formats.py" 2>/dev/null || echo "")

    if [[ -z "$plan" ]]; then
        log_skip "$app_label custom formats already present"
        return 0
    fi

    while IFS=$'\t' read -r name post_body; do
        [[ -z "$name" ]] && continue
        if api_post "$base/customformat" "$key" "$post_body" >/dev/null 2>&1; then
            created=$((created + 1))
        else
            log_warn "Failed to create custom format '$name' in $app_label"
        fi
    done <<<"$plan"

    if ((created > 0)); then
        log_ok "Custom formats: $created created in $app_label"
    fi
}

# Attach custom format scores to the quality profile. Treats an empty
# formatItems as CREATE (allowed); non-empty + different as drift (warn only).
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_format_scores() {
    local app="$1" base="$2" key="$3"
    local app_label="${app^}"

    local scores
    scores=$(cfg_custom_format_scores)
    if [[ -z "$scores" || "$scores" == "{}" ]]; then
        return 0
    fi

    local existing
    if ! existing=$(api_get "$base/customformat" "$key"); then
        log_warn "Could not fetch $app_label custom formats - skipping score attachment"
        return 0
    fi

    local format_map
    format_map=$(echo "$existing" | python3 -c '
import sys, json
try:
    cfs = json.load(sys.stdin)
    print(json.dumps({cf["name"]: cf["id"] for cf in cfs}))
except Exception:
    print("{}")
' 2>/dev/null)

    local profile_name
    profile_name=$(cfg_field "quality_profile.name")

    local profiles profile_json
    if ! profiles=$(api_get "$base/qualityprofile" "$key"); then
        log_warn "Could not fetch $app_label quality profiles - skipping score attachment"
        return 0
    fi

    profile_json=$(echo "$profiles" | PROFILE_NAME="$profile_name" python3 -c '
import sys, json, os
name = os.environ["PROFILE_NAME"]
try:
    profiles = json.load(sys.stdin)
    p = next((pp for pp in profiles if pp.get("name") == name), None)
    if p:
        print(json.dumps(p))
    else:
        print("")
except Exception:
    print("")
' 2>/dev/null)

    if [[ -z "$profile_json" ]]; then
        log_warn "$app_label quality profile '$profile_name' not found - skipping format scores"
        return 0
    fi

    local status
    status=$(echo "$profile_json" \
        | SCORES="$scores" \
            FORMAT_MAP="$format_map" \
            python3 "$_ARR_LIB_DIR/render/format_scores.py" 2>/dev/null)

    case "${status%%$'\t'*}" in
        match)
            log_skip "$app_label format scores already match your settings"
            ;;
        empty)
            local put_body="${status#*$'\t'}"
            local profile_id
            profile_id=$(echo "$profile_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
            if api_put "$base/qualityprofile/$profile_id" "$key" "$put_body" >/dev/null 2>&1; then
                log_ok "Format scores attached to profile '$profile_name' in $app_label"
            else
                log_warn "Failed to attach format scores to $app_label profile '$profile_name'"
            fi
            ;;
        drift)
            log_drift "$app_label profile '$profile_name' format scores differ from config.yml: ${status#*$'\t'}. configure.sh does not reconcile this on re-run. To change: edit scores in the $app_label UI (Settings -> Profiles -> $profile_name), or rebuild (docker compose down -v && ./setup.sh --full)."
            ;;
        *)
            log_warn "Could not determine $app_label format score status"
            ;;
    esac
}

# Attach Jackett indexers (as Torznab) to Sonarr or Radarr. Filters by indexer
# type so Sonarr gets general+tv and Radarr gets general+movies. Idempotent —
# skips indexers whose id is already present in the target's indexer name list.
#
# Categories are auto-discovered from each indexer's Torznab caps and split by
# app: Radarr gets 2xxx (Movies) + movie/anime natives; Sonarr gets 5xxx (TV) +
# tv/anime natives; both get 8xxx (Other). Native 100xxx categories are filtered
# by name to video content only. Without native categories, Radarr's mandatory
# add-time test fails with "no results in the configured categories".
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key> <comma-separated-fallback-categories>
configure_arr_indexers() {
    local app="$1" base="$2" key="$3" fallback_categories="$4"
    local jackett_local_url jackett_internal_url
    jackett_local_url="$(service_local_url jackett)"
    jackett_internal_url="$(service_internal_url jackett)"

    local jackett_key
    jackett_key=$(get_jackett_api_key)
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
configure_arr_root_folder() {
    local app="$1" base="$2" key="$3"

    local root_folder
    root_folder=$(cfg_field "$app.root_folder")

    local existing rf_status
    if ! existing=$(api_get "$base/rootfolder" "$key"); then
        log_warn "Could not fetch ${app^} root folders - skipping check"
        existing="[]"
    fi
    rf_status=$(echo "$existing" | WANT_PATH="$root_folder" python3 -c '
import sys, json, os
want = os.environ["WANT_PATH"]
try: items = json.load(sys.stdin)
except Exception: items = []
paths = [r.get("path","") for r in items]
if want in paths: print("match")
elif paths:       print("drift\t" + ",".join(paths))
else:             print("absent")
' 2>/dev/null)
    case "${rf_status%%$'\t'*}" in
        match)
            log_skip "${app^} root folder $root_folder already matches config.yml"
            ;;
        drift)
            log_drift "${app^} root folder differs from config.yml (live=${rf_status#*$'\t'}, config.yml=$root_folder). configure.sh does not reconcile this on re-run. To change: ${app^} UI -> Settings -> Media Management -> Root Folders -> delete the stale entry, or rebuild (docker compose down -v && ./setup.sh --full)."
            ;;
        *)
            local root_body
            root_body=$(ROOT_FOLDER="$root_folder" python3 -c '
import json
import os
import sys

json.dump({"path": os.environ["ROOT_FOLDER"]}, sys.stdout)
' 2>/dev/null)
            if [[ -n "$root_body" ]] && api_post "$base/rootfolder" "$key" "$root_body" >/dev/null 2>&1; then
                log_ok "Root folder: $root_folder"
            else
                log_warn "Failed to set ${app^} root folder: $root_folder"
            fi
            ;;
    esac
}

# Set the global minimum-free-space threshold for a Sonarr or Radarr instance.
# Reads min_free_space_gb from config.yml, converts to MB, and applies via
# GET/PUT /api/v3/config/mediamanagement. Only updates when the current value
# is the API default (100 MB); warns on drift from user-customized values.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_disk_threshold() {
    local app="$1" base="$2" key="$3"

    local min_free_gb
    min_free_gb=$(cfg_field "min_free_space_gb" 2>/dev/null || echo "20")

    if [[ "$min_free_gb" == "0" ]]; then
        log_skip "${app^} disk threshold disabled (min_free_space_gb=0)"
        return 0
    fi

    local min_free_mb=$((min_free_gb * 1024))

    local mm_config current_mb
    if ! mm_config=$(api_get "$base/config/mediamanagement" "$key"); then
        log_warn "Could not fetch ${app^} media management config - skipping disk threshold"
        return 0
    fi
    current_mb=$(echo "$mm_config" | json_get minimumFreeSpaceWhenImporting 100)

    if [[ "$current_mb" == "$min_free_mb" ]]; then
        log_skip "${app^} disk threshold already ${min_free_gb}GB"
        return 0
    fi

    if [[ "$current_mb" != "100" ]]; then
        log_drift "${app^} minimumFreeSpaceWhenImporting=${current_mb}MB differs from config.yml (${min_free_gb}GB=${min_free_mb}MB). configure.sh does not reconcile on re-run."
        return 0
    fi

    local mm_body
    mm_body=$(echo "$mm_config" | MIN_FREE_MB="$min_free_mb" python3 -c '
import sys, json, os
config = json.load(sys.stdin)
config["minimumFreeSpaceWhenImporting"] = int(os.environ["MIN_FREE_MB"])
json.dump(config, sys.stdout)' 2>/dev/null)

    if api_put "$base/config/mediamanagement" "$key" "$mm_body" >/dev/null 2>&1; then
        log_ok "Disk threshold: ${min_free_gb}GB minimum free space"
    else
        log_warn "Failed to set ${app^} disk threshold"
    fi
}

# Check/create a qBittorrent download client for a Sonarr or Radarr instance.
# The category field name differs between apps (tvCategory vs movieCategory),
# passed as the 4th argument.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key> <category-field-name>
configure_arr_download_client() {
    local app="$1" base="$2" key="$3" category_field="$4"

    local dl_category
    dl_category=$(cfg_field "$app.download_client_category")

    local existing dc_status
    if ! existing=$(api_get "$base/downloadclient" "$key"); then
        log_warn "Could not fetch ${app^} download clients - skipping check"
        existing="[]"
    fi
    dc_status=$(echo "$existing" | WANT_CATEGORY="$dl_category" CATEGORY_FIELD="$category_field" python3 -c '
import sys, json, os
want = os.environ["WANT_CATEGORY"]
cat_field = os.environ["CATEGORY_FIELD"]
try: items = json.load(sys.stdin)
except Exception: items = []
qbt = next((c for c in items if c.get("name") == "qBittorrent"), None)
if qbt is None:
    print("absent")
else:
    live = next((f.get("value","") for f in qbt.get("fields",[]) if f.get("name")==cat_field), "")
    print("match" if str(live) == str(want) else "drift\t" + str(live))
' 2>/dev/null)
    case "${dc_status%%$'\t'*}" in
        match)
            log_skip "${app^} qBittorrent category already matches config.yml ($dl_category)"
            ;;
        drift)
            log_drift "${app^} qBittorrent category differs from config.yml (live=${dc_status#*$'\t'}, config.yml=$dl_category). configure.sh does not reconcile this on re-run. To change: ${app^} UI -> Settings -> Download Clients -> qBittorrent -> update Category, or rebuild."
            ;;
        *)
            local dlclient_json
            dlclient_json=$(DL_CATEGORY="$dl_category" CATEGORY_FIELD="$category_field" \
                python3 -c '
import os, json
print(json.dumps({
    "enable": True,
    "protocol": "torrent",
    "priority": 1,
    "name": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "removeCompletedDownloads": True,
    "removeFailedDownloads": True,
    "fields": [
        {"name": "host", "value": "qbittorrent"},
        {"name": "port", "value": 8080},
        {"name": os.environ["CATEGORY_FIELD"], "value": os.environ["DL_CATEGORY"]},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": False},
        {"name": "firstAndLastFirst", "value": False},
    ],
}))')
            if api_post "$base/downloadclient" "$key" "$dlclient_json" >/dev/null 2>&1; then
                log_ok "Download client: qBittorrent (category: $dl_category)"
            else
                log_warn "Failed to add qBittorrent to ${app^}"
            fi
            ;;
    esac
}

# Enable Forms authentication on a Sonarr or Radarr instance using Jellyfin
# admin credentials. Restarts the container and polls until ready.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_auth() {
    local app="$1" base="$2" key="$3"

    local jf_user="${JELLYFIN_ADMIN_USER:-admin}"
    local jf_pw="${JELLYFIN_ADMIN_PASSWORD:-}"
    if [[ -z "$jf_pw" ]]; then
        log_warn "JELLYFIN_ADMIN_PASSWORD not set - skipping ${app^} auth"
        return 0
    fi

    local host_config current_auth
    if ! host_config=$(api_get "$base/config/host" "$key"); then
        log_warn "Could not fetch ${app^} host config - skipping auth check"
        host_config="{}"
    fi
    current_auth=$(echo "$host_config" | json_get authenticationMethod none)

    if [[ "$current_auth" == "forms" ]]; then
        log_skip "${app^} Forms authentication already enabled"
        return 0
    fi

    local auth_config
    auth_config=$(echo "$host_config" | JF_USER="$jf_user" JF_PW="$jf_pw" python3 -c '
import os, sys, json
config = json.load(sys.stdin)
config["authenticationMethod"] = "forms"
config["authenticationRequired"] = "enabled"
config["username"] = os.environ["JF_USER"]
config["password"] = os.environ["JF_PW"]
config["passwordConfirmation"] = os.environ["JF_PW"]
json.dump(config, sys.stdout)' 2>/dev/null)

    if api_put "$base/config/host" "$key" "$auth_config" >/dev/null 2>&1; then
        log_ok "${app^} Forms authentication enabled (user: $jf_user)"
        docker restart "$app" >/dev/null 2>&1
        post_restart_wait "$(service_local_url "$app")" || true
    else
        log_warn "Failed to enable ${app^} authentication"
    fi
}

# Connect a Sonarr or Radarr instance to Jellyfin so library scans trigger
# automatically on import. Uses the MediaBrowser notification type.
#
# Args: <"sonarr"|"radarr"> <api-base-url> <api-key>
configure_arr_jellyfin_connection() {
    local app="$1" base="$2" key="$3"

    local jf_key="${JELLYFIN_API_KEY:-}"
    if [[ -z "$jf_key" ]]; then
        log_warn "JELLYFIN_API_KEY not set - skipping ${app^} Jellyfin connection"
        return 0
    fi

    local existing conn_status
    if ! existing=$(api_get "$base/notification" "$key"); then
        sleep 5
        if ! existing=$(api_get "$base/notification" "$key"); then
            log_warn "Could not fetch ${app^} notifications - skipping Jellyfin connection"
            return 0
        fi
    fi
    conn_status=$(echo "$existing" | python3 -c '
import sys, json
try: items = json.load(sys.stdin)
except Exception: items = []
jf = next((n for n in items if n.get("implementation") == "MediaBrowser"), None)
if jf is None:
    print("absent")
else:
    print("present")
' 2>/dev/null)

    if [[ "$conn_status" == "present" ]]; then
        log_skip "${app^} Jellyfin connection already configured"
        return 0
    fi

    # Sonarr uses onImportComplete; Radarr uses onDownload for the same purpose
    local notif_json
    notif_json=$(JF_KEY="$jf_key" APP="$app" python3 -c '
import os, json
app = os.environ["APP"]
trigger = {"onImportComplete": True} if app == "sonarr" else {"onDownload": True}
payload = {
    "name": "Jellyfin",
    "implementation": "MediaBrowser",
    "configContract": "MediaBrowserSettings",
    "onGrab": False,
    "onUpgrade": False,
    "onRename": False,
    "onHealthIssue": False,
    "onHealthRestored": False,
    "onApplicationUpdate": False,
    "fields": [
        {"name": "host", "value": "jellyfin"},
        {"name": "port", "value": 8096},
        {"name": "useSsl", "value": False},
        {"name": "urlBase", "value": ""},
        {"name": "apiKey", "value": os.environ["JF_KEY"]},
        {"name": "notify", "value": False},
        {"name": "updateLibrary", "value": True},
        {"name": "mapFrom", "value": ""},
        {"name": "mapTo", "value": ""},
    ],
}
payload.update(trigger)
print(json.dumps(payload))')

    # POST /notification runs a provider Test() before saving — Sonarr hits
    # Jellyfin GET /System/Configuration, Radarr hits POST /Notifications/Admin.
    # The test can transiently fail if Jellyfin just restarted and isn't ready yet.
    # Retry with backoff, then fall back to forceSave=true (same pattern as indexers).
    local attempt
    for attempt in 1 2 3; do
        if api_post "$base/notification" "$key" "$notif_json" >/dev/null 2>&1; then
            log_ok "${app^} -> Jellyfin: library update on import"
            return 0
        fi
        sleep $((attempt * 3))
    done
    if api_post "$base/notification?forceSave=true" "$key" "$notif_json" >/dev/null 2>&1; then
        log_ok "${app^} -> Jellyfin: library update on import"
    else
        log_warn "Failed to add Jellyfin connection to ${app^}"
    fi
}

# Owns: Sonarr/Radarr custom-format definitions and profile score configuration.
# Sources: scripts/lib/arr/main.sh state plus lib/common.sh, lib/json.sh, and arr renderers.
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

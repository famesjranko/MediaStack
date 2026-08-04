# Owns: Sonarr/Radarr quality profile and quality-definition configuration.
# Sources: scripts/lib/arr/main.sh state plus lib/common.sh, lib/json.sh, and arr renderers.
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

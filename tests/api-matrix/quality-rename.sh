# tests/api-matrix/quality-rename.sh — api-matrix test-2: day-2 in-place rename.
#
# Proves the PRODUCT day-2 "change quality profile" push (issue #71): seed cell A
# via the product quality configurators, then change to cell B with
# QP_RENAME_FROM set, and assert the live profile is RENAMED IN PLACE — same id,
# new name/enabled-set/cutoff, the NEW size's custom-format scores actually
# landed, and NO orphan profile (count unchanged, old name gone).
#
# Unlike test-1 (apply_cell.py — a test transport that PRESERVES formatItems and
# never asserts scores), this drives configure_quality_profile's rename branch +
# configure_arr_format_scores via tests/api-matrix/push_quality.sh — the exact
# product functions the launcher action triggers through configure.sh. It is the
# only place the "rename + re-score in place, no orphan" contract is proven
# end-to-end through product code.
#
#   matrix_quality_rename APP BASE_URL API_KEY

# Run the product quality push for one cell inside DinD (bash, since the product
# libs are bash and dind_exec is `sh -c`). rename_from empty = initial create.
_qr_push() {
    local app="$1" base="$2" key="$3" res="$4" size="$5" rename_from="$6"
    dind_exec "bash tests/api-matrix/push_quality.sh $app $base $key $res $size '$rename_from'" >/dev/null 2>&1
}

# Echo profile count for the app's *arr.
_qr_count() {
    dind_exec "curl -sf -H 'X-Api-Key: $2' $1/qualityprofile" \
        | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null
}

# Echo the id of the profile named $3 (empty if absent).
_qr_id_of() {
    dind_exec "curl -sf -H 'X-Api-Key: $2' $1/qualityprofile" | NAME="$3" python3 -c '
import sys, json, os
ps = json.load(sys.stdin)
print(next((str(p["id"]) for p in ps if p.get("name") == os.environ["NAME"]), ""))
' 2>/dev/null
}

# Delete any live quality profile named $3 (best-effort; no-op if absent).
_qr_delete_named() {
    local base="$1" key="$2" name="$3" pid
    pid=$(_qr_id_of "$base" "$key" "$name")
    [[ -n "$pid" ]] && dind_exec "curl -sf -X DELETE -H 'X-Api-Key: $key' $base/qualityprofile/$pid" >/dev/null 2>&1
    return 0
}

# Echo the score of custom-format $4 on profile id $3 (NA if not present).
_qr_score() {
    local base="$1" key="$2" pid="$3" fmt="$4" cfs prof
    cfs=$(dind_exec "curl -sf -H 'X-Api-Key: $key' $base/customformat")
    prof=$(dind_exec "curl -sf -H 'X-Api-Key: $key' $base/qualityprofile/$pid")
    FMT="$fmt" python3 -c '
import sys, json, os
cfs = json.loads(sys.argv[1]); prof = json.loads(sys.argv[2])
fid = {c["name"]: c["id"] for c in cfs}.get(os.environ["FMT"])
scores = {fi["format"]: fi.get("score", 0) for fi in prof.get("formatItems", [])}
print(scores.get(fid, "NA"))
' "$cfs" "$prof" 2>/dev/null
}

matrix_quality_rename() {
    local app="$1" base="$2" key="$3"
    local label="${app^}"

    # Fresh throwaway config for this app's run.
    dind_exec "rm -f /tmp/ms-quality-rename.yml" >/dev/null 2>&1

    # Stay independent of test-1, which PUTs every cell in place and ends on
    # "1080p Large" (a live profile by that name). Use 720p cells it never leaves
    # behind, and clear any prior copy so the rename branch is reliably hit (a
    # pre-existing target name would take the "already renamed" fall-through).
    _qr_delete_named "$base" "$key" "720p Compact"
    _qr_delete_named "$base" "$key" "720p Balanced"

    # Seed cell A: 720p compact (initial create, no rename signal).
    _qr_push "$app" "$base" "$key" 720p compact ""
    local seed_count seed_id
    seed_count=$(_qr_count "$base" "$key")
    seed_id=$(_qr_id_of "$base" "$key" "720p Compact")
    [[ -n "$seed_id" ]] \
        && pass "$label rename: cell A '720p Compact' created (id=$seed_id)" \
        || fail "$label rename: cell A '720p Compact' created" "no id"

    # Change to cell B: 720p balanced, with the day-2 in-place rename signal.
    _qr_push "$app" "$base" "$key" 720p balanced "720p Compact"
    local after_count new_id old_id
    after_count=$(_qr_count "$base" "$key")
    new_id=$(_qr_id_of "$base" "$key" "720p Balanced")
    old_id=$(_qr_id_of "$base" "$key" "720p Compact")

    assert_eq "$seed_id" "$new_id" \
        "$label rename: '720p Balanced' kept the SAME profile id (in place, no orphan)"
    assert_eq "" "$old_id" \
        "$label rename: old '720p Compact' profile is gone (not orphaned)"
    assert_eq "$seed_count" "$after_count" \
        "$label rename: profile count unchanged (no duplicate created)"

    # The NEW size's custom-format score landed on the renamed id — the score
    # path apply_cell.py never exercised. Balanced scores x265 (HD) at -25 (the
    # seed was compact at 0, so this also proves the score was re-attached).
    assert_eq "-25" "$(_qr_score "$base" "$key" "$new_id" "x265 (HD)")" \
        "$label rename: balanced size's x265 score (-25) attached to the renamed profile"
}

# Owns: stage2_* — Stage 2 Jellyfin remote-streaming bitrate collection.
# Sources: Stage 2 UI and the Mbps validators.

_stage2_collect_jellyfin_remote_bitrate() {
    ui_section 4 5 "Jellyfin remote streaming"

    # Jellyfin's RemoteClientBitrateLimit is a PER-STREAM cap (not a global
    # aggregate). We surface a reference table so the user can pick their
    # own value rather than accept/reject a single recommendation. The
    # table covers (a) typical per-stream Mbps budgets at common quality
    # levels, and (b) per-viewer budget across plausible concurrent-viewer
    # counts, computed at 45% of detected upload bandwidth.
    local upload_mbps="${_NET_UL_MBPS:-}"
    if [[ -z "$upload_mbps" || ! "$upload_mbps" =~ ^[0-9]+$ ]]; then
        upload_mbps=$(ui_input_validated "Your upload bandwidth in Mbps (used for the recommendation table)" "100" validate_mbps_whole)
    else
        ui_log info "Detected upload bandwidth: ${upload_mbps} Mbps."
    fi

    ui_box "Per-stream bitrate by quality (Jellyfin transcodes to fit)" \
        "720p HD           3-7 Mbps" \
        "1080p HD          5-15 Mbps" \
        "4K HEVC (H.265)   20-40 Mbps" \
        "4K H.264          40-80 Mbps"

    # Compute the recommendation matrix + suggested-default in one python pass.
    # Python returns the borderless, column-formatted rows on stdout (ui_box
    # supplies the frame) with the suggested default as the LAST line; bash pops
    # that off and renders the rest through ui_box so gum and fallback match.
    # Heuristic: usable = upload * 0.45; raw = usable / viewers; clamp [2, max_cap]
    #   max_cap (1-2 viewers): 8 if upload>=250, 7 if >=100, else 6
    #   max_cap (3-4 viewers): 7 if upload>=500, else 6
    #   max_cap (5+ viewers):  6 if upload>=500, 5 if >=250, else 4
    # 1-2 col borderline: fall back to "1 viewer alone" (floor for safety)
    local _cap_out _cap_rows=() suggested_default
    # Bare assignment (not `local x=$(...)`) so a python failure still aborts the
    # wizard under `set -e`, exactly as before. Capture first, then split with a
    # here-string: `mapfile < <(python3 ...)` would swallow the python exit status
    # AND could leave an empty array for the `[-1]` deref below (unbound abort).
    _cap_out=$(
        UPLOAD="$upload_mbps" python3 <<'PY'
import math, os, sys

def compute_cell(upload, viewers):
    usable = upload * 0.45
    raw = usable / viewers
    if viewers <= 2:
        max_cap = 8 if upload >= 250 else (7 if upload >= 100 else 6)
    elif viewers <= 4:
        max_cap = 7 if upload >= 500 else 6
    else:
        max_cap = 6 if upload >= 500 else (5 if upload >= 250 else 4)
    if viewers == 2 and raw < 3:
        solo = usable
        if solo >= 2:
            return f"{int(min(max_cap, solo))} (1 viewer)"
        return "-"
    if raw < 1.5:
        return "-"
    return str(max(2, min(max_cap, math.ceil(raw))))

upload_speeds = [10, 20, 40, 100, 250, 500]
columns = [(2, "1-2 viewers"), (4, "3-4 viewers"), (6, "5+ viewers")]
# Borderless rows (no +---+, no leading indent) — ui_box draws the frame.
fmt = "{:<8s}  {:<12s} {:<11s} {:<10s}"
header = fmt.format("Upload", *[c[1] for c in columns])
print(header)
print("-" * len(header))
for up in upload_speeds:
    cells = [compute_cell(up, c[0]) for c in columns]
    print(fmt.format(f"{up} Mbps", *cells))

# Default = recommendation for user's upload at 4 viewers (most common case).
# Strip the "(1 viewer)" annotation if present and fall back to "0" on "-".
# Printed LAST so bash can pop it off the row list.
default_cell = compute_cell(int(os.environ["UPLOAD"]), 4)
if default_cell == "-":
    default_cell = compute_cell(int(os.environ["UPLOAD"]), 2)
    if default_cell == "-" or "(1 viewer)" in default_cell:
        default_cell = "0"
    else:
        default_cell = default_cell.split()[0]
else:
    default_cell = default_cell.split()[0]
print(default_cell)
PY
    )
    mapfile -t _cap_rows <<<"$_cap_out"
    suggested_default="${_cap_rows[-1]}"
    unset '_cap_rows[-1]'

    ui_box "Recommended per-viewer cap (Mbps)" \
        "45% of your upload, capped so your home network stays responsive" \
        "(Jellyfin won't try to use the whole line):" \
        "" \
        "${_cap_rows[@]}"

    # Defensive: the validated prompt trusts its default on the DEMO/non-TTY
    # path, so the default MUST be a valid number. The python heredoc always
    # prints one; guard anyway so a future change can't feed an invalid default
    # into the re-prompt loop.
    [[ "$suggested_default" =~ ^[0-9]+(\.[0-9]+)?$ ]] || suggested_default="0"
    local custom
    custom=$(ui_input_validated "Per-viewer cap in Mbps (decimals OK, e.g. 3.5 or 7.0; 0 = unlimited)" "$suggested_default" validate_mbps_decimal)
    _WIZ_JELLYFIN_BITRATE="$custom"

    # This value is Jellyfin's server-wide default; the admin can retune it or
    # override it per user later, so say so rather than imply it's fixed.
    ui_log info "This sets Jellyfin's global remote-streaming cap. Change it anytime in the"
    ui_log info "Jellyfin dashboard under Networking (Remote Client Bitrate Limit), or set a"
    ui_log info "different limit per user in each user's profile."
}

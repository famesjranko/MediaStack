# =============================================================================
# MediaStack — two-axis quality picker (shared)
# =============================================================================
# Single source of truth for the resolution → size selection. Both the setup
# wizard (scripts/setup/stages/stage1.sh) and the day-2 launcher (./mediastack,
# the "Change quality profile" action — issue #71) source this file and call the
# one function, so the two surfaces can never drift in which axes/labels they
# present (the same reason apply_indexers_only is shared).
#
# Menus are built DYNAMICALLY from scripts/setup/presets.yml via
# `wizard_apply.py --list-axes` (TSV) — adding a resolution/size is data-only,
# no edit here. The size menu's GB/movie hint is a (resolution x size) CELL value,
# so the size LABELS are built AFTER the resolution is chosen — 720p shows 720p
# sizes, not 1080p (#96). Both ui_choose prompts set UI_CHOOSE_DEFAULT_INDEX so the
# non-TTY/DEMO path returns the default deterministically (never a re-prompt
# loop, which would hang the PTY harness).
#
# Side-effect-free: sourcing only defines the function. Safe under both
# `set -euo pipefail` (installer) and `set -uo pipefail` (launcher).
# =============================================================================

# Idempotent include guard (see scripts/lib/profiles.sh for the rationale).
[[ -n "${_MS_QUALITY_SELECT_SH_LOADED:-}" ]] && return 0
_MS_QUALITY_SELECT_SH_LOADED=1

# Prompt for resolution then size and write the chosen KEYS to caller variables.
#
#   Usage: quality_select_pick OUT_RES_VAR OUT_SIZE_VAR [DEFAULT_RES] [DEFAULT_SIZE]
#     OUT_RES_VAR / OUT_SIZE_VAR  caller-provided variable names to fill
#     DEFAULT_RES / DEFAULT_SIZE  pre-selected keys (default: 1080p / balanced —
#                                 the effect-equivalent of the old "balanced")
#
# Returns non-zero (and logs) if the menu cannot be read or is empty, so the
# caller can abort instead of feeding an empty list to ui_choose.
quality_select_pick() {
    local -n _qsp_res_out=$1
    local -n _qsp_size_out=$2
    local _qsp_def_res="${3:-1080p}"
    local _qsp_def_size="${4:-balanced}"

    local _qsp_wiz="${SCRIPT_DIR:-$PWD}/scripts/setup/wizard_apply.py"
    local _qsp_tsv
    if ! _qsp_tsv=$(python3 "$_qsp_wiz" --list-axes 2>/dev/null) || [[ -z "$_qsp_tsv" ]]; then
        log_error "Could not read the quality menu from scripts/setup/presets.yml."
        return 1
    fi

    # Parse the menu once. Resolution labels are final here; size LABELS are
    # DEFERRED (built after the resolution pick below) so each GB hint matches the
    # chosen resolution (#96). HINT rows feed a (size|res) -> hint lookup.
    local -a _qsp_rkeys=() _qsp_rlabels=() _qsp_skeys=() _qsp_sdisp=() _qsp_sdesc=() _qsp_slabels=()
    local -A _qsp_hint_map=()
    local _qsp_axis _qsp_key _qsp_disp _qsp_desc _qsp_label
    while IFS=$'\t' read -r _qsp_axis _qsp_key _qsp_disp _qsp_desc; do
        [[ -z "$_qsp_axis" ]] && continue
        case "$_qsp_axis" in
            RESOLUTION)
                _qsp_label="$_qsp_disp"
                [[ -n "$_qsp_desc" ]] && _qsp_label="$_qsp_disp - $_qsp_desc"
                _qsp_rkeys+=("$_qsp_key"); _qsp_rlabels+=("$_qsp_label")
                ;;
            SIZE)
                _qsp_skeys+=("$_qsp_key"); _qsp_sdisp+=("$_qsp_disp"); _qsp_sdesc+=("$_qsp_desc")
                ;;
            HINT)
                # HINT<TAB>size_key<TAB>res_key<TAB>hint — the hint is the 4th
                # field (_qsp_desc): IFS=$'\t' coalesces an empty interior column,
                # so list_axes puts the hint in the description slot, not a padded
                # 5th. (See scripts/setup/wizard_apply.py:list_axes.)
                _qsp_hint_map["${_qsp_key}|${_qsp_disp}"]="$_qsp_desc"
                ;;
        esac
    done <<< "$_qsp_tsv"

    if (( ${#_qsp_rkeys[@]} == 0 || ${#_qsp_skeys[@]} == 0 )); then
        log_error "Quality menu is empty (no resolutions/sizes in presets.yml)."
        return 1
    fi

    local _qsp_i _qsp_di _qsp_chosen

    # Resolution
    _qsp_di=1
    for _qsp_i in "${!_qsp_rkeys[@]}"; do
        [[ "${_qsp_rkeys[$_qsp_i]}" == "$_qsp_def_res" ]] && _qsp_di=$((_qsp_i + 1))
    done
    _qsp_chosen=$(UI_CHOOSE_DEFAULT_INDEX=$_qsp_di ui_choose \
        "Choose the maximum video resolution:" "${_qsp_rlabels[@]}")
    _qsp_res_out="${_qsp_rkeys[0]}"
    for _qsp_i in "${!_qsp_rlabels[@]}"; do
        [[ "${_qsp_rlabels[$_qsp_i]}" == "$_qsp_chosen" ]] && _qsp_res_out="${_qsp_rkeys[$_qsp_i]}"
    done

    # Size labels — built NOW (not at parse time) so each "(~N GB/movie)" hint
    # reflects the resolution just chosen. A cell with no hint just omits it; the
    # ":-" is load-bearing under the installer's `set -euo pipefail`.
    local _qsp_h
    for _qsp_i in "${!_qsp_skeys[@]}"; do
        _qsp_label="${_qsp_sdisp[$_qsp_i]}"
        _qsp_h="${_qsp_hint_map["${_qsp_skeys[$_qsp_i]}|${_qsp_res_out}"]:-}"
        [[ -n "$_qsp_h" ]] && _qsp_label="$_qsp_label ($_qsp_h)"
        [[ -n "${_qsp_sdesc[$_qsp_i]}" ]] && _qsp_label="$_qsp_label - ${_qsp_sdesc[$_qsp_i]}"
        _qsp_slabels+=("$_qsp_label")
    done

    # Size
    _qsp_di=1
    for _qsp_i in "${!_qsp_skeys[@]}"; do
        [[ "${_qsp_skeys[$_qsp_i]}" == "$_qsp_def_size" ]] && _qsp_di=$((_qsp_i + 1))
    done
    _qsp_chosen=$(UI_CHOOSE_DEFAULT_INDEX=$_qsp_di ui_choose \
        "Choose how much storage to spend per movie/show:" "${_qsp_slabels[@]}")
    _qsp_size_out="${_qsp_skeys[0]}"
    for _qsp_i in "${!_qsp_slabels[@]}"; do
        [[ "${_qsp_slabels[$_qsp_i]}" == "$_qsp_chosen" ]] && _qsp_size_out="${_qsp_skeys[$_qsp_i]}"
    done

    # Explicit success — the trailing `for`/`[[ ]]` above would otherwise leave a
    # non-zero exit status, breaking the documented "non-zero only on failure"
    # contract the call sites (and #71) rely on.
    return 0
}

# Owns: stage3_* — Jellyfin encoder configuration/verification, fallback-to-software, and NVIDIA finalize-failure handling.
# Sources: python3 for Jellyfin API JSON; stage3_* marker/state/transcode helpers.

_stage3_apply_runtime_override() {
    local gpu_type="${1:-none}"

    if type detect_host_memory >/dev/null 2>&1 && [[ -z "${HOST_MEMORY_MB:-}" ]]; then
        detect_host_memory
    fi

    if type generate_override >/dev/null 2>&1; then
        generate_override "$gpu_type"
    fi

    if command -v docker >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR" && docker compose up -d jellyfin >/dev/null 2>&1) || return 1
        # Wait for the recreated container to accept `docker exec` before
        # returning. Callers probe/transcode immediately (stage3_probe_capabilities
        # runs codec smoke tests; stage3_verify_transcode_evidence runs the NVENC
        # smoke test) — against a container still restarting, every codec exec
        # fails and NVENC gets silently downgraded to h264-only (or the transcode
        # reads as "no GPU"). Bounded; on timeout proceed anyway and let the
        # probes/verify degrade gracefully rather than block finalize forever.
        local _elapsed=0 _max="${STAGE3_CONTAINER_READY_TIMEOUT:-30}"
        [[ "$_max" =~ ^[0-9]+$ ]] || _max=30
        while ! docker exec jellyfin true >/dev/null 2>&1; do
            ((_elapsed >= _max)) && break
            sleep 2
            ((_elapsed += 2))
        done
        return 0
    fi

    return 0
}

_stage3_offer() {
    {
        ui_section "Hardware transcoding"
        ui_box "Hardware transcoding is optional" \
            "Detected GPU: $(gpu_brand_label "${GPU_TYPE:-none}")" \
            "Jellyfin can use supported GPUs for video conversion." \
            "Intel and AMD finish now. NVIDIA may finish after reboot."
    } >&2
    UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Configure hardware transcoding now?" \
        "Configure hardware transcoding" \
        "Skip for now" \
        "Tell me more"
}

_stage3_tell_me_more() {
    # No section header here — the loop re-enters _stage3_offer immediately after,
    # which prints the "Hardware transcoding" header; printing it here too would
    # double it up.
    ui_log info "Intel and AMD GPUs can be configured now without reboot."
    ui_log info "NVIDIA may need one reboot before MediaStack can finish NVENC setup."
    ui_log info "MediaStack only enables a hardware encoder after verification evidence is available."
    ui_log skip "Skipping keeps Jellyfin on software transcoding."
}

_stage3_choose_gpu_vendor() {
    declare -p GPU_CANDIDATES >/dev/null 2>&1 || return 0
    ((${#GPU_CANDIDATES[@]} > 1)) || return 0

    ui_section "Choose GPU"
    local options=() vendors=() vendor default_index=1 choice
    for vendor in "${GPU_CANDIDATES[@]}"; do
        vendors+=("$vendor")
        case "$vendor" in
            nvidia) options+=("NVIDIA — NVENC") ;;
            amd) options+=("AMD — VAAPI") ;;
            intel) options+=("Intel — Quick Sync") ;;
        esac
        [[ "$vendor" == "${GPU_TYPE:-}" ]] && default_index="${#options[@]}"
    done

    choice=$(UI_CHOOSE_DEFAULT_INDEX="$default_index" ui_choose "Which GPU should Jellyfin use?" "${options[@]}")
    case "$choice" in
        "NVIDIA — NVENC") GPU_TYPE=nvidia ;;
        "AMD — VAAPI") GPU_TYPE=amd ;;
        "Intel — Quick Sync") GPU_TYPE=intel ;;
        *) GPU_TYPE="${vendors[$((default_index - 1))]}" ;;
    esac
}

_stage3_configure_jellyfin() {
    (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only jellyfin)
}

_stage3_verify_jellyfin_encoding() {
    local encoder="$1"
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1

    STAGE3_EXPECTED_ENCODER="$encoder" \
        STAGE3_HW_DECODING_CODECS="${STAGE_3_GPU_HW_DECODING_CODECS:-h264}" \
        STAGE3_DECODE_HEVC_10BIT="${STAGE_3_GPU_DECODE_HEVC_10BIT:-false}" \
        STAGE3_DECODE_VP9_10BIT="${STAGE_3_GPU_DECODE_VP9_10BIT:-false}" \
        STAGE3_ALLOW_HEVC_ENCODING="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-false}" \
        STAGE3_ALLOW_AV1_ENCODING="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-false}" \
        STAGE3_RENDER_DEVICE="${STAGE_3_GPU_RENDER_DEVICE:-/dev/dri/renderD128}" \
        STAGE3_CURRENT_CONFIG="$current" \
        python3 - <<'PY'
import json
import os
import sys

def as_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")

c = json.loads(os.environ["STAGE3_CURRENT_CONFIG"])
encoder = os.environ["STAGE3_EXPECTED_ENCODER"]
expected = {
    "HardwareAccelerationType": encoder,
    "EnableHardwareEncoding": True,
    "HardwareDecodingCodecs": [
        item.strip()
        for item in os.environ.get("STAGE3_HW_DECODING_CODECS", "h264").split(",")
        if item.strip()
    ] or ["h264"],
    "EnableDecodingColorDepth10Hevc": as_bool(os.environ.get("STAGE3_DECODE_HEVC_10BIT", "false")),
    "EnableDecodingColorDepth10Vp9": as_bool(os.environ.get("STAGE3_DECODE_VP9_10BIT", "false")),
    "AllowHevcEncoding": as_bool(os.environ.get("STAGE3_ALLOW_HEVC_ENCODING", "false")),
    "AllowAv1Encoding": as_bool(os.environ.get("STAGE3_ALLOW_AV1_ENCODING", "false")),
}
if encoder == "qsv":
    expected["QsvDevice"] = os.environ.get("STAGE3_RENDER_DEVICE", "")
elif encoder == "vaapi":
    expected["VaapiDevice"] = os.environ.get("STAGE3_RENDER_DEVICE", "")

for key, value in expected.items():
    if c.get(key) != value:
        print(f"{key}: expected {value!r}, got {c.get(key)!r}", file=sys.stderr)
        sys.exit(1)
PY
}

_stage3_wait_for_jellyfin_encoding() {
    local encoder="$1"
    local max_wait="${STAGE3_ENCODING_VERIFY_TIMEOUT:-60}"
    local interval="${STAGE3_ENCODING_VERIFY_INTERVAL:-2}"
    local elapsed=0

    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=60
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=2

    while true; do
        if _stage3_verify_jellyfin_encoding "$encoder"; then
            return 0
        fi
        if ((elapsed >= max_wait)); then
            return 1
        fi
        sleep "$interval" || true
        elapsed=$((elapsed + interval))
    done
}

_stage3_jellyfin_api_key() {
    if [[ -n "${JELLYFIN_API_KEY:-}" ]]; then
        printf '%s\n' "$JELLYFIN_API_KEY"
        return 0
    fi

    python3 - "$SCRIPT_DIR/.env" <<'PY' 2>/dev/null
import pathlib
import shlex
import sys

for raw in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    if key != "JELLYFIN_API_KEY":
        continue
    try:
        parsed = shlex.split(value, posix=True)
        print(parsed[0] if parsed else "")
    except ValueError:
        print(value)
    break
PY
}

_stage3_disable_jellyfin_hardware() {
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current body
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1
    body=$(echo "$current" | python3 -c '
import json
import sys
c = json.load(sys.stdin)
c["HardwareAccelerationType"] = "none"
c["EnableHardwareEncoding"] = False
print(json.dumps(c))
')
    curl -sf -X POST "$jf_url/System/Configuration/encoding" \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1
}

_stage3_encoder_disabled() {
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1
    # Fallback is safe only when Jellyfin reports full software mode.
    STAGE3_CURRENT_CONFIG="$current" \
        python3 - <<'PY'
import json
import os
import sys

try:
    c = json.loads(os.environ["STAGE3_CURRENT_CONFIG"])
except Exception:
    sys.exit(1)

if c.get("HardwareAccelerationType") == "none" and c.get("EnableHardwareEncoding") is False:
    sys.exit(0)

sys.exit(1)
PY
}

_stage3_fallback() {
    local vendor="${1:-}"
    local encoder="${2:-}"
    if ! stage3_set_gpu_env "none" "fallback" "$vendor" "$encoder"; then
        ui_log warn "Could not persist software fallback state; hardware fallback was not applied."
        return 3
    fi
    stage3_remove_nvidia_marker
    GPU_TYPE="none"
    _stage3_configure_jellyfin >/dev/null 2>&1 || true
    if ! _stage3_disable_jellyfin_hardware; then
        ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
    elif ! _stage3_encoder_disabled "$encoder"; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi
    _stage3_apply_runtime_override "none"
    ui_log warn "Hardware transcoding could not be verified. Jellyfin will use software transcoding. Fix the driver/runtime issue, then choose Manage hardware transcoding (GPU) from the menu."
    _stage3_print_final_summary
    # Only the durable write above is a meaningful status here: callers treat a
    # non-zero return as "state could not be persisted", so the summary's own
    # exit status must never reach them.
    return 0
}

_stage3_skip_to_software_mode() {
    local prior_gpu="${1:-none}"
    local warn_if_disable_fails=false

    stage3_remove_nvidia_marker

    case "$prior_gpu" in
        intel | amd | nvidia) warn_if_disable_fails=true ;;
    esac

    if ! _stage3_disable_jellyfin_hardware; then
        if [[ "$warn_if_disable_fails" == "true" ]]; then
            ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
        fi
    elif ! _stage3_encoder_disabled; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi

    _stage3_apply_runtime_override "none" || true
}

_stage3_nvidia_finalize_failure() {
    if ! stage3_set_gpu_env "none" "fallback" "nvidia" "nvenc"; then
        ui_log warn "Could not persist NVIDIA software fallback state; recovery marker retained."
        return 3
    fi
    _stage3_configure_jellyfin >/dev/null 2>&1 || true
    if ! _stage3_disable_jellyfin_hardware; then
        ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
    elif ! _stage3_encoder_disabled "nvenc"; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi
    _stage3_apply_runtime_override "none"
    stage3_remove_nvidia_marker
    ui_log warn "NVIDIA finalization did not complete. MediaStack is falling back to software transcoding; check journalctl -u mediastack-setup --no-pager, fix the driver/runtime issue, then choose Manage hardware transcoding (GPU) from the menu."
    _stage3_print_final_summary
    return 0
}

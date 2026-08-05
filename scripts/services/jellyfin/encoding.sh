# Owns: configure_jellyfin_encoding — hardware transcoding (encoding.xml) via the System/Configuration/encoding API.
# Sources: main.sh (auth/session context), api helpers and log_* from scripts/lib/common.sh.

configure_jellyfin_encoding() {
    local jf_url="$1" jf_token="$2"
    local gpu="${JELLYFIN_GPU:-none}"

    if [[ "$gpu" == "none" || -z "$gpu" ]]; then
        case "${STAGE_3_GPU_STATE:-}" in
            skipped) log_skip "Hardware transcoding: skipped - Jellyfin will use software transcoding" ;;
            fallback) log_skip "Hardware transcoding: fallback - Jellyfin will use software transcoding" ;;
            *) log_skip "Hardware transcoding: not configured yet - setup handles GPU after Core LAN" ;;
        esac
        return 0
    fi

    local accel_type
    case "$gpu" in
        nvidia) accel_type="nvenc" ;;
        intel)
            case "${STAGE_3_GPU_ENCODER:-qsv}" in
                vaapi) accel_type="vaapi" ;;
                *) accel_type="qsv" ;;
            esac
            ;;
        amd) accel_type="vaapi" ;;
        *)
            log_skip "Hardware transcoding: unknown GPU type '$gpu'"
            return 0
            ;;
    esac
    local render_device="${STAGE_3_GPU_RENDER_DEVICE:-/dev/dri/renderD128}"

    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""

    local current_config
    if ! current_config=$(api_fetch "Jellyfin encoding config" \
        "$jf_url/System/Configuration/encoding" -H "Authorization: $auth"); then
        log_warn "Could not read Jellyfin encoding config - skipping"
        return 0
    fi

    # Jellyfin defaults HardwareAccelerationType to "none" (not "").
    # Both "none" and "" mean "unconfigured / software transcoding".
    local current_accel
    current_accel=$(echo "$current_config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c.get('HardwareAccelerationType', ''))" 2>/dev/null)

    local stage3_state="${STAGE_3_GPU_STATE:-}"
    if [[ "$stage3_state" == "complete" && "$current_accel" != "$accel_type" ]]; then
        log_drift "Jellyfin transcoding is '$current_accel', expected '$accel_type' from completed hardware transcoding proof. Leaving manual Jellyfin settings unchanged; choose Manage hardware transcoding (GPU) -> Configure or change hardware transcoding to re-verify and apply."
        return 0
    fi

    local allow_intel_method_switch=false
    if [[ "$gpu" == "intel" && "$stage3_state" == "pending" ]]; then
        case "$current_accel:$accel_type" in
            qsv:vaapi | vaapi:qsv) allow_intel_method_switch=true ;;
        esac
    fi
    if [[ "$current_accel" != "$accel_type" && "$current_accel" != "none" && -n "$current_accel" && "$allow_intel_method_switch" != "true" ]]; then
        log_drift "Jellyfin transcoding is '$current_accel', expected '$accel_type' (from JELLYFIN_GPU=$gpu). To reset: Jellyfin Dashboard -> Playback -> Transcoding."
        return 0
    fi

    # GET-merge-POST: modify only GPU-related fields, preserve everything else.
    local encoding_result encoding_action encoding_body
    encoding_result=$(echo "$current_config" \
        | ACCEL_TYPE="$accel_type" \
            HW_DECODING_CODECS="${STAGE_3_GPU_HW_DECODING_CODECS:-h264}" \
            DECODE_HEVC_10BIT="${STAGE_3_GPU_DECODE_HEVC_10BIT:-false}" \
            DECODE_VP9_10BIT="${STAGE_3_GPU_DECODE_VP9_10BIT:-false}" \
            ALLOW_HEVC_ENCODING="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-false}" \
            ALLOW_AV1_ENCODING="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-false}" \
            RENDER_DEVICE="$render_device" \
            python3 -c "
import sys, json, os
c = json.load(sys.stdin)
accel = os.environ['ACCEL_TYPE']
def as_bool(value):
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')
codecs = [
    item.strip()
    for item in os.environ.get('HW_DECODING_CODECS', 'h264').split(',')
    if item.strip()
]
if not codecs:
    codecs = ['h264']
desired = {
    'HardwareAccelerationType': accel,
    'EnableHardwareEncoding': True,
    'HardwareDecodingCodecs': codecs,
    'EnableDecodingColorDepth10Hevc': as_bool(os.environ.get('DECODE_HEVC_10BIT', 'false')),
    'EnableDecodingColorDepth10Vp9': as_bool(os.environ.get('DECODE_VP9_10BIT', 'false')),
    'EnableDecodingColorDepth10HevcRext': False,
    'EnableDecodingColorDepth12HevcRext': False,
    'AllowHevcEncoding': as_bool(os.environ.get('ALLOW_HEVC_ENCODING', 'false')),
    'AllowAv1Encoding': as_bool(os.environ.get('ALLOW_AV1_ENCODING', 'false')),
}
if accel == 'nvenc':
    desired.update({
        'EnableEnhancedNvdecDecoder': True,
        'EnableTonemapping': True,
        'TonemappingAlgorithm': 'bt2390',
    })
elif accel == 'qsv':
    desired.update({
        'QsvDevice': os.environ.get('RENDER_DEVICE', ''),
        'VaapiDevice': '',
        'EnableVppTonemapping': False,
        'EnableTonemapping': True,
        'TonemappingAlgorithm': 'bt2390',
    })
elif accel == 'vaapi':
    desired.update({
        'VaapiDevice': os.environ.get('RENDER_DEVICE', '/dev/dri/renderD128'),
        'EnableTonemapping': True,
        'EnableVppTonemapping': False,
        'TonemappingAlgorithm': 'bt2390',
    })
changed = False
for key, value in desired.items():
    if c.get(key) != value:
        c[key] = value
        changed = True
print('APPLY' if changed else 'SKIP')
if changed:
    print(json.dumps(c))")
    encoding_action=$(echo "$encoding_result" | head -1)
    if [[ "$encoding_action" == "SKIP" ]]; then
        log_skip "Hardware transcoding already set to $accel_type"
        return 0
    fi
    if [[ "$encoding_action" != "APPLY" ]]; then
        log_warn "Unexpected Jellyfin encoding config diff result - skipping"
        return 0
    fi
    if [[ "$stage3_state" == "complete" ]]; then
        log_drift "Jellyfin hardware transcoding settings differ from the completed hardware transcoding proof. Leaving manual Jellyfin settings unchanged; choose Manage hardware transcoding (GPU) -> Configure or change hardware transcoding to re-verify and apply."
        return 0
    fi
    encoding_body=$(echo "$encoding_result" | tail -n +2)

    if api_fetch "Jellyfin encoding config" \
        "$jf_url/System/Configuration/encoding" \
        -X POST \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$encoding_body" >/dev/null; then
        log_ok "Hardware transcoding: $accel_type (from JELLYFIN_GPU=$gpu)"
    else
        log_warn "Failed to set Jellyfin encoding config - configure manually in Dashboard -> Playback -> Transcoding"
    fi
}

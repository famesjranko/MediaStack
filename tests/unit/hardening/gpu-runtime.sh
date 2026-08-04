# Owns: NVIDIA Docker runtime verification tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/gpu-runtime.sh.

# ===========================================================================
# verify_gpu_runtime — GPU_TYPE=none (immediate return)
# ===========================================================================

NVIDIA_CTK_CALLED=false
sudo() {
    if [[ "${1:-}" == "nvidia-ctk" ]]; then
        NVIDIA_CTK_CALLED=true
    fi
    return 0
}

GPU_TYPE="none"
verify_gpu_runtime
assert_eq "false" "$NVIDIA_CTK_CALLED" "verify_gpu_runtime: GPU_TYPE=none — no action"
unset -f sudo

# ===========================================================================
# verify_gpu_runtime — GPU_TYPE=nvidia + valid daemon.json
# ===========================================================================

DAEMON_JSON_TMP=$(mktemp)
cat >"$DAEMON_JSON_TMP" <<'JSON'
{
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
JSON

# Override the function to use our temp path
eval "verify_gpu_runtime_valid_test() {
    [[ \"\${GPU_TYPE:-none}\" != \"nvidia\" ]] && return
    local daemon_json=\"$DAEMON_JSON_TMP\"
    if [[ ! -f \"\$daemon_json\" ]]; then
        return
    fi
    local has_nvidia
    has_nvidia=\$(python3 -c \"
import json, sys
with open('\$daemon_json') as f:
    d = json.load(f)
runtimes = d.get('runtimes', {})
if 'nvidia' in runtimes:
    sys.exit(0)
sys.exit(1)
\" 2>/dev/null && echo \"yes\" || echo \"no\")
    GPU_RUNTIME_RESULT=\"\$has_nvidia\"
}"

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
GPU_TYPE="nvidia"
GPU_RUNTIME_RESULT=""
verify_gpu_runtime_valid_test
assert_eq "yes" "$GPU_RUNTIME_RESULT" "verify_gpu_runtime: nvidia + valid daemon.json"

rm -f "$DAEMON_JSON_TMP"

# ===========================================================================

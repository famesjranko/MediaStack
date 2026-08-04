# Owns: pre-wizard NVIDIA Docker runtime verification.
# Sources: hardening.sh globals, common.sh logging, and host python3.
# Globals: GPU_TYPE (optional persisted hardware choice).

verify_gpu_runtime() {
    [[ "${GPU_TYPE:-none}" != "nvidia" ]] && return

    local daemon_json="/etc/docker/daemon.json"
    if [[ ! -f "$daemon_json" ]]; then
        if ! command -v nvidia-ctk &>/dev/null; then
            return # nvidia-ctk not installed yet — Stage 3 will configure the runtime
        fi
        log_warn "daemon.json missing - attempting nvidia-ctk runtime configure..."
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        sudo systemctl restart docker 2>/dev/null || true
        return
    fi

    local has_nvidia
    has_nvidia=$(python3 -c "
import json, sys
with open('$daemon_json') as f:
    d = json.load(f)
runtimes = d.get('runtimes', {})
if 'nvidia' in runtimes:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")

    if [[ "$has_nvidia" == "yes" ]]; then
        log_ok "NVIDIA Docker runtime registered in daemon.json"
    else
        log_warn "NVIDIA runtime missing from daemon.json - attempting auto-repair..."
        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
        sudo systemctl restart docker 2>/dev/null || true
    fi
}

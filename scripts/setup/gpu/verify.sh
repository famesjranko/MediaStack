# Owns: nvidia_* verify_* — final GPU usability checks and vendor-specific verification state.
# Sources: gpu.sh detection helpers, common.sh logging, and host GPU commands.
_nvidia_docker_runtime_state() {
    local keys
    for _ in 1 2 3 4; do
        if keys="$(docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null)" \
            && [[ -n "$keys" ]]; then
            case " $keys " in
                *" nvidia "*) printf 'registered' ;;
                *) printf 'absent' ;;
            esac
            return 0
        fi
        sleep 2
    done
    printf 'unknown'
}

# Confirm the selected GPU is actually usable before we write the compose
# override. A broken override (e.g. runtime: nvidia pointing at a runtime
# that isn't registered) prevents Jellyfin from starting at all — worse
# than just losing hardware acceleration. Mutates global GPU_TYPE.
verify_gpu_usable() {
    case "$GPU_TYPE" in
        nvidia)
            if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi -L &>/dev/null; then
                log_error "NVIDIA hardware detected but nvidia-smi is not working."
                log_error "Driver failed to load (Secure Boot blocking the module? DKMS build failure? pending reboot?)."
                log_warn "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            if ! command -v nvidia-container-runtime &>/dev/null; then
                log_error "nvidia-container-runtime binary not found."
                log_error "Try: sudo apt-get install --reinstall nvidia-container-toolkit"
                log_warn "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            # Confirm Docker's nvidia runtime is registered — robustly, treating
            # the three states distinctly (never silently fall back on a transient
            # miss):
            local _rt_state
            _rt_state="$(_nvidia_docker_runtime_state)"
            case "$_rt_state" in
                registered)
                    log_ok "NVIDIA GPU verified (nvidia-smi + docker runtime)"
                    ;;
                absent)
                    # CONFIRMED missing: the toolkit is present but the runtime is
                    # not registered with Docker. Self-heal (idempotent reconfigure
                    # + restart) and re-check; only fall back if it is still absent.
                    # The Docker restart is justified here because the runtime is
                    # confirmed missing — not merely unprobeable.
                    log_warn "Docker's NVIDIA runtime is not registered; configuring it now..."
                    sudo nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
                    sudo systemctl restart docker >/dev/null 2>&1 \
                        || sudo service docker restart >/dev/null 2>&1 || true
                    if [[ "$(_nvidia_docker_runtime_state)" == "registered" ]]; then
                        log_ok "NVIDIA GPU verified (nvidia-smi + docker runtime now registered)"
                    else
                        log_error "Docker's NVIDIA runtime could not be registered."
                        log_error "Try: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
                        log_warn "Falling back to software transcoding."
                        GPU_TYPE="none"
                        return
                    fi
                    ;;
                *)
                    # unknown: `docker info` was unreadable after retries (busy
                    # daemon) — NOT a confirmed-missing runtime. Do NOT bounce a
                    # possibly-healthy daemon, and do NOT silently drop the GPU on
                    # an inconclusive probe. Keep nvidia; the real test transcode in
                    # _stage3_configure_and_verify / stage3_finalize_nvidia is the
                    # authoritative gate and falls back cleanly if it truly fails.
                    log_warn "Could not confirm Docker's NVIDIA runtime (daemon busy?); the test transcode will confirm GPU usability."
                    log_ok "NVIDIA GPU verified (nvidia-smi; docker runtime check inconclusive)"
                    ;;
            esac
            ;;
        amd)
            local render_device
            render_device="$(gpu_persisted_render_device amd || gpu_render_device_for_vendor amd || true)"
            if [[ -z "$render_device" ]]; then
                log_error "AMD GPU detected but no /dev/dri/renderD* device is available."
                log_warn "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            log_ok "AMD GPU verified ($render_device present)"
            if command -v vainfo &>/dev/null; then
                log_info "VAAPI info (host): $(vainfo 2>&1 | head -3 | tr '\n' ' ')"
            fi
            ;;
        intel)
            local render_device
            render_device="$(gpu_persisted_render_device intel || gpu_render_device_for_vendor intel || true)"
            if [[ -z "$render_device" ]]; then
                log_error "Intel GPU detected but no /dev/dri/renderD* device is available."
                log_warn "Falling back to software transcoding."
                GPU_TYPE="none"
                return
            fi
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            log_ok "Intel GPU verified ($render_device present)"
            if command -v vainfo &>/dev/null; then
                log_info "VAAPI info (host): $(vainfo 2>&1 | head -3 | tr '\n' ' ')"
            fi
            ;;
    esac
}

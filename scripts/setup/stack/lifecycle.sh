# Owns: Image pulls, stack start, and post-start health-gating for setup.sh.
# Sources: scripts/setup/stack.sh state ($SCRIPT_DIR, STACK_PULL_*/STACK_HEALTH_* vars, profiles_build_args) plus scripts/lib/common.sh.

pull_images() {
    cd "$SCRIPT_DIR" || return 1
    local profiles=()
    profiles_build_args profiles
    local image_channel="${IMAGE_CHANNEL:-stable}"
    image_channel="${image_channel,,}"

    # Count active-profile images and how many are already pulled locally.
    # --policy missing below means pulls only fetch what's actually new; this
    # preamble lets us short-circuit when nothing is missing and gives the user
    # an honest line about what's happening (they were previously seeing 20-30
    # min of "Downloading..." for images they already had — silent updates).
    local total=0 present=0
    local image_list
    image_list=$(docker compose "${profiles[@]}" config --images 2>/dev/null || true)
    if [[ -n "$image_list" ]]; then
        total=$(printf '%s\n' "$image_list" | grep -c .)
        present=$(printf '%s\n' "$image_list" \
            | xargs -r -I{} docker image inspect --format=ok {} 2>/dev/null \
            | grep -c ok || true)
    fi

    if ((total > 0 && present == total)); then
        log_ok "All ${total} images already present locally - skipping pull"
        log_info "To check for and apply image updates later, run ./mediastack -> Manage updates."
        return 0
    elif ((present > 0 && present < total)); then
        log_info "Pulling ${image_channel} channel container images (${present}/${total} already present, fetching $((total - present)) new)..."
    else
        log_info "Pulling ${image_channel} channel container images..."
    fi

    local attempt max_attempts="$STACK_PULL_MAX_ATTEMPTS"
    local backoff="$STACK_PULL_INITIAL_BACKOFF_SECONDS"
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if docker compose "${profiles[@]}" pull --policy missing 2>&1; then
            log_ok "All images pulled successfully"
            return 0
        fi

        if ((attempt < max_attempts)); then
            log_warn "Image pull failed (attempt ${attempt}/${max_attempts}). Retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff * 2))
        fi
    done

    log_warn "Some images could not be pulled after ${max_attempts} attempts."
    log_warn "Continuing with cached images (if any). Services with missing images will not start."
    log_info "You can retry manually later: docker compose ${profiles[*]} pull --policy missing"
    log_info "Or, once registry access recovers, run ./mediastack -> Manage updates."
    return 0
}

start_stack() {
    log_info "Starting MediaStack..."
    cd "$SCRIPT_DIR" || return 1
    if declare -F storage_guard_before_start >/dev/null; then
        storage_guard_before_start || return 1
    fi
    if [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
        export UNPACKERR_TORRENT_PATHS="${UNPACKERR_TORRENT_PATHS-}"
    elif [[ -z "${UNPACKERR_TORRENT_PATHS:-}" ]]; then
        export UNPACKERR_TORRENT_PATHS="/data/torrents"
    fi
    local profiles=()
    profiles_build_args profiles
    # Stop containers from profiles that are no longer selected (re-run safety).
    # docker compose up -d does NOT stop containers from a previously-active
    # profile, so a domain→local switch would leave NPM/fail2ban running.
    if [[ ! " ${profiles[*]} " =~ " --profile proxy " ]]; then
        for svc in npm fail2ban ddns-updater; do
            if service_container_running "$svc"; then
                log_info "Stopping leftover $svc (proxy profile no longer active)..."
                docker stop "$svc" >/dev/null 2>&1 && docker rm "$svc" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [[ ! " ${profiles[*]} " =~ " --profile subtitles " ]]; then
        if service_container_running bazarr; then
            log_info "Stopping leftover bazarr (subtitles profile no longer active)..."
            docker stop bazarr >/dev/null 2>&1 && docker rm bazarr >/dev/null 2>&1 || true
        fi
    fi
    if [[ ! " ${profiles[*]} " =~ " --profile autoheal " ]]; then
        if service_container_running autoheal; then
            log_info "Stopping leftover autoheal (AUTOHEAL_ENABLED=false)..."
            docker stop autoheal >/dev/null 2>&1 && docker rm autoheal >/dev/null 2>&1 || true
        fi
    fi

    ensure_mediastack_network_config
    docker compose "${profiles[@]}" up -d
    log_ok "Containers started"
}

wait_all_healthy() {
    local timeout="$STACK_HEALTH_TIMEOUT_SECONDS"
    local elapsed=0
    local interval="$STACK_HEALTH_POLL_INTERVAL_SECONDS"
    local profiles=()
    profiles_build_args profiles
    local expected_services
    if (($# > 0)); then
        expected_services=$(printf '%s\n' "$@")
    else
        expected_services=$(docker compose "${profiles[@]}" ps --all --services 2>/dev/null || true)
    fi

    local _spin_i=0 _fc=${#_G_SPIN[@]}

    while ((elapsed < timeout)); do
        local status_report failed waiting restarting no_health missing
        status_report=$(docker compose "${profiles[@]}" ps --all --format json 2>/dev/null \
            | EXPECTED_SERVICES="$expected_services" python3 -c "
import json
import os
import sys

expected = set(filter(None, os.environ.get('EXPECTED_SERVICES', '').split()))
records = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if isinstance(obj, list):
        records.extend(obj)
    else:
        records.append(obj)

seen = set()
failed = []
waiting = []
restarting = []
no_health = []

for svc in records:
    service = str(svc.get('Service') or svc.get('service') or '')
    name = str(svc.get('Name') or svc.get('name') or service or 'unknown')
    label = service or name
    seen.add(service or label)

    state = str(svc.get('State') or svc.get('state') or '').lower()
    health = str(svc.get('Health') or svc.get('health') or '').lower()
    status_text = str(svc.get('Status') or svc.get('status') or '').lower()
    if not health:
        if 'unhealthy' in status_text:
            health = 'unhealthy'
        elif 'healthy' in status_text:
            health = 'healthy'

    if state == 'running':
        if health and health not in ('healthy', 'none', '-'):
            waiting.append(f'{label}({health})')
        elif health in ('', 'none', '-'):
            no_health.append(label)
    elif state in ('exited', 'dead'):
        failed.append(f'{label}({state})')
    elif state == 'restarting':
        restarting.append(label)
    elif state:
        waiting.append(f'{label}({state})')
    else:
        waiting.append(f'{label}(unknown)')

missing = sorted(expected - seen)
if not records and not expected:
    waiting.append('compose-status-unavailable')

print('failed\\t' + ' '.join(failed))
print('waiting\\t' + ' '.join(waiting))
print('restarting\\t' + ' '.join(restarting))
print('no_health\\t' + ' '.join(no_health))
print('missing\\t' + ' '.join(missing))
" 2>/dev/null || printf 'failed\tcompose-status-unavailable\nwaiting\t\nrestarting\t\nno_health\t\nmissing\t\n')

        failed=""
        waiting=""
        restarting=""
        no_health=""
        missing=""
        while IFS=$'\t' read -r key value; do
            case "$key" in
                failed) failed="$value" ;;
                waiting) waiting="$value" ;;
                restarting) restarting="$value" ;;
                no_health) no_health="$value" ;;
                missing) missing="$value" ;;
            esac
        done <<<"$status_report"

        if [[ -n "$failed" || -n "$missing" ]]; then
            echo -ne "\r\033[K"
            [[ -n "$failed" ]] && log_warn "Some services stopped unexpectedly: ${failed}"
            [[ -n "$missing" ]] && log_warn "Some expected services are missing: ${missing}"
            log_info "Current container state:"
            docker compose "${profiles[@]}" ps || true
            return 1
        fi

        # restarting containers (e.g. beszel-agent before its key is configured)
        # are not a blocker — configure.sh will complete their initialisation.
        if [[ -z "$waiting" ]]; then
            echo -ne "\r\033[K"
            if [[ -n "$restarting" ]]; then
                log_ok "Services ready — ${restarting} still initializing (configure.sh will complete setup)"
            elif [[ -n "$no_health" ]]; then
                log_ok "All services healthy/running (no healthcheck: ${no_health})"
            else
                log_ok "All services healthy!"
            fi
            return 0
        fi

        # Animate spinner during the poll interval.
        local _fmt="${waiting// / · }"
        local _ticks=$((interval * 1000 / STACK_HEALTH_SPINNER_FRAME_MS))
        for ((_t = 0; _t < _ticks; _t++)); do
            echo -ne "\r  ${_UI_CYAN}${_G_SPIN[$((_spin_i % _fc))]}${_UI_RESET}  Waiting for services (${elapsed}s/${timeout}s) — ${_fmt}\033[K"
            ((_spin_i = _spin_i + 1))
            sleep "$STACK_HEALTH_SPINNER_SLEEP_SECONDS"
        done
        ((elapsed += interval))
    done

    echo -ne "\r\033[K"
    log_warn "Some services may still be starting after ${timeout}s. Check the menu: Manage stack."
}

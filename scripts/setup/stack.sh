# =============================================================================
# MediaStack Setup — Data dirs, config dirs, stack lifecycle, access info
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

# Shared docker-compose profile-arg builder (profiles_build_args), also used by
# the ./mediastack launcher so the day-2 menu's stop/start/status always targets
# the same profile set the installer used. Resolved relative to this file so
# every sourcer (setup.sh and the unit/scenario tests) finds it regardless of CWD.
_STACK_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_STACK_HELPER_DIR="$(cd "$_STACK_MODULE_DIR/.." && pwd)"
# shellcheck source=../lib/profiles.sh
source "$_STACK_HELPER_DIR/lib/profiles.sh"
unset _STACK_HELPER_DIR

# Topic modules, split out of this file for size: image pull/start/health,
# data & config dir management, and the final/day-2 summary rendering. Kept
# in this one place so every sourcer (setup.sh, the launcher, and the
# unit/scenario tests) gets the full stack.sh surface from a single source.
# shellcheck source=stack/lifecycle.sh
source "$_STACK_MODULE_DIR/stack/lifecycle.sh"
# shellcheck source=stack/dirs.sh
source "$_STACK_MODULE_DIR/stack/dirs.sh"
# shellcheck source=stack/summary.sh
source "$_STACK_MODULE_DIR/stack/summary.sh"

: "${STACK_PULL_MAX_ATTEMPTS:=3}"
: "${STACK_PULL_INITIAL_BACKOFF_SECONDS:=10}"
: "${STACK_HEALTH_TIMEOUT_SECONDS:=120}"
: "${STACK_HEALTH_POLL_INTERVAL_SECONDS:=5}"
: "${STACK_HEALTH_SPINNER_FRAME_MS:=80}"
: "${STACK_HEALTH_SPINNER_SLEEP_SECONDS:=0.08}"
readonly STACK_PULL_MAX_ATTEMPTS STACK_PULL_INITIAL_BACKOFF_SECONDS
readonly STACK_HEALTH_TIMEOUT_SECONDS STACK_HEALTH_POLL_INTERVAL_SECONDS
readonly STACK_HEALTH_SPINNER_FRAME_MS STACK_HEALTH_SPINNER_SLEEP_SECONDS

_stack_env_get() {
    local key="$1"
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    python3 - "$SCRIPT_DIR/.env" "$key" <<'PY'
import pathlib
import shlex
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for raw in env_path.read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    name, value = raw.split("=", 1)
    if name != key:
        continue
    try:
        parsed = shlex.split(value, posix=True)
        print(parsed[0] if parsed else "", end="")
    except ValueError:
        print(value.strip("'\""), end="")
    break
PY
}

_stack_save_env_value() {
    local key="$1" value="$2"
    export "${key}=${value}"
    if [[ -f "$SCRIPT_DIR/.env" ]] && declare -F env_save_api_key >/dev/null; then
        env_save_api_key "$key" "$value"
    fi
}

ensure_mediastack_network_config() {
    local requested_prefix="${MEDIASTACK_NETWORK_PREFIX:-}"
    local requested_subnet="${MEDIASTACK_SUBNET:-}"
    local requested_gateway="${MEDIASTACK_GATEWAY:-}"
    local stage1_complete="${STAGE_1_COMPLETE:-}"
    if [[ -z "$requested_prefix" ]]; then
        requested_prefix="$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)"
    fi
    if [[ -z "$requested_subnet" ]]; then
        requested_subnet="$(_stack_env_get MEDIASTACK_SUBNET)"
    fi
    if [[ -z "$requested_gateway" ]]; then
        requested_gateway="$(_stack_env_get MEDIASTACK_GATEWAY)"
    fi
    if [[ -z "$stage1_complete" ]]; then
        stage1_complete="$(_stack_env_get STAGE_1_COMPLETE)"
    fi

    local tmp_dir routes_file addrs_file docker_file mediastack_file
    tmp_dir=$(mktemp -d)
    routes_file="$tmp_dir/routes.txt"
    addrs_file="$tmp_dir/addrs.txt"
    docker_file="$tmp_dir/docker.json"
    mediastack_file="$tmp_dir/mediastack.json"

    if command -v ip >/dev/null 2>&1; then
        ip -o -4 route show >"$routes_file" 2>/dev/null || : >"$routes_file"
        ip -o -4 addr show >"$addrs_file" 2>/dev/null || : >"$addrs_file"
    else
        : >"$routes_file"
        : >"$addrs_file"
    fi

    : >"$docker_file"
    : >"$mediastack_file"
    if command -v docker >/dev/null 2>&1; then
        local docker_network_ids
        docker_network_ids=$(docker network ls -q 2>/dev/null || true)
        if [[ -n "$docker_network_ids" ]]; then
            docker network inspect $docker_network_ids >"$docker_file" 2>/dev/null || : >"$docker_file"
        fi
        docker network inspect mediastack >"$mediastack_file" 2>/dev/null || : >"$mediastack_file"
    fi

    local selector_output selector_rc=0
    selector_output=$(REQUESTED_PREFIX="$requested_prefix" REQUESTED_SUBNET="$requested_subnet" REQUESTED_GATEWAY="$requested_gateway" STAGE1_COMPLETE="$stage1_complete" \
        python3 "$_STACK_MODULE_DIR/render/network_selector.py" "$routes_file" "$addrs_file" "$docker_file" "$mediastack_file") || selector_rc=$?
    rm -rf "$tmp_dir"

    if ((selector_rc != 0)); then
        while IFS= read -r line; do
            case "$line" in
                ERROR:*) log_error "${line#ERROR: }" ;;
                INFO:*) log_info "${line#INFO: }" ;;
                *) [[ -n "$line" ]] && log_info "$line" ;;
            esac
        done <<<"$selector_output"
        return 1
    fi

    local prefix="" subnet="" gateway="" npm_ip="" key value
    while IFS='=' read -r key value; do
        case "$key" in
            MEDIASTACK_NETWORK_PREFIX) prefix="$value" ;;
            MEDIASTACK_SUBNET) subnet="$value" ;;
            MEDIASTACK_GATEWAY) gateway="$value" ;;
            MEDIASTACK_NPM_IP) npm_ip="$value" ;;
        esac
    done <<<"$selector_output"

    if [[ -z "$prefix" || -z "$subnet" || -z "$gateway" || -z "$npm_ip" ]]; then
        log_error "Could not determine MediaStack Docker subnet."
        return 1
    fi

    _stack_save_env_value MEDIASTACK_NETWORK_PREFIX "$prefix"
    _stack_save_env_value MEDIASTACK_SUBNET "$subnet"
    _stack_save_env_value MEDIASTACK_GATEWAY "$gateway"
    _stack_save_env_value MEDIASTACK_NPM_IP "$npm_ip"
    log_ok "Docker bridge subnet: ${subnet} (NPM ${npm_ip})"
}

# An explicitly unhealthy running container makes the readiness probe fail. The
# recreate seam must propagate that failure: an unhealthy service is not a
# successful update and must not be flipped green in the cached table.
unhealthy_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  source "$REPO_ROOT/scripts/setup/override.sh"
  _service_profile_flag(){ echo ""; }
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  ui_confirm(){ return 0; }
  ui_log(){ printf "UI_%s:%s\n" "$1" "$2"; }
  sleep(){ :; }
  docker(){
    if [[ "$1" == "compose" ]]; then
      return 0
    fi
    if [[ "$1" == "inspect" ]]; then
      case "$*" in
        *"State.Status"*) echo "running" ;;
        *"State.Health"*) echo "unhealthy" ;;
        *"State.Running"*) echo "true" ;;
      esac
    fi
  }
  _MU_APPLIED=()
  _apply_service_update sonarr
  echo "RC=$?"
  echo "APPLIED=[${_MU_APPLIED[*]}]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$unhealthy_out" "RC=1" \
    "unhealthy: running unhealthy container fails the update"
assert_contains "$unhealthy_out" "APPLIED=[]" \
    "unhealthy: running unhealthy container is not flipped green"
if grep -q "UI_ok:sonarr updated\." <<<"$unhealthy_out"; then
    fail "unhealthy: running unhealthy container does not log update success"
else
    pass "unhealthy: running unhealthy container does not log update success"
fi

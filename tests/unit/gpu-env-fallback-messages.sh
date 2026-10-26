#!/usr/bin/env bash
# tests/unit/gpu-env-fallback-messages.sh
#
# GPU contracts: .env writer parity (E1), recorded transcoding outcomes (E2),
# and user-facing messages that prefer ./mediastack, with one exact Jellyfin recovery exception (E3).

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="gpu-env-fallback-messages"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/env-gen.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/lib/env-update.sh"
source "$REPO_ROOT/scripts/lib/gpu-fallback.sh"
source "$REPO_ROOT/scripts/setup/stage3/state.sh"

set +e
set +u
log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }

DDNS_UPDATER_UID="$(id -u)"
DDNS_UPDATER_GID="$(id -g)"
_ENV_TZ="Etc/UTC"
_ENV_PUID="$(id -u)"
_ENV_PGID="$(id -g)"
_ENV_HOST_ADDRESS="192.168.1.10"
# shellcheck disable=SC2034 # read by write_env
GPU_TYPE="none"
_WIZ_TZ="Etc/UTC"
_WIZ_DATA_DIR="/data"
_WIZ_ADMIN_USER="admin"
_WIZ_ADMIN_PW="GeneratedPassword123"
_WIZ_ADMIN_EMAIL="owner@gate.test"
_WIZ_DOMAIN=""
SCRIPT_DIR="$TMP_ROOT/box"
mkdir -p "$SCRIPT_DIR/config/ddns-updater"

# --- E1: template and _env_write_kv emit the same bytes -------------------
# Given an .env written by the install template
write_env >/dev/null
sha_template=$(sha256sum "$SCRIPT_DIR/.env" | cut -d' ' -f1)

# When every key in it is re-written with its own current value through _env_write_kv
pairs=()
while IFS= read -r line; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    v="${BASH_REMATCH[2]}"
    v="${v#\'}"
    v="${v%\'}"
    pairs+=("${BASH_REMATCH[1]}" "$v")
done <"$SCRIPT_DIR/.env"
status=$(_env_write_kv "$SCRIPT_DIR/.env" "${pairs[@]}")
sha_after=$(sha256sum "$SCRIPT_DIR/.env" | cut -d' ' -f1)

# Then the writer reports unchanged and the file is byte-identical
assert_eq "unchanged" "$status" "env parity: _env_write_kv finds nothing to change after the template"
assert_eq "$sha_template" "$sha_after" "env parity: .env sha unchanged by a no-op rewrite"

# And a bare template value is single-quoted exactly as the writer would write it
assert_contains "$(cat "$SCRIPT_DIR/.env")" "PUID='$(id -u)'" "env parity: bare template value is single-quoted"

# And the file still sources and keeps its values
sourced=$(
    set -a
    source "$SCRIPT_DIR/.env"
    echo "$PUID:$TZ"
)
assert_eq "$(id -u):Etc/UTC" "$sourced" "env parity: canonical .env still sources with the same values"

# --- E2: fallback reason persisted and shown -------------------------------
# Given a Secure Boot fallback
STAGE3_FALLBACK_REASON=secure_boot
# When the fallback state is persisted
stage3_set_gpu_env none fallback nvidia nvenc
# Then the reason lands in .env and the shared reason variable is reset
assert_contains "$(cat "$SCRIPT_DIR/.env")" "STAGE_3_GPU_FALLBACK_REASON='secure_boot'" "fallback: secure_boot reason persisted"
assert_eq "" "${STAGE3_FALLBACK_REASON:-}" "fallback: reason variable reset after the write"

# Given the persisted state
STAGE_3_GPU_STATE=fallback
STAGE_3_GPU_FALLBACK_REASON=secure_boot
# When the health line runs
out=$(gpu_fallback_health)
# Then it warns and names the remedy and the menu path
assert_eq "warn" "${out%%|*}" "fallback: health line warns on secure_boot"
assert_contains "$out" "disable Secure Boot" "fallback: health line names the Secure Boot remedy"
assert_contains "$out" "./mediastack -> Manage hardware transcoding" "fallback: health line names the menu path"

# When a user skips
STAGE3_FALLBACK_REASON=user_choice
stage3_set_gpu_env none skipped "" ""
STAGE_3_GPU_STATE=skipped
STAGE_3_GPU_FALLBACK_REASON=user_choice
# Then the health line is ok, and a later completed setup clears the reason
assert_eq "ok" "$(gpu_fallback_health | cut -d'|' -f1)" "fallback: user_choice is ok"
stage3_set_gpu_env intel complete intel qsv
assert_contains "$(cat "$SCRIPT_DIR/.env")" "STAGE_3_GPU_FALLBACK_REASON=''" "fallback: completed setup clears the reason"

# Given the hardware status view
source "$REPO_ROOT/scripts/lib/ui.sh" 2>/dev/null
ui_kv() { printf '%s=%s\n' "$1" "$2"; }
ui_box() {
    shift
    printf '%s\n' "$@"
}
source "$REPO_ROOT/scripts/launcher/hardware.sh"
JELLYFIN_GPU=none
STAGE_3_GPU_STATE=fallback
STAGE_3_GPU_FALLBACK_REASON=secure_boot
# When it renders
view=$(_hw_transcoding_info)
# Then it shows the reason and the fix
assert_contains "$view" "Reason=Secure Boot blocks the NVIDIA driver" "fallback: status view shows the reason"
assert_contains "$view" "Fix=disable Secure Boot" "fallback: status view shows the Secure Boot fix"

# Given a transcoding run that found no supported GPU
# When its outcome is recorded and rendered by the launcher
# Then it completes normally without the GPU-inactive warning
no_gpu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  result=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$result"
  STAGE_3_GPU_STATE=fallback STAGE_3_GPU_FALLBACK_REASON=no_gpu record_transcoding_outcome
  token=$(<"$result"); printf "token=%s\\n" "$token"
  ui_log(){ printf "%s|%s\\n" "$1" "$2"; }
  _show_action_result 0 "Hardware transcoding" "$token" 0
  unlink "$result"
' 2>&1)
assert_contains "$no_gpu_out" "token=completed" "transcoding: no_gpu records completed"
assert_not_contains "$no_gpu_out" "the GPU is not active" "transcoding: no_gpu does not warn that the GPU is inactive"

# Given a transcoding run the user chose to skip
# When its outcome is recorded and rendered by the launcher
# Then it completes normally without the GPU-inactive warning
user_choice_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  result=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$result"
  STAGE_3_GPU_STATE=fallback STAGE_3_GPU_FALLBACK_REASON=user_choice record_transcoding_outcome
  token=$(<"$result"); printf "token=%s\\n" "$token"
  ui_log(){ printf "%s|%s\\n" "$1" "$2"; }
  _show_action_result 0 "Hardware transcoding" "$token" 0
  unlink "$result"
' 2>&1)
assert_contains "$user_choice_out" "token=completed" "transcoding: user_choice records completed"
assert_not_contains "$user_choice_out" "the GPU is not active" "transcoding: user_choice does not warn that the GPU is inactive"

# Given a transcoding fallback without a recorded reason
# When its outcome is recorded
# Then it completes normally
empty_reason_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  result=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$result"
  STAGE_3_GPU_STATE=fallback STAGE_3_GPU_FALLBACK_REASON= record_transcoding_outcome
  cat "$result"
  unlink "$result"
' 2>&1)
assert_eq "completed" "$empty_reason_out" "transcoding: empty fallback reason records completed"

# Given a transcoding run whose hardware verification failed
# When its outcome is recorded and rendered by the launcher
# Then it keeps the software-fallback warning
verify_failed_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/checks.sh"
  result=$(mktemp); export MEDIASTACK_LAUNCHER_RESULT="$result"
  STAGE_3_GPU_STATE=fallback STAGE_3_GPU_FALLBACK_REASON=verify_failed record_transcoding_outcome
  token=$(<"$result"); printf "token=%s\\n" "$token"
  ui_log(){ printf "%s|%s\\n" "$1" "$2"; }
  _show_action_result 0 "Hardware transcoding" "$token" 0
  unlink "$result"
' 2>&1)
assert_contains "$verify_failed_out" "token=software-fallback:verify_failed" "transcoding: verify_failed keeps its software-fallback token"
assert_contains "$verify_failed_out" "the GPU is not active" "transcoding: verify_failed still warns that the GPU is inactive"

# --- E3: user-facing text uses the menu, except Jellyfin recovery ----------
# Given every log/ui/echo/printf string in the shell sources
# When it is scanned for advice naming setup.sh, configure.sh or update.sh
hits=$(cd "$REPO_ROOT" && grep -rnE '(log_[a-z]+|ui_[a-z]+|echo|printf)\b.*(setup|configure|update)\.sh' scripts setup.sh mediastack --include='*.sh' --include=mediastack \
    | grep -vE '^[^:]+:[0-9]+:\s*#' \
    | grep -vE 'dry-run\.sh:.*_dry_run_would' || true)
allowed_recovery='^scripts/services/jellyfin/main\.sh:[0-9]+:[[:space:]]*log_error "  \./scripts/configure\.sh --only jellyfin"$'
# Drift and completed-install notices name configure.sh as the reapply step: no
# menu item reapplies config.yml (#105).
allowed_reapply='^scripts/(configure|lib/arr/(storage|quality|formats)|services/jellyfin/wizard|setup/stages/stage1|lib/ui-demo)\.sh:[0-9]+:.*\./scripts/configure\.sh( --only [a-z]+)?'
recovery_hits=$(grep -E "$allowed_recovery" <<<"$hits" || true)
other_hits=$(grep -vE "$allowed_recovery|$allowed_reapply" <<<"$hits" || true)
# Then exactly the approved standalone Jellyfin recovery commands are found.
assert_eq "2" "$(grep -c . <<<"$recovery_hits")" "messages: both approved Jellyfin recovery commands are present"
assert_eq "" "$other_hits" "messages: only exact Jellyfin recovery commands advise a script"

# Given the Secure Boot remedy
remedy=$(gpu_fallback_secure_boot_lines)
# Then it gives both fixes, the mokutil steps and the menu path
assert_contains "$remedy" "Disable Secure Boot" "secure boot: firmware remedy"
assert_contains "$remedy" "mokutil --import" "secure boot: MOK remedy steps"
assert_contains "$remedy" "./mediastack -> Manage hardware transcoding (GPU)" "secure boot: menu path to retry"
assert_not_contains "$remedy" "setup.sh" "secure boot: no script advice"

# Given option (b) of the Secure Boot remedy
# Then the key is created at the path dkms signs with before it is imported, in order
assert_contains "$remedy" "apt-get -y install dkms mokutil openssl" "secure boot: installs the packages MediaStack has not installed yet"
key_line=$(grep -n "openssl req" <<<"$remedy" | head -1 | cut -d: -f1)
import_line=$(grep -n "mokutil --import /var/lib/dkms/mok.pub" <<<"$remedy" | head -1 | cut -d: -f1)
assert_contains "$remedy" "-keyout /var/lib/dkms/mok.key" "secure boot: private key path is the one dkms signs with"
assert_eq "1" "$([[ -n "$key_line" && -n "$import_line" && "$key_line" -lt "$import_line" ]] && echo 1 || echo 0)" "secure boot: key is created before it is imported"
assert_contains "$remedy" "Enroll MOK" "secure boot: reboot and enrol step"

# Given user-facing strings in Python sources under scripts/
# When scanned for advice naming setup.sh, configure.sh or update.sh
# (image_drift.py is a maintainer tool, run by developers on a checkout, not a user path)
pyhits=$(cd "$REPO_ROOT" && grep -rnE '(setup|configure|update)\.sh' scripts --include='*.py' \
    | grep -vE '^[^:]+:[0-9]+:\s*#' | grep -v '^scripts/image_drift\.py:' || true)
# Then nothing is found
assert_eq "" "$pyhits" "messages: no Python user-facing string advises setup.sh, configure.sh or update.sh"

scenario_end "$CURRENT_SCENARIO"
summary

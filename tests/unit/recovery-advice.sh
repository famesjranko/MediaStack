#!/usr/bin/env bash
# tests/unit/recovery-advice.sh
#
# Drift and completed-install messages must not send the user to
# `docker compose down -v`: service databases live in bind-mounted
# config/<service> directories, so that command keeps them, and the completion
# markers make the install route skip (issue #105). Each message must name a
# keep path and a reapply path that MediaStack supports.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="recovery-advice"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# Static guard: no runtime message under scripts/ recommends `down -v`.
# destroy.sh owns the typed-DESTROY teardown and its preview text. Lines that
# start with `docker` are commands MediaStack runs for its own cleanup, not
# advice. The image_drift.py hit is a docstring about the install digest
# record, not a message shown to the user.
# ---------------------------------------------------------------------------
# Given every launcher, setup and script source file except the teardown module.
# When the sources are searched for a compose `down -v` or `down --volumes`.
hits=$(
    cd "$REPO_ROOT" \
        && grep -rnE 'down +(-v|--volumes)' mediastack setup.sh scripts --include='*.sh' --include='*.py' --include=mediastack \
        | grep -v '^scripts/setup/checks/destroy\.sh:' \
            | grep -v '^scripts/image_drift\.py:.*re-baselines' \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|docker )'
)
# Then no message recommends it.
assert_eq "" "$hits" "no runtime message recommends compose down -v"

# ---------------------------------------------------------------------------
# Behaviour: each drift message names keep and reapply paths.
# ---------------------------------------------------------------------------
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/lib/arr/main.sh"

DRIFT_MESSAGES=()
WARN_MESSAGES=()
log_ok() { :; }
log_skip() { :; }
log_drift() { DRIFT_MESSAGES+=("$1"); }
log_warn() { WARN_MESSAGES+=("$1"); }

CFG_PROFILE_NAME="1080p Balanced"
cfg_field() {
    case "$1" in
        sonarr.root_folder) printf '%s\n' "/data/media/tv-new" ;;
        sonarr.download_client_category) printf '%s\n' "tv-new" ;;
        quality_profile.name) printf '%s\n' "$CFG_PROFILE_NAME" ;;
        quality_profile.cutoff_id) printf '%s\n' "2" ;;
        quality_profile.upgrade_allowed) printf '%s\n' "true" ;;
        *) return 1 ;;
    esac
}
cfg_custom_format_scores() { printf '%s\n' '{"HD Bluray Tier 01": 100}'; }

LIVE_ROOT='[{"path":"/data/media/tv"}]'
LIVE_DOWNLOAD='[{"name":"qBittorrent","fields":[{"name":"tvCategory","value":"tv-live"}]}]'
LIVE_PROFILES='[{"id":1,"name":"1080p Balanced","cutoff":1,"upgradeAllowed":true,"items":[],"formatItems":[{"format":7,"name":"HD Bluray Tier 01","score":5}]}]'
LIVE_FORMATS='[{"id":7,"name":"HD Bluray Tier 01"}]'
api_get() {
    case "$1" in
        */rootfolder) printf '%s\n' "$LIVE_ROOT" ;;
        */downloadclient) printf '%s\n' "$LIVE_DOWNLOAD" ;;
        */qualityprofile) printf '%s\n' "$LIVE_PROFILES" ;;
        */customformat) printf '%s\n' "$LIVE_FORMATS" ;;
        *) return 1 ;;
    esac
}

# assert_advice <messages> <label> <needle>... - the message names each needle
# and does not recommend the volume-removal command. A finished install must
# not be sent to the Install route either, unless INSTALL_OK=1 (the Stage 1
# skip legitimately names Install as the step after Uninstall).
assert_advice() {
    local msg="$1" label="$2" needle
    shift 2
    for needle in "$@"; do
        assert_contains "$msg" "$needle" "$label: names '$needle'"
    done
    assert_not_contains "$msg" "down -v" "$label: does not recommend down -v"
    if [[ "${INSTALL_OK:-0}" != 1 ]]; then
        assert_not_contains "$msg" "Install MediaStack" "$label: does not send a finished install to Install"
    fi
}

# Given a root folder that differs from config.yml.
# When Sonarr is configured.
configure_arr_root_folder sonarr http://sonarr/api/v3 key
# Then the notice offers keeping the live path and reapplying config.yml.
assert_advice "${DRIFT_MESSAGES[*]}" "root folder drift" \
    "sonarr.root_folder in config.yml" "./scripts/configure.sh --only sonarr"

# Given a qBittorrent category that differs from config.yml.
DRIFT_MESSAGES=()
# When Sonarr's download client is configured.
configure_arr_download_client sonarr http://sonarr/api/v3 key tvCategory
# Then the notice offers keeping the live category and reapplying config.yml.
assert_advice "${DRIFT_MESSAGES[*]}" "download category drift" \
    "sonarr.download_client_category in config.yml" "Download Clients"

# Given a quality profile whose cutoff differs from config.yml.
DRIFT_MESSAGES=()
# When the quality profile is configured.
configure_quality_profile sonarr http://sonarr/api/v3 key '[1]'
# Then the notice offers keeping it and reapplying config.yml.
assert_advice "${DRIFT_MESSAGES[*]}" "quality profile drift" \
    "do nothing" "./scripts/configure.sh --only sonarr"

# Given a profile renamed in the app, so the rename source no longer exists.
WARN_MESSAGES=()
CFG_PROFILE_NAME="New name"
# When Change quality profile re-pushes the new name.
QP_RENAME_FROM="Old name" configure_quality_profile sonarr http://sonarr/api/v3 key '[1]'
CFG_PROFILE_NAME="1080p Balanced"
# Then the warning offers renaming back or keeping the new name.
assert_advice "${WARN_MESSAGES[*]}" "quality profile rename" \
    "rename it back to 'Old name'" "quality_profile.name in config.yml"

# Given custom-format scores that differ from config.yml.
DRIFT_MESSAGES=()
# When format scores are configured.
configure_arr_format_scores sonarr http://sonarr/api/v3 key
# Then the notice offers keeping them and reapplying config.yml.
assert_advice "${DRIFT_MESSAGES[*]}" "format score drift" \
    "do nothing" "to 0" "./scripts/configure.sh --only sonarr"

# ---------------------------------------------------------------------------
# Completed install: the Stage 1 skip names configure.sh and the Uninstall
# route, and says what Uninstall removes.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/env-gen.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"
set +e
set +u

SKIP_CAPTURE=""
log_skip() { SKIP_CAPTURE+="$*"$'\n'; }
seed_root_config() { :; }
# Given a finished Stage 1.
STAGE_1_COMPLETE=1
# When the installer runs Stage 1 again.
run_stage1
# Then it names the supported reapply and reset routes.
INSTALL_OK=1 assert_advice "$SKIP_CAPTURE" "stage 1 skip" \
    "./scripts/configure.sh" "Uninstall MediaStack" "config/" "watch history"

scenario_end "$CURRENT_SCENARIO"
summary

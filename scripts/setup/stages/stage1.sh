# Owns: run_* — Stage 1 flow ordering and completion-marker skip routing.
# Sources: stage1/* concern modules, wizard helpers, and setup globals.
# =============================================================================
# MediaStack Setup — Stage 1 controller (Core LAN)
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

_STAGE1_CONCERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stage1" && pwd)"
# shellcheck source=../stage1/system.sh
source "$_STAGE1_CONCERNS_DIR/system.sh"
# shellcheck source=../stage1/admin.sh
source "$_STAGE1_CONCERNS_DIR/admin.sh"
# shellcheck source=../stage1/storage.sh
source "$_STAGE1_CONCERNS_DIR/storage.sh"
# shellcheck source=../stage1/nas.sh
source "$_STAGE1_CONCERNS_DIR/nas.sh"
# shellcheck source=../stage1/subtitles.sh
source "$_STAGE1_CONCERNS_DIR/subtitles.sh"
# shellcheck source=../stage1/smb.sh
source "$_STAGE1_CONCERNS_DIR/smb.sh"
# shellcheck source=../stage1/quality.sh
source "$_STAGE1_CONCERNS_DIR/quality.sh"
# shellcheck source=../stage1/indexers.sh
source "$_STAGE1_CONCERNS_DIR/indexers.sh"
# shellcheck source=../stage1/image-channel.sh
source "$_STAGE1_CONCERNS_DIR/image-channel.sh"
# shellcheck source=../stage1/qbit.sh
source "$_STAGE1_CONCERNS_DIR/qbit.sh"
# shellcheck source=../stage1/security.sh
source "$_STAGE1_CONCERNS_DIR/security.sh"
# shellcheck source=../stage1/confirm.sh
source "$_STAGE1_CONCERNS_DIR/confirm.sh"
# shellcheck source=../stage1/install.sh
source "$_STAGE1_CONCERNS_DIR/install.sh"
# shellcheck source=../stage1/demo.sh
source "$_STAGE1_CONCERNS_DIR/demo.sh"
unset _STAGE1_CONCERNS_DIR

run_stage1() {
    seed_root_config # ensure live config.yml exists before the wizard mutates it (env-gen.sh)
    # Sentinel convention: STAGE_1_COMPLETE is unset OR empty when Stage 1
    # has not yet completed; literal "1" means complete. env-gen.sh writes
    # the empty value (see 'STAGE_1_COMPLETE=${prev_stage1}' where
    # prev_stage1 defaults to ""), and setup.sh uses '${STAGE_1_COMPLETE:-}'
    # to match. Do NOT change this to ':-0' — the sentinel is empty, not 0,
    # and a non-empty default would change predicate semantics if env_gen
    # ever wrote an explicit "0".
    if [[ "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        log_skip "Stage 1 already complete - rerun setup to add remote access or hardware transcoding when needed"
        log_skip "To rebuild from scratch: docker compose down -v && ./setup.sh --full"
        # Mark the install path as complete so setup.sh::main() does not fall
        # through to stop_existing_stack / pull_images / configure.sh on a
        # benign re-run. Honors the graceful re-run invariant —
        # without this flag, every './setup.sh' after Stage 1 was complete
        # would tear down the running stack and re-pull images.
        # shellcheck disable=SC2034 # setup.sh::main consumes this global
        WIZARD_RAN_INSTALL=true
        return 0
    fi

    ui_banner "MediaStack - Core Media Server" "Working media server in 5-7 minutes"

    _wizard_run_discovery
    stage1_show_system

    while true; do
        _stage1_collect_admin
        _stage1_collect_storage
        _stage1_collect_subtitles
        _stage1_collect_smb
        _stage1_collect_quality
        _stage1_collect_indexers
        _stage1_collect_image_channel
        _stage1_collect_qbit
        _stage1_collect_security

        local action
        _stage1_confirm
        action="${_STAGE1_CONFIRM_ACTION:-Back}"
        case "$action" in
            Install) break ;;
            Back) continue ;;
            Abort)
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                exit 0
                ;;
        esac
    done

    _stage1_install
}

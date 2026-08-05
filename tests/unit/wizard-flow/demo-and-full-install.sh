#!/usr/bin/env bash
# tests/unit/wizard-flow/demo-and-full-install.sh
#
# The non-interactive DEMO=1 env var path, the SMB share-scope prompt inside
# _stage1_collect_smb, and the --full installer routing through Docker/GPU
# detection and Stage-owned host integration.

# =========================================================================
# Test 7: Full wizard in DEMO=1 mode
# =========================================================================
TMP_DIR_DEMO=$(mktemp -d)
TMP_DIR_DEMO_DEFAULT=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_DEMO" "$TMP_DIR_DEMO_DEFAULT"' EXIT

cp "$REPO_ROOT/config/examples/config.yml" "$TMP_DIR_DEMO/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_DEMO/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_DEMO/scripts"
mkdir -p "$TMP_DIR_DEMO/config/ddns-updater"
reset_fixture_config "$TMP_DIR_DEMO/config.yml"

SCRIPT_DIR="$TMP_DIR_DEMO"
unset UI_DEMO
export DEMO=1
GPU_TYPE="none"
RUN_STAGE2_COUNT=0
RUN_STAGE3_COUNT=0

detect_env

cat >"$TMP_DIR_DEMO/.env" <<'PRESEEDED'
DOMAIN=demo.example.test
NPM_ADMIN_EMAIL=owner@demo.test
JELLYFIN_ADMIN_PASSWORD='changeme'
BAZARR_ENABLED=true
SMB_ENABLED=true
SMB_SHARE_SCOPE=system
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
TORRENT_PORT=6999
IMAGE_CHANNEL=latest
WG_PORT=51999
PRESEEDED

run_wizard >/dev/null 2>&1
demo_wizard_rc=$?

assert_eq "0" "$demo_wizard_rc" "DEMO=1: run_wizard exits 0"
assert_eq "0" "$RUN_STAGE2_COUNT" "DEMO=1: Stage 2 is not called"
assert_eq "0" "$RUN_STAGE3_COUNT" "DEMO=1: hardware transcoding add-on is not called"
assert_eq "owner@demo.test" "$(env_val_from "$TMP_DIR_DEMO/.env" NPM_ADMIN_EMAIL)" "DEMO=1: pre-seeded email preserved"
assert_eq "example.com" "$(env_val_from "$TMP_DIR_DEMO/.env" DOMAIN)" "DEMO=1: Stage 1 stays LAN-only"
assert_eq "6999" "$(env_val_from "$TMP_DIR_DEMO/.env" TORRENT_PORT)" "DEMO=1: pre-seeded torrent port preserved"
assert_eq "latest" "$(env_val_from "$TMP_DIR_DEMO/.env" IMAGE_CHANNEL)" "DEMO=1: pre-seeded image channel preserved"
assert_eq "51820" "$(env_val_from "$TMP_DIR_DEMO/.env" WG_PORT)" "DEMO=1: Stage 1 keeps default WireGuard port"
assert_eq "true" "$(env_val_from "$TMP_DIR_DEMO/.env" BAZARR_ENABLED)" "DEMO=1: pre-seeded Bazarr enabled preserved"
assert_eq "true" "$(env_val_from "$TMP_DIR_DEMO/.env" SMB_ENABLED)" "DEMO=1: pre-seeded SMB enabled preserved"
assert_eq "system" "$(env_val_from "$TMP_DIR_DEMO/.env" SMB_SHARE_SCOPE)" "DEMO=1: pre-seeded SMB scope preserved"
assert_eq "" "$(env_val_from "$TMP_DIR_DEMO/.env" WG_INIT_PASSWORD)" "DEMO=1: Stage 1 leaves WireGuard init password empty"
assert_eq "1080p Balanced" "$(python3 -c "
import yaml
with open('$TMP_DIR_DEMO/config.yml') as f:
    c = yaml.safe_load(f)
print(c['quality_profile']['name'])
")" "DEMO=1: 1080p Balanced applied"

demo_pw=$(env_val_from "$TMP_DIR_DEMO/.env" JELLYFIN_ADMIN_PASSWORD)
if [[ "$demo_pw" == "GeneratedDemoPassword123" ]]; then
    pass "DEMO=1: weak pre-seeded password replaced"
else
    fail "DEMO=1: weak pre-seeded password replaced" "got '$demo_pw'"
fi

cp "$REPO_ROOT/config/examples/config.yml" "$TMP_DIR_DEMO_DEFAULT/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_DEMO_DEFAULT/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_DEMO_DEFAULT/scripts"
mkdir -p "$TMP_DIR_DEMO_DEFAULT/config/ddns-updater"
reset_fixture_config "$TMP_DIR_DEMO_DEFAULT/config.yml"

SCRIPT_DIR="$TMP_DIR_DEMO_DEFAULT"
GPU_TYPE="none"
RUN_STAGE2_COUNT=0
RUN_STAGE3_COUNT=0
detect_env

run_wizard >/dev/null 2>&1
demo_default_rc=$?

assert_eq "0" "$demo_default_rc" "DEMO=1: no-preseed run_wizard exits 0"
assert_eq "admin@mediastack.local" "$(env_val_from "$TMP_DIR_DEMO_DEFAULT/.env" NPM_ADMIN_EMAIL)" "DEMO=1: no-preseed email defaults for Beszel"
assert_eq "stable" "$(env_val_from "$TMP_DIR_DEMO_DEFAULT/.env" IMAGE_CHANNEL)" "DEMO=1: no-preseed image channel defaults stable"

unset DEMO

# =========================================================================
# Test 8: SMB enabled path prompts for explicit share scope
# =========================================================================
_orig_ui_section=$(declare -f ui_section)
_orig_ui_input_validated=$(declare -f ui_input_validated)
_orig_ui_confirm=$(declare -f ui_confirm)
_orig_ui_choose=$(declare -f ui_choose)
_orig_validate_smb_port=$(declare -f validate_smb_port)

SMB_CONFIRM_COUNT=0
SMB_SCOPE_PROMPT=""
SMB_SCOPE_PROMPT_FILE="$TMP_DIR/smb-scope-prompt"
ui_section() { :; }
ui_input_validated() {
    case "${1:-}" in
        "Data directory") echo "/srv/media" ;;
        *) echo "${2:-}" ;;
    esac
}
ui_confirm() {
    # The SMB section's only confirm is "Enable SMB file share...": say yes.
    SMB_CONFIRM_COUNT=$((SMB_CONFIRM_COUNT + 1))
    return 0
}
validate_smb_port() { return 0; }
ui_choose() {
    # The end-of-section review ("Use these …?") must be accepted or the storage
    # wrapper loops forever; everything else keeps the original scope-capture behaviour.
    case "${1:-}" in
        "Use these"*) echo "Use these details" ;;
        *)
            printf '%s\n' "${1:-}" >"$SMB_SCOPE_PROMPT_FILE"
            echo "Full system (/) - advanced admin access to the whole server."
            ;;
    esac
}

_WIZ_DATA_DIR=""
_WIZ_BAZARR_ENABLED=""
_WIZ_SMB_ENABLED=""
_WIZ_SMB_SHARE_SCOPE=""
# SMB now lives in its own section (_stage1_collect_smb), split out of storage.
_stage1_collect_smb >/dev/null 2>&1
SMB_SCOPE_PROMPT=$(cat "$SMB_SCOPE_PROMPT_FILE" 2>/dev/null)

assert_eq "true" "$_WIZ_SMB_ENABLED" "SMB prompt: enabling SMB is preserved"
assert_eq "Choose SMB share scope:" "$SMB_SCOPE_PROMPT" "SMB prompt: asks for explicit scope after enable"
assert_eq "system" "$_WIZ_SMB_SHARE_SCOPE" "SMB prompt: full-system choice maps to system scope"

eval "$_orig_ui_section"
eval "$_orig_ui_input_validated"
eval "$_orig_ui_confirm"
eval "$_orig_ui_choose"
eval "$_orig_validate_smb_port"

# =========================================================================
# Test 9: --full reaches Docker installation before Docker checks enforce
# =========================================================================
TMP_DIR_FULL=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_DEMO" "$TMP_DIR_FULL"' EXIT

cp "$REPO_ROOT/config/examples/config.yml" "$TMP_DIR_FULL/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_FULL/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_FULL/scripts"
mkdir -p "$TMP_DIR_FULL/config/ddns-updater"
cat >"$TMP_DIR_FULL/scripts/configure.sh" <<'FULLCONFIG'
#!/usr/bin/env bash
exit 0
FULLCONFIG
chmod +x "$TMP_DIR_FULL/scripts/configure.sh"

source "$REPO_ROOT/setup.sh"
set +e
set +u

SCRIPT_DIR="$TMP_DIR_FULL"
FULL_ORDER=()
FULL_DOCKER_INSTALLED=false
FULL_STASH_COUNT=0
FULL_WIZARD_GPU_TYPE=""

record_full_order() {
    FULL_ORDER+=("$1")
}

check_not_root() { record_full_order check_not_root; }
check_debian() { record_full_order check_debian; }
check_disk_floor() { record_full_order check_disk_floor; }
check_internet_reachability() { record_full_order check_internet_reachability; }
check_ram_warn() { record_full_order check_ram_warn; }
prompt_sudo_cache() { record_full_order prompt_sudo_cache; }
stash_gpu_type() {
    record_full_order stash_gpu_type
    FULL_STASH_COUNT=$((FULL_STASH_COUNT + 1))
    if ((FULL_STASH_COUNT == 1)); then
        GPU_TYPE=none
    else
        GPU_TYPE=nvidia
    fi
}
detect_existing_install() { record_full_order detect_existing_install; }
install_base_packages() { record_full_order install_base_packages; }
install_docker() {
    record_full_order install_docker
    FULL_DOCKER_INSTALLED=true
}
check_docker() {
    record_full_order check_docker
    $FULL_DOCKER_INSTALLED
}
check_compose() {
    record_full_order check_compose
    $FULL_DOCKER_INSTALLED
}
detect_gpu() {
    record_full_order detect_gpu
    GPU_TYPE=none
}
install_nvidia_drivers() { record_full_order install_nvidia_drivers; }
install_amd_drivers() { record_full_order install_amd_drivers; }
install_intel_drivers() { record_full_order install_intel_drivers; }
cleanup_post_reboot() { record_full_order cleanup_post_reboot; }
verify_gpu_usable() { record_full_order verify_gpu_usable; }
apply_nvidia_patch() { record_full_order apply_nvidia_patch; }
detect_host_memory() { record_full_order detect_host_memory; }
setup_hardening() { record_full_order setup_hardening; }
detect_env() {
    record_full_order detect_env
    _ENV_TZ=Etc/UTC
    _ENV_PUID=1000
    _ENV_PGID=1000
    _ENV_HOST_ADDRESS=127.0.0.1
}
run_wizard() {
    record_full_order run_wizard
    FULL_WIZARD_GPU_TYPE="$GPU_TYPE"
    WIZARD_RAN_INSTALL=true
    cat >"$SCRIPT_DIR/.env" <<'FULLENV'
TZ=Etc/UTC
PUID=1000
PGID=1000
DATA_DIR=/tmp/ms-data
HOST_ADDRESS=127.0.0.1
JELLYFIN_ADMIN_USER='admin'
JELLYFIN_ADMIN_PASSWORD='GeneratedDemoPassword123'
NPM_ADMIN_EMAIL=
JELLYFIN_GPU=none
DOMAIN=example.com
REMOTE_WEB_STATE=skipped
WG_HOST=example.com
WG_PORT=51820
WG_INIT_PASSWORD=''
WG_DEFAULT_DNS=1.1.1.1
WG_ACCESS_TIER=full-lan
WG_LAN_CIDR=192.168.1.0/24
WG_SERVER_LAN_IP=127.0.0.1
WG_INIT_ALLOWED_IPS='192.168.1.0/24'
WG_PER_CLIENT_FIREWALL=true
TORRENT_PORT=6881
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
BAZARR_ENABLED=false
SMB_ENABLED=false
STAGE_1_COMPLETE=1
FULLENV
}
setup_ufw_service_ports() { record_full_order setup_ufw_service_ports; }
setup_samba() { record_full_order setup_samba; }
stop_existing_stack() { record_full_order stop_existing_stack; }
create_data_dirs() { record_full_order create_data_dirs; }
create_config_dirs() { record_full_order create_config_dirs; }
generate_override() { record_full_order generate_override; }
pull_images() { record_full_order pull_images; }
start_stack() { record_full_order start_stack; }
wait_all_healthy() { record_full_order wait_all_healthy; }
print_access_info() { record_full_order print_access_info; }
setup_hardening() { record_full_order setup_hardening; }

python3() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "import yaml" ]]; then
        return 0
    fi
    command python3 "$@"
}

sudo() {
    record_full_order sudo
    return 0
}

main --full >/dev/null 2>&1
full_rc=$?
full_order_text="${FULL_ORDER[*]}"

assert_eq "0" "$full_rc" "--full: main exits 0 with side effects stubbed"
assert_contains "$full_order_text" "install_docker check_docker check_compose" "--full: Docker checks run after install_docker"
assert_contains "$full_order_text" "install_base_packages check_internet_reachability install_docker check_docker check_compose stash_gpu_type" "--full: reachability is rechecked after base packages install, before Docker install"
full_internet_count=0
for token in "${FULL_ORDER[@]}"; do
    [[ "$token" == "check_internet_reachability" ]] && full_internet_count=$((full_internet_count + 1))
done
assert_eq "2" "$full_internet_count" "--full: internet reachability runs before and after base package install"
assert_eq "2" "$FULL_STASH_COUNT" "--full: GPU detection runs before and after base package install"
assert_eq "nvidia" "$FULL_WIZARD_GPU_TYPE" "--full: hardware transcoding receives post-pciutils GPU detection"
if [[ "$full_order_text" == *"check_docker"*"install_docker"* ]]; then
    fail "--full: check_docker does not run before install_docker" "order: $full_order_text"
else
    pass "--full: check_docker does not run before install_docker"
fi
# Host integration (UFW service ports + SMB share) moved into Stage 1
# (_stage1_install, before print_access_info) so the SMB share the user picks in
# the wizard is configured with the rest of Stage 1, not tacked on after the
# final summary. main() no longer calls them after run_wizard; the stubbed
# run_wizard here does not reach _stage1_install, so they must be absent from
# main's post-wizard order.
if [[ "$full_order_text" == *"setup_samba"* || "$full_order_text" == *"setup_ufw_service_ports"* ]]; then
    fail "main: host integration moved into Stage 1 (not called by main after run_wizard)" "order: $full_order_text"
else
    pass "main: host integration moved into Stage 1 (not called by main after run_wizard)"
fi
# ...and confirm Stage 1 actually owns it, ordered before the access summary.
stage1_install_src="$(cat "$REPO_ROOT/scripts/setup/stage1/install.sh")"
if [[ "$stage1_install_src" == *"setup_ufw_service_ports"*"setup_samba"*"print_access_info"* ]]; then
    pass "stage1 install: host integration runs before print_access_info"
else
    fail "stage1 install: host integration must run before print_access_info" "stage1/install.sh order mismatch"
fi
if [[ "$full_order_text" == *"run_wizard"*"stop_existing_stack"* || "$full_order_text" == *"run_wizard"*"pull_images"* || "$full_order_text" == *"run_wizard"*"start_stack"* ]]; then
    fail "main: legacy stack install is skipped after stage install" "order: $full_order_text"
else
    pass "main: legacy stack install is skipped after stage install"
fi


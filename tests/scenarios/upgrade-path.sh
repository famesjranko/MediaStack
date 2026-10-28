# Accepted-image installation -> candidate combination, using real update paths.
# Fresh configuration evidence is reported by fresh-install separately.
source tests/scenarios/fresh-install.sh

upgrade_state() { dind_exec "python3 -I tests/fixtures/upgrade_state.py $1"; }

# Invoke the production update/revert functions. Only menu input is supplied by
# the fixture; Docker, snapshots, policy writes and authentication stay real.
upgrade_launcher() {
    docker exec -i -e "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-}" -w /root/MediaStack "$DIND_NAME" bash -s -- "$1" <<'BASH'
set -euo pipefail
SCRIPT_DIR=/root/MediaStack
CONFIG_FILE=$SCRIPT_DIR/config.yml
set -a
source .env
set +a
source scripts/lib/common.sh
source scripts/lib/ui.sh
source scripts/lib/profiles.sh
source scripts/setup/storage.sh
source scripts/setup/override.sh
source scripts/launcher/manage-updates.sh
_MU_APPLIED=()
case "$1" in
    update) _apply_service_update qbittorrent 1 ;;
    revert) _reset_service_to_default qbittorrent ;;
esac
BASH
}

run_scenario() {
    if [[ -n "${MS_TEST_STRIP_SERVICES:-}" ]]; then
        fail 'upgrade-path requires the complete default stack'
        return 1
    fi
    local baseline_only=0
    local MS_TEST_IMAGE_OVERRIDES="${MS_TEST_IMAGE_OVERRIDES:-}"
    if [[ -z "$MS_TEST_IMAGE_OVERRIDES" ]]; then
        # The ordinary battery has no candidate. Pin its Update/Revert target
        # to the accepted qBittorrent image so the test never floats upstream.
        # The recorder initialized without overrides, so this earns no receipt.
        baseline_only=1
        MS_TEST_IMAGE_OVERRIDES=$(awk -F '\t' '$1 == "qbittorrent" { print $1 "=" $2 "@" $3 }' "$REPO_ROOT/docs/operations/image-digests.lock")
        [[ -n "$MS_TEST_IMAGE_OVERRIDES" ]] && dind_override_images || return 1
        pass 'upgrade-path baseline only: accepted-image management, no candidate evidence'
    fi
    # Overrides already patched the DinD lock. Keep it as the target, then boot
    # the accepted lock from the host source checkout on the Stable channel.
    dind_exec 'cp docs/operations/image-digests.lock /tmp/upgrade-target.lock' || return 1
    dind_write_file docs/operations/image-digests.lock <"$REPO_ROOT/docs/operations/image-digests.lock" || return 1
    if ((baseline_only == 0)) && dind_exec 'cmp -s docs/operations/image-digests.lock /tmp/upgrade-target.lock'; then
        fail 'upgrade-path requires a changed candidate digest'
        return 1
    fi
    local baseline_fails=$FAIL_COUNT
    fresh_install_run || return 1
    ((FAIL_COUNT == baseline_fails)) || return 1
    # DinD has no systemd host. Host firewall convergence has its own proofs;
    # explicitly disable that optional host feature in this service fixture.
    env_set ADMIN_PORT_FILTER false
    env_set HARDENING_ENABLED false
    env_set UFW_ENABLED false
    upgrade_state seed && upgrade_state save || {
        fail 'upgrade-path seeds and records real user settings'
        return 1
    }
    pass 'upgrade-path records configured accepted images and deliberate user changes'

    # Prove that the state comparison detects an overwrite before trusting it
    # as a migration oracle. Restore the user choice before the upgrade.
    upgrade_state flip || return 1
    if upgrade_state check >/dev/null 2>&1; then
        fail 'upgrade-path detects overwritten user settings'
    else
        pass 'upgrade-path detects overwritten user settings'
    fi
    upgrade_state flip && upgrade_state check || return 1

    dind_exec 'cp /tmp/upgrade-target.lock docs/operations/image-digests.lock' || return 1
    local log=/tmp/ms-upgrade-update.log
    # The launcher takes a stopped-config restore point and performs a real
    # recreation. Revert must restore the accepted image and usable login.
    if upgrade_launcher update >"$log" 2>&1 && wait_healthy qbittorrent 120; then
        pass 'upgrade-path launcher Update saves a restore point and recreates qBittorrent'
    else
        fail 'upgrade-path launcher Update saves a restore point and recreates qBittorrent'
        tail -30 "$log"
        return 1
    fi
    if upgrade_launcher revert >"$log" 2>&1 && wait_healthy qbittorrent 120 && upgrade_state check; then
        pass 'upgrade-path launcher Revert restores the installed image, state, and login'
    else
        fail 'upgrade-path launcher Revert restores the installed image, state, and login'
        tail -30 "$log"
    fi
    # End on the proposed candidate combination for the event-based receipts.
    upgrade_launcher update >"$log" 2>&1 && wait_healthy qbittorrent 120 && upgrade_state check || {
        fail 'upgrade-path returns to the candidate after verified revert'
        return 1
    }
    pass 'upgrade-path returns to the candidate after verified revert'
    if dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/update.sh" >"$log" 2>&1; then
        pass 'upgrade-path real scripts/update.sh succeeds'
    else
        fail 'upgrade-path real scripts/update.sh succeeds'
        tail -30 "$log"
        return 1
    fi
    local svc
    for svc in jellyfin sonarr radarr jackett qbittorrent seerr; do
        if wait_healthy "$svc" 180; then
            pass "upgrade-path: $svc ready after accepted-to-candidate update"
        else
            fail "upgrade-path: $svc ready after accepted-to-candidate update"
        fi
    done
    local pair ref actual accepted
    for pair in $(echo "$MS_TEST_IMAGE_OVERRIDES" | tr ',' ' '); do
        svc=${pair%%=*}
        ref=${pair#*=}
        # These profiles are absent from fresh-install. Hosted plans still pin
        # their accepted companion refs, but neither can be tested here.
        if [[ "$svc" == bazarr || "$svc" == wireguard ]]; then
            accepted=$(awk -F '\t' -v svc="$svc" '$1 == svc { print $2 "@" $3 }' "$REPO_ROOT/docs/operations/image-digests.lock")
            if [[ "$ref" != "$accepted" ]]; then
                fail "upgrade-path: $svc candidate is outside active profiles"
            fi
            continue
        fi
        if actual=$(dind_exec "docker inspect --format '{{.Config.Image}}' $svc" 2>/dev/null); then
            assert_eq "$ref" "$actual" "upgrade-path: $svc actually runs the requested image"
        else
            fail "upgrade-path: $svc image inspection failed"
        fi
    done
    if upgrade_state check; then
        pass 'upgrade-path preserves users, settings, IDs, categories, and credentials'
    else
        fail 'upgrade-path preserves users, settings, IDs, categories, and credentials'
    fi
    if dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/configure.sh --only qbittorrent,jackett,sonarr,radarr,jellyfin,seerr" >"$log" 2>&1 \
        && upgrade_state check; then
        pass 'upgrade-path reconfiguration preserves intentional user changes'
    else
        fail 'upgrade-path reconfiguration preserves intentional user changes'
        tail -30 "$log"
    fi
    assert_qbittorrent_configured
    assert_jackett_configured
    assert_sonarr_configured "$log"
    assert_radarr_configured "$log"
    assert_seerr_configured "$(env_get JELLYFIN_ADMIN_PASSWORD)"

}

# tests/scenarios/install-e2e.sh — the real installer and the day-2 Manage
# updates menu on live images. Nothing in the product is stubbed: setup.sh
# installs Docker prerequisites, pulls, starts and configures the stack, and
# ./mediastack moves each data-owning service through Update and Revert under a
# pseudo-terminal. What this proves, and what stays out, is in
# docs/operations/image-compatibility.md.
#
# Image plan. Candidate digests arrive through MS_TEST_IMAGE_OVERRIDES, which
# patches the DinD compose file and Stable lock. The installer's own generated
# override then pulls them for every service except the six data owners below.
# Those install on the accepted lock row and reach their candidate through the
# menu's Update, because an existing install moves forward that way. The
# reverse (installing the candidate, then "updating" to the older accepted
# image) would start an older Jellyfin or Arr on a database that the newer
# version already migrated. Revert puts back the restore point that Update
# took, so the return trip is the supported downgrade.

source tests/scenarios/fresh-install.sh

IE2E_USER=mstest
IE2E_DATA_SERVICES=(jellyfin sonarr radarr jackett qbittorrent seerr)
IE2E_PASSWORD='Fr3sh!$tack"with\special#chars^&*'
IE2E_SETUP_LOG=/tmp/ie2e-setup.log
declare -A IE2E_INSTALLED=() IE2E_TARGET=() # data service -> image@digest

ie2e_user_exec() {
    docker exec -u "$IE2E_USER" -e "HOME=/home/$IE2E_USER" -e "USER=$IE2E_USER" -e UI_ASCII=1 \
        -w /root/MediaStack "$DIND_NAME" bash -c "$1"
}

# Saved user state through the real service APIs (seed, save, check).
ie2e_state() { dind_exec "python3 -I tests/fixtures/upgrade_state.py $1"; }

ie2e_accepted_ref() {
    awk -F '\t' -v s="$1" '$1 == s { print $2 "@" $3 }' "$REPO_ROOT/docs/operations/image-digests.lock"
}

ie2e_override_ref() {
    local pair
    for pair in $(echo "${MS_TEST_IMAGE_OVERRIDES:-}" | tr ',' ' '); do
        [[ "${pair%%=*}" == "$1" ]] && echo "${pair#*=}"
    done
}

ie2e_digest() { echo "${1##*@}"; }

# Decide the install image and the Update target of each data service, and
# write the install lock: candidate rows for every other service, accepted rows
# for the data services. A data service without a candidate gets its accepted
# image as the Update target, so Update never floats to an upstream tag.
ie2e_plan_images() {
    local svc acc ref extra=()
    for svc in "${IE2E_DATA_SERVICES[@]}"; do
        acc=$(ie2e_accepted_ref "$svc")
        ref=$(ie2e_override_ref "$svc")
        if [[ -z "$ref" ]]; then
            ref="$acc"
            extra+=("$svc=$acc")
        fi
        if [[ "$acc" != *@sha256:* || "$ref" != *@sha256:* ]]; then
            fail "install-e2e: $svc install and target images are digest refs" "accepted='$acc' target='$ref'"
            return 1
        fi
        IE2E_INSTALLED[$svc]="$acc"
        IE2E_TARGET[$svc]="$ref"
    done
    if ((${#extra[@]})); then
        MS_TEST_IMAGE_OVERRIDES="${extra[*]}" dind_override_images || return 1
    fi
    dind_write_file /tmp/ie2e-accepted.lock <"$REPO_ROOT/docs/operations/image-digests.lock" || return 1
    dind_python "${IE2E_DATA_SERVICES[@]}" <<'PY'
import pathlib
import sys

data = set(sys.argv[1:])
accepted = {}
for line in pathlib.Path("/tmp/ie2e-accepted.lock").read_text().splitlines():
    if line and not line.startswith("#"):
        accepted[line.split("\t")[0]] = line
lock = pathlib.Path("docs/operations/image-digests.lock")
rows = []
for line in lock.read_text().splitlines():
    service = line.split("\t")[0]
    rows.append(accepted[service] if service in data and not line.startswith("#") else line)
lock.write_text("\n".join(rows) + "\n")
PY
}

# Host and wizard answers for a non-interactive DEMO=1 install.
ie2e_prepare() {
    # setup.sh and ./mediastack refuse root. The fixtures below chown to 1000,
    # the PUID the installer derives from this user.
    dind_exec "id -u $IE2E_USER >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker $IE2E_USER" || return 1
    dind_exec "printf '%s ALL=(ALL) NOPASSWD:ALL\n' $IE2E_USER >/etc/sudoers.d/90-mediastack-e2e && chmod 440 /etc/sudoers.d/90-mediastack-e2e" || return 1
    [[ "$(dind_exec "id -u $IE2E_USER" | tr -d '\r\n')" == 1000 ]] || return 1
    dind_exec 'cp .env.example .env' || return 1
    # DEMO=1 takes every Stage 1 answer from an existing .env.
    env_set TZ Etc/UTC
    env_set DATA_DIR /tmp/ms-data
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD "$IE2E_PASSWORD"
    env_set NPM_ADMIN_EMAIL admin@e2e.test
    env_set IMAGE_CHANNEL stable
    # DinD has no systemd host: the admin-port filter is a systemd unit, and
    # UFW and kernel hardening change the host firewall and sysctl. They have
    # their own unit tests and the lan-host harness; turn off only those.
    env_set ADMIN_PORT_FILTER false
    env_set HARDENING_ENABLED false
    env_set UFW_ENABLED false
    # Deterministic indexer: the wizard's public-indexer preset is replaced by
    # the local Torznab fixture, so the installer writes it into config.yml and
    # configure.sh registers it in Jackett, Sonarr and Radarr.
    env_set PUBLIC_INDEXERS_ENABLED true
    dind_exec "printf 'indexers:\n  - id: mstest\n    type: general\n' >config/examples/public-indexers.yml" || return 1
    dind_exec 'mkdir -p config/jackett/cardigann/definitions && cp tests/fixtures/torznab/mstest.yml config/jackett/cardigann/definitions/mstest.yml' || return 1
    dind_exec "mkdir -p /tmp/ms-data && chmod 755 /root && chown -R $IE2E_USER: /root/MediaStack /tmp/ms-data" || return 1
    # The installer creates the stack network; the fixture site must be on it
    # before configure.sh enables the indexer. Its dynamic address (.2) is
    # outside the octets the stack pins.
    dind_pull_retry "$TORZNAB_FIXTURE_IMAGE" || return 1
    docker exec -d "$DIND_NAME" sh -c "timeout 3600 sh -c 'until docker network inspect mediastack >/dev/null 2>&1; do sleep 1; done' && docker run -d --name $TORZNAB_FIXTURE_NAME --network mediastack -v /root/MediaStack/tests/fixtures/torznab/server.py:/srv/server.py:ro $TORZNAB_FIXTURE_IMAGE python3 -I /srv/server.py"
}

# Default and autoheal profile services: what a LAN-only Stage 1 runs.
ie2e_expected_services() {
    dind_python <<'PY'
import yaml

with open("docker-compose.yml") as fh:
    services = yaml.safe_load(fh)["services"]
print(" ".join(s for s, d in services.items() if d.get("profiles") in (None, [], ["autoheal"])))
PY
}

ie2e_lock_ref() {
    dind_exec "awk -F '\t' -v s='$1' '\$1 == s { print \$2 \"@\" \$3 }' docs/operations/image-digests.lock" | tr -d '\r\n'
}

ie2e_image_of() { dind_exec "docker inspect --format '{{.Config.Image}}' $1 2>/dev/null" | tr -d '\r\n'; }

ie2e_runs_digest() { # <service> <sha256:...>: the container's image has that repo digest
    dind_exec "docker image inspect --format '{{json .RepoDigests}}' \$(docker inspect --format '{{.Image}}' $1)" | grep -q "@$2\""
}

ie2e_install() {
    echo "  running DEMO=1 ./setup.sh --full as $IE2E_USER (a cold pull can take 20+ min)…"
    if ie2e_user_exec 'DEMO=1 ./setup.sh --full </dev/null' >"$IE2E_SETUP_LOG" 2>&1; then
        pass "install-e2e: DEMO=1 ./setup.sh --full exits 0"
    else
        fail "install-e2e: DEMO=1 ./setup.sh --full exits 0"
        tail -60 "$IE2E_SETUP_LOG"
        return 1
    fi
    assert_eq 1 "$(env_get STAGE_1_COMPLETE)" "install-e2e: installer set STAGE_1_COMPLETE=1"
    assert_eq stable "$(env_get IMAGE_CHANNEL)" "install-e2e: install uses the Stable channel"
    assert_eq example.com "$(env_get DOMAIN)" "install-e2e: DEMO install stays LAN-only"
    local svc expected record
    expected=$(ie2e_expected_services) || return 1
    [[ -n "$expected" ]] || {
        fail "install-e2e: default-profile service list is readable"
        return 1
    }
    record=$(dind_exec 'cat config/state/image-install.tsv' 2>/dev/null)
    for svc in $expected; do
        if wait_healthy "$svc" 360; then
            pass "install-e2e: $svc healthy after install"
        else
            fail "install-e2e: $svc healthy after install"
        fi
        assert_eq "$(ie2e_lock_ref "$svc")" "$(ie2e_image_of "$svc")" \
            "install-e2e: $svc runs the Stable lock image from the installer's override"
        if grep -qP "^$svc\t[^\t]+\t$(ie2e_digest "$(ie2e_lock_ref "$svc")")\$" <<<"$record"; then
            pass "install-e2e: $svc install digest recorded for Revert"
        else
            fail "install-e2e: $svc install digest recorded for Revert"
        fi
    done
    for svc in npm fail2ban ddns-updater wireguard bazarr; do
        if dind_exec "docker inspect $svc >/dev/null 2>&1"; then
            fail "install-e2e: optional-profile $svc not started by a LAN-only install"
        else
            pass "install-e2e: optional-profile $svc not started by a LAN-only install"
        fi
    done
    if [[ "$(dind_exec "docker inspect --format '{{.State.Running}}' $TORZNAB_FIXTURE_NAME 2>/dev/null" | tr -d '\r\n')" == true ]]; then
        pass "install-e2e: torznab fixture site ran on the installer's network"
    else
        fail "install-e2e: torznab fixture site ran on the installer's network"
    fi
    ((FAIL_COUNT == IE2E_FAIL_BASE))
}

ie2e_containers() { dind_exec "docker ps -aq | xargs -r docker inspect --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' | sort"; }

# Container lines (name, ID, start time) that differ between two snapshots.
ie2e_changed() { diff <(echo "$1") <(echo "$2") | sed -n 's/^[<>] //p' | cut -c1-40 | sort -u | tr '\n' ' '; }

ie2e_state_files() {
    dind_exec 'sha256sum .env config.yml docker-compose.override.yml config/state/image-install.tsv'
}

ie2e_pty() { # <name> <command> <steps-json>; transcript in /tmp/ie2e-<name>.plain.log
    local name="$1" steps="/tmp/ie2e-$1.steps.json"
    dind_write_file "$steps" <<<"$3" || return 1
    ie2e_user_exec "timeout 1800 python3 -I tests/lib/wizard_pty.py --command '$2' --steps $steps --raw-log /tmp/ie2e-$name.raw.log --plain-log /tmp/ie2e-$name.plain.log --step-timeout 120 --exit-timeout 60"
}

ie2e_transcript() { dind_exec "cat /tmp/ie2e-$1.plain.log"; }

# Re-running the installer and choosing "Continue without changes" must change
# nothing. That branch returns before any configurator runs, so it cannot show
# drift handling; ie2e_reconfigure tests that.
ie2e_rerun() {
    local before_c before_f log
    ie2e_state seed && ie2e_state save || {
        fail 'install-e2e: seeds and records user settings before the re-run'
        return 1
    }
    before_c=$(ie2e_containers)
    before_f=$(ie2e_state_files)
    # Empty snapshots would make the unchanged-state comparisons below pass on nothing.
    if [[ "$before_c" == *"/jellyfin "* && "$(grep -cE '^[0-9a-f]{64} ' <<<"$before_f")" == 4 ]]; then
        pass 'install-e2e: container and state-file snapshots before the re-run are complete'
    else
        fail 'install-e2e: container and state-file snapshots before the re-run are complete' \
            "containers: $(grep -c . <<<"$before_c"); state files: $before_f"
        return 1
    fi
    if ie2e_pty rerun 'DEMO=1 ./setup.sh --full' '[
        {"choose": {"prompt": "What would you like to do\\?", "item": "^Use existing install$"}, "timeout": 300},
        {"choose": {"prompt": "What would you like to do\\?", "item": "^Continue without changes$"}}]'; then
        pass 'install-e2e: installer re-run with "Continue without changes" exits 0'
    else
        fail 'install-e2e: installer re-run with "Continue without changes" exits 0'
        ie2e_transcript rerun | tail -40
        return 1
    fi
    log=$(ie2e_transcript rerun)
    assert_contains "$log" 'Continuing with existing install. No changes made.' \
        'install-e2e: "Continue without changes" keeps the existing install'
    if grep -qE '\[ERROR\]|Pulling|Starting MediaStack|Running auto-configuration' <<<"$log"; then
        fail 'install-e2e: "Continue without changes" pulls, starts and configures nothing' \
            "$(grep -E '\[ERROR\]|Pulling|Starting|auto-configuration' <<<"$log" | head -3)"
    else
        pass 'install-e2e: "Continue without changes" pulls, starts and configures nothing'
    fi
    local changed
    changed=$(ie2e_changed "$before_c" "$(ie2e_containers)")
    if [[ -z "$changed" ]]; then
        pass 'install-e2e: "Continue without changes" recreates and restarts no container'
    else
        fail 'install-e2e: "Continue without changes" recreates and restarts no container' "changed: $changed"
    fi
    assert_eq "$before_f" "$(ie2e_state_files)" \
        'install-e2e: "Continue without changes" leaves .env, config.yml, override and install record unchanged'
    if ie2e_state check; then
        pass 'install-e2e: "Continue without changes" leaves saved user state unchanged'
    else
        fail 'install-e2e: "Continue without changes" leaves saved user state unchanged'
    fi
}

# upgradeAllowed of Sonarr's "1080p Balanced" profile: True, False, or an error.
ie2e_sonarr_upgrade_allowed() {
    dind_exec "curl -sf -H 'X-Api-Key: $(env_get SONARR_API_KEY | tr -d '\r\n')' http://127.0.0.1:8989/api/v3/qualityprofile" \
        | python3 -I -c '
import json, sys
try:
    profiles = json.load(sys.stdin)
    print(next(p for p in profiles if p["name"] == "1080p Balanced")["upgradeAllowed"])
except Exception as exc:
    print(f"unreadable: {exc!r}")
'
}

# Re-apply configuration the way a user does on a finished install:
# ./scripts/configure.sh (docs/guide/using-the-menu.md, Direct CLI usage). Every
# configurator runs against the live services, on the installed images. The
# Sonarr profile change from ie2e_rerun must be reported as drift and kept:
# re-runs warn on drift and never auto-reconcile.
ie2e_reconfigure() {
    local log=/tmp/ie2e-configure.log plain before errors
    before=$(ie2e_sonarr_upgrade_allowed)
    if [[ "$before" != True && "$before" != False ]]; then
        fail 'install-e2e: Sonarr profile is readable before the configure.sh re-run' "$before"
        return 1
    fi
    if ie2e_user_exec './scripts/configure.sh </dev/null' >"$log" 2>&1; then
        pass 'install-e2e: ./scripts/configure.sh re-run on the finished install exits 0'
    else
        fail 'install-e2e: ./scripts/configure.sh re-run on the finished install exits 0'
        tail -40 "$log"
        return 1
    fi
    plain=$(sed -r 's/\x1b\[[0-9;]*m//g' "$log")
    if grep -qE "^\[WARN\] Sonarr quality profile '1080p Balanced' differs from config.yml:.*upgrade_allowed" <<<"$plain"; then
        pass 'install-e2e: configure.sh re-run warns that the changed Sonarr profile differs from config.yml'
    else
        fail 'install-e2e: configure.sh re-run warns that the changed Sonarr profile differs from config.yml' \
            "$(grep -i 'quality profile' <<<"$plain" | head -3)"
    fi
    assert_eq "$before" "$(ie2e_sonarr_upgrade_allowed)" \
        'install-e2e: configure.sh re-run leaves the changed Sonarr profile as the user set it'
    if ie2e_state check; then
        pass 'install-e2e: configure.sh re-run keeps saved user state'
    else
        fail 'install-e2e: configure.sh re-run keeps saved user state'
    fi
    # fresh-install's assert_uptime_kuma_idempotent, on this user run: as root
    # it cannot reuse the error file that this user's run left in /tmp.
    if grep -qE '^\[SKIP\] Monitors already exist' <<<"$plain" && ! grep -qE '^\[OK\] Monitors created' <<<"$plain"; then
        pass 'install-e2e: configure.sh re-run keeps the Uptime Kuma monitors and creates none'
    else
        fail 'install-e2e: configure.sh re-run keeps the Uptime Kuma monitors and creates none' \
            "$(grep -E 'Monitors|Uptime Kuma' <<<"$plain" | head -3)"
    fi
    # A drift notice does not count as a warning (log_drift), so the summary
    # must still report a clean run.
    errors=$(grep -E '^\[ERROR\]' <<<"$plain")
    if [[ -z "$errors" ]] && grep -q 'Auto-configuration complete!' <<<"$plain"; then
        pass 'install-e2e: configure.sh re-run reports no error and no warning'
    else
        fail 'install-e2e: configure.sh re-run reports no error and no warning' \
            "${errors:-$(grep -E '^\[WARN\]|Auto-configuration complete' <<<"$plain" | grep -v 'differs from config.yml' | head -5)}"
    fi
}

# Jackett serves the fixture indexer's Torznab caps through its stored API key,
# the request Sonarr and Radarr make. The saved user state holds only the Arr
# rows, so it cannot show that Jackett itself still works.
ie2e_assert_jackett_caps() { # <label>
    local key verdict attempt
    key=$(api_get_jackett_key)
    # A recreated Jackett can report healthy shortly before it loads indexers.
    for attempt in 1 2 3 4 5 6; do
        verdict=$(jackett_indexer_caps mstest "$key")
        [[ "$verdict" == ok ]] && break
        ((attempt < 6)) && sleep 5
    done
    if [[ "$verdict" == ok ]]; then
        pass "install-e2e: Jackett serves Torznab categories after $1"
    else
        fail "install-e2e: Jackett serves Torznab categories after $1" "verdict=$verdict key=${key:0:8}"
    fi
}

# Steps from the launcher main menu into Manage updates, one action, and out.
ie2e_update_steps() {
    printf '[{"choose": {"prompt": "What would you like to do\\\\?", "item": "^Manage updates"}},
 {"choose": {"prompt": "Manage updates:", "item": "^Update a service$"}, "timeout": 300},
 {"choose": {"prompt": "Update which service\\\\?", "item": "^%s  "}},
 {"expect": "Update %s to the newest upstream image\\\\?[^\\\\n]*: ", "fresh": true, "send": "y\\n"},
 {"expect": "Press Enter to return to menu", "fresh": true, "send": "\\n", "timeout": 900},
 {"choose": {"prompt": "Manage updates:", "item": "^Back$"}},
 {"choose": {"prompt": "What would you like to do\\\\?", "item": "^Quit$"}}]' "$1" "$1"
}

ie2e_revert_steps() {
    printf '[{"choose": {"prompt": "What would you like to do\\\\?", "item": "^Manage updates"}},
 {"choose": {"prompt": "Manage updates:", "item": "^Revert a service to its installed image$"}, "timeout": 300},
 {"choose": {"prompt": "Revert which service to its installed image\\\\?", "item": "^%s  "}},
 {"expect": "Press Enter to return to menu", "fresh": true, "send": "\\n", "timeout": 900},
 {"choose": {"prompt": "Manage updates:", "item": "^Back$"}, "timeout": 300},
 {"choose": {"prompt": "What would you like to do\\\\?", "item": "^Quit$"}}]' "$1"
}

# One menu move of one service: it ends healthy on the expected image, no
# other container is recreated, and saved user state is unchanged.
ie2e_move() { # <update|revert> <service> <expected image ref> <label>
    local action="$1" svc="$2" want="$3" label="$4" before after steps
    before=$(ie2e_containers)
    if [[ "$action" == update ]]; then steps=$(ie2e_update_steps "$svc"); else steps=$(ie2e_revert_steps "$svc"); fi
    if ie2e_pty "$action-$svc" ./mediastack "$steps" && wait_healthy "$svc" 300; then
        pass "install-e2e: menu $label $svc completes and $svc is healthy"
    else
        fail "install-e2e: menu $label $svc completes and $svc is healthy"
        ie2e_transcript "$action-$svc" | tail -40
        return 1
    fi
    assert_eq "$want" "$(ie2e_image_of "$svc")" "install-e2e: $label $svc runs $want"
    if ie2e_runs_digest "$svc" "$(ie2e_digest "$want")"; then
        pass "install-e2e: $label $svc running image has digest $(ie2e_digest "$want" | cut -c1-19)"
    else
        fail "install-e2e: $label $svc running image has digest $(ie2e_digest "$want" | cut -c1-19)"
    fi
    after=$(ie2e_containers)
    local others id_before id_after
    others=$(ie2e_changed "$(grep -v "^/$svc " <<<"$before")" "$(grep -v "^/$svc " <<<"$after")")
    id_before=$(awk -v n="/$svc" '$1 == n { print $2 }' <<<"$before")
    id_after=$(awk -v n="/$svc" '$1 == n { print $2 }' <<<"$after")
    if [[ -z "$others" && -n "$id_after" && "$id_before" != "$id_after" ]]; then
        pass "install-e2e: $label $svc recreates $svc and no other container"
    else
        fail "install-e2e: $label $svc recreates $svc and no other container" \
            "id ${id_before:0:12} -> ${id_after:0:12}; other changes: ${others:-none}"
    fi
    if ie2e_state check; then
        pass "install-e2e: user state survives $label $svc"
    else
        fail "install-e2e: user state survives $label $svc"
    fi
    ie2e_assert_jackett_caps "$label $svc"
}

ie2e_menu_updates() {
    local svc status want_status table
    if ! ie2e_pty status ./mediastack '[
        {"choose": {"prompt": "What would you like to do\\?", "item": "^Manage updates"}},
        {"choose": {"prompt": "Manage updates:", "item": "^Back$"}, "timeout": 300},
        {"choose": {"prompt": "What would you like to do\\?", "item": "^Quit$"}}]'; then
        fail 'install-e2e: ./mediastack reaches Manage updates'
        ie2e_transcript status | tail -40
        return 1
    fi
    pass 'install-e2e: ./mediastack reaches Manage updates'
    table=$(ie2e_transcript status | tr -d '\r')
    for svc in "${IE2E_DATA_SERVICES[@]}"; do
        want_status="Up to date"
        [[ "${IE2E_TARGET[$svc]}" != "${IE2E_INSTALLED[$svc]}" ]] && want_status="Update available"
        status=$(awk -v s="$svc" 'substr($0, 3, 13) ~ "^" s " *$" { print substr($0, 36); exit }' <<<"$table")
        assert_eq "$want_status" "$status" "install-e2e: Manage updates shows $svc as $want_status"
    done
    local pin
    for svc in "${IE2E_DATA_SERVICES[@]}"; do
        if [[ "${IE2E_TARGET[$svc]}" == "${IE2E_INSTALLED[$svc]}" ]]; then
            # The menu offers Update only when the target digest differs. Not a
            # skip: a skip would withhold every receipt of this run, including
            # those of the services that do have a candidate.
            echo "  [NOTE] $svc: no candidate differs from its installed image; no menu Update/Revert for it in this run"
            continue
        fi
        pin=$(dind_exec "awk -F '\t' -v s=$svc '\$1 == s { print \$2 \"@\" \$3 }' config/state/image-install.tsv" | tr -d '\r\n')
        ie2e_move update "$svc" "${IE2E_TARGET[$svc]}" Update || return 1
        ie2e_move revert "$svc" "$pin" Revert || return 1
        assert_eq "${IE2E_INSTALLED[$svc]##*@}" "${pin##*@}" "install-e2e: Revert $svc target is the installed digest"
        # End on the candidate: receipts judge the last container of each service.
        ie2e_move update "$svc" "${IE2E_TARGET[$svc]}" 'second Update' || return 1
    done
}

ie2e_run() {
    IE2E_FAIL_BASE=$FAIL_COUNT
    ie2e_plan_images || return 1
    ie2e_prepare || {
        fail 'install-e2e: host and wizard answers prepared'
        return 1
    }
    ie2e_install || return 1
    ie2e_rerun || return 1
    ie2e_reconfigure || return 1
    ie2e_menu_updates || return 1
    # Every default-profile service, now on its candidate, is still configured.
    fresh_install_assert_services "$IE2E_SETUP_LOG" "$IE2E_PASSWORD" lan
    # The fresh-install checks that need no remote state. They change Jellyfin
    # encoding and config.yml, so they run last. Omitted checks and the reasons
    # are in docs/operations/image-compatibility.md.
    assert_jellyfin_encoding
    assert_drift_regression
}

run_scenario() {
    if [[ -n "${MS_TEST_STRIP_SERVICES:-}" ]]; then
        fail 'install-e2e requires the complete default stack'
        return 1
    fi
    local rc=0
    ie2e_run || rc=$?
    # --reset-between restores the repository but not the DinD host. Remove the
    # installer's ownership ledger and the sudo rule so later scenarios start
    # from a host with no MediaStack install record.
    dind_exec 'rm -rf /etc/mediastack /etc/sudoers.d/90-mediastack-e2e' || true
    return "$rc"
}

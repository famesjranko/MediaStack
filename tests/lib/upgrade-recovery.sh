# Real-container interrupted Revert. The launcher fixture only injects SIGKILL
# after the real config rename; Docker, archive operations and login stay real.
upgrade_interrupted_revert() {
    local log=/tmp/ms-upgrade-interrupted.log rc=0
    dind_exec '
        rm -f /tmp/upgrade-revert-interrupted /tmp/upgrade-original-safety.sha /tmp/upgrade-retry-safety.sha &&
        printf "newer config survives in safety archive\n" >config/qbittorrent/upgrade-newer-only.txt
    ' || return 1
    upgrade_launcher interrupt >"$log" 2>&1 || rc=$?
    if ((rc != 137)) || ! dind_exec '
        test -f /tmp/upgrade-revert-interrupted &&
        test ! -e config/qbittorrent &&
        test "$(docker inspect --format "{{.State.Running}}" qbittorrent)" = false &&
        test "$(stat -c %a config/state/revert-qbittorrent.tsv)" = 600 &&
        test "$(stat -c %a config/state/restore-points/qbittorrent.pre-revert.tar.gz)" = 600 &&
        sha256sum config/state/restore-points/qbittorrent.pre-revert.tar.gz >/tmp/upgrade-original-safety.sha &&
        test "$(tar -xzOf config/state/restore-points/qbittorrent.pre-revert.tar.gz qbittorrent/upgrade-newer-only.txt)" = "newer config survives in safety archive"
    '; then
        fail 'upgrade-path interrupts a stopped real container in the config rename gap'
        tail -25 "$log"
        return 1
    fi
    pass 'upgrade-path interrupts a stopped real container in the config rename gap'

    if upgrade_launcher retry >"$log" 2>&1 && wait_healthy qbittorrent 120 \
        && upgrade_state check && dind_exec '
            cmp -s /tmp/upgrade-original-safety.sha /tmp/upgrade-retry-safety.sha &&
            test ! -f config/qbittorrent/upgrade-newer-only.txt &&
            test ! -e config/state/revert-qbittorrent.tsv &&
            test ! -e config/state/restore-points/qbittorrent.work &&
            test ! -f config/state/restore-points/qbittorrent.tar.gz &&
            test "$(docker inspect --format "{{.State.Running}}" qbittorrent)" = true &&
            expected=$(awk -F "\t" '\''$1 == "qbittorrent" {print $2 "@" $3}'\'' config/state/image-install.tsv) &&
            test -n "$expected" &&
            test "$(docker inspect --format "{{.Config.Image}}" qbittorrent)" = "$expected"
        '; then
        pass 'upgrade-path retries Revert with the same safety archive, installed image, resume data and real login'
    else
        fail 'upgrade-path retries Revert with the same safety archive, installed image, resume data and real login'
        tail -25 "$log"
        return 1
    fi
}

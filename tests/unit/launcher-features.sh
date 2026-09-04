#!/usr/bin/env bash
# tests/unit/launcher-features.sh
#
# Launcher coverage for the day-2 "Features" submenu: the three optional,
# reversible toggles — Bazarr subtitles, the host SMB share, and public search
# indexers. Verifies:
#   1. submenu_features renders ON/OFF state from .env; remote/GPU adds self-hide.
#   2. launcher_menu_post always exposes "Features" and routes to submenu_features.
#   3. menu choices dispatch to the right action_toggle_* handler.
#   4. each toggle does the right, ADD-ONLY thing — and enabling indexers wires
#      them into Sonarr/Radarr (configure.sh --only jackett,sonarr,radarr), not
#      just Jackett, while turning a feature OFF never deletes user data.
#
# The launcher is sourced (its BASH_SOURCE guard skips main()); the toggle
# behaviour tests run each handler against a sandbox SCRIPT_DIR with fake
# configure.sh / wizard_apply / setup_samba so the real commands are captured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-features"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# 1. submenu_features: ON/OFF state from .env; remote/GPU adds self-hide.
# ---------------------------------------------------------------------------
render_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  BAZARR_ENABLED=true; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
  UFW_ENABLED=false; HARDENING_ENABLED=true
  submenu_features >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$render_out" "Subtitles (Bazarr): ON" "features: bazarr state ON read from .env"
assert_contains "$render_out" "File sharing (SMB): OFF" "features: smb state OFF read from .env"
assert_contains "$render_out" "Search indexers: OFF" "features: indexers state OFF read from .env"
assert_contains "$render_out" "Firewall (UFW): OFF" "features: ufw state OFF read from .env"
assert_contains "$render_out" "System hardening: ON" "features: hardening state ON read from .env"
if grep -q "NAS storage watchdog" <<<"$render_out"; then
    fail "features: NAS watchdog hidden on non-NAS install"
else
    pass "features: NAS watchdog hidden on non-NAS install"
fi
if grep -q "Add remote access" <<<"$render_out"; then
    fail "features: remote add hidden when already configured"
else
    pass "features: remote add hidden when already configured"
fi
if grep -q "Add hardware transcoding" <<<"$render_out"; then
    fail "features: GPU add never offered here — single home is top-level 'Manage hardware transcoding (GPU)'"
else
    pass "features: GPU add never offered here — single home is top-level 'Manage hardware transcoding (GPU)'"
fi

# The remote add appears only when its recovery predicate allows it. The GPU add
# is deliberately NEVER offered here even when the transcoding predicate is true —
# its single home is the always-present top-level "Manage hardware transcoding".
adds_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  recovery_menu_remote_available(){ return 0; }
  recovery_menu_transcoding_available(){ return 0; }
  submenu_features >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$adds_out" "Add remote access" "features: remote add shown when available"
if grep -q "Add hardware transcoding" <<<"$adds_out"; then
    fail "features: GPU add NOT offered here even when transcoding predicate is true (single top-level home)"
else
    pass "features: GPU add NOT offered here even when transcoding predicate is true (single top-level home)"
fi

# The NAS storage watchdog toggle appears only on NAS installs (STORAGE_MODE=nas).
nas_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  render_banner(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  STORAGE_MODE=nas; STORAGE_WATCHDOG=true
  submenu_features >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$nas_out" "NAS storage watchdog: ON" "features: NAS watchdog shown ON on NAS install"

# ---------------------------------------------------------------------------
# 2. launcher_menu_post always exposes Features and routes it to submenu_features.
# ---------------------------------------------------------------------------
menu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  STAGE_1_COMPLETE=1
  launcher_menu_post >/dev/null 2>&1
  tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
' 2>&1)
assert_contains "$menu_out" "Features & settings (quality, bandwidth, subtitles, sharing, indexers)" \
    "launcher_menu_post: Features item always shown"
if grep -q "Add a feature" <<<"$menu_out"; then
    fail "launcher_menu_post: legacy 'Add a feature' label removed"
else
    pass "launcher_menu_post: legacy 'Add a feature' label removed"
fi

route_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  ui_choose(){ echo "Features & settings (quality, bandwidth, subtitles, sharing, indexers)"; }
  submenu_features(){ echo DISPATCH_FEATURES; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  STAGE_1_COMPLETE=1
  launcher_menu_post 2>&1
' 2>&1)
assert_contains "$route_out" "DISPATCH_FEATURES" "launcher_menu_post: Features routes to submenu_features"

# ---------------------------------------------------------------------------
# 3. submenu_features dispatches each toggle label to the right handler.
# ---------------------------------------------------------------------------
dispatch() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" CHOICE="$1" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    render_banner(){ :; }
    recovery_menu_remote_available(){ return 1; }
    recovery_menu_transcoding_available(){ return 1; }
    ui_choose(){ echo "$CHOICE"; }
    action_toggle_bazarr(){ echo DISPATCH_BAZARR; exit 0; }
    action_toggle_smb(){ echo DISPATCH_SMB; exit 0; }
    action_toggle_indexers(){ echo DISPATCH_INDEXERS; exit 0; }
    action_toggle_ufw(){ echo DISPATCH_UFW; exit 0; }
    action_toggle_hardening(){ echo DISPATCH_HARDENING; exit 0; }
    BAZARR_ENABLED=true; SMB_ENABLED=false; PUBLIC_INDEXERS_ENABLED=false
    submenu_features 2>&1
  ' 2>&1
}
assert_contains "$(dispatch 'Subtitles (Bazarr): ON')" "DISPATCH_BAZARR" "dispatch: subtitles -> bazarr toggle"
assert_contains "$(dispatch 'File sharing (SMB): OFF')" "DISPATCH_SMB" "dispatch: file sharing -> smb toggle"
assert_contains "$(dispatch 'Search indexers: OFF')" "DISPATCH_INDEXERS" "dispatch: indexers -> indexers toggle"
assert_contains "$(dispatch 'Firewall (UFW): OFF')" "DISPATCH_UFW" "dispatch: firewall -> ufw toggle"
assert_contains "$(dispatch 'System hardening: ON')" "DISPATCH_HARDENING" "dispatch: hardening -> hardening toggle"

# Watchdog dispatch needs STORAGE_MODE=nas for the option to be built.
watchdog_dispatch=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  ui_choose(){ echo "NAS storage watchdog: ON"; }
  action_toggle_watchdog(){ echo DISPATCH_WATCHDOG; exit 0; }
  STORAGE_MODE=nas; STORAGE_WATCHDOG=true
  submenu_features 2>&1
' 2>&1)
assert_contains "$watchdog_dispatch" "DISPATCH_WATCHDOG" "dispatch: NAS watchdog -> watchdog toggle"

# ---------------------------------------------------------------------------
# 4. Toggle BEHAVIOUR in a sandbox SCRIPT_DIR — capture real commands + .env.
# ---------------------------------------------------------------------------
# run_toggle <handler> <init-env-lines>  -> prints "=== ENV ===" .env then
# "=== CAP ===" the captured external commands.
run_toggle() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" HANDLER="$1" INIT="$2" FAIL_PERSIST="${3:-0}" bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
    mkdir -p "$tmp/scripts/setup"
    printf "%s\n" "$INIT" > "$tmp/.env"
    cat > "$tmp/scripts/configure.sh" <<"EOF"
#!/usr/bin/env bash
echo "CONFIGURE $*" >> "$CAPTURE"
EOF
    chmod +x "$tmp/scripts/configure.sh"
    cat > "$tmp/scripts/setup/hardening.sh" <<"EOF"
setup_samba(){ echo "SAMBA enabled=${SMB_ENABLED} scope=${SMB_SHARE_SCOPE:-}" >> "$CAPTURE"; }
setup_ufw(){ echo "UFW_SETUP" >> "$CAPTURE"; }
setup_ufw_service_ports(){ echo "UFW_PORTS" >> "$CAPTURE"; }
setup_unattended_upgrades(){ echo "APT_HARDEN" >> "$CAPTURE"; }
setup_sysctl_hardening(){ echo "SYSCTL_HARDEN" >> "$CAPTURE"; }
_uninstall_ufw(){ echo "UFW_UNINSTALL" >> "$CAPTURE"; return 0; }
_uninstall_sysctl(){ echo "SYSCTL_UNINSTALL" >> "$CAPTURE"; return 0; }
_uninstall_apt(){ echo "APT_UNINSTALL" >> "$CAPTURE"; return 0; }
_ms_state_set(){ echo "STATE_SET $*" >> "$CAPTURE"; }
validate_install_state(){ return 0; }
EOF
    # UFW OFF path probes `sudo ufw status`; stub sudo so it never really runs.
    sudo(){ echo "SUDO $*" >> "$CAPTURE"; return 0; }
    _docker_reachable(){ return 0; }
    _regenerate_override(){ :; }
    docker(){ echo "DOCKER $*" >> "$CAPTURE"; }
    # Capture wizard_apply.py calls, but let the real python3 run the .env writer
    # (_env_write_kv invokes `python3 - <file> <key> <value>...` reading its script on stdin).
    python3(){ if [[ "$1" == "-" ]]; then command python3 "$@"; else echo "WIZARD $*" >> "$CAPTURE"; fi; }
    ui_log(){ :; }; launcher_pause_for_menu(){ :; }; _show_action_result(){ echo "RESULT rc=$1 label=$2" >> "$CAPTURE"; }
    ui_confirm(){ return 0; }
    ui_choose(){ echo "Media only (recommended)"; }
    storage_install_watchdog(){ echo "WATCHDOG_INSTALL" >> "$CAPTURE"; }
    storage_pause_watchdog_for_install(){ echo "WATCHDOG_PAUSE" >> "$CAPTURE"; }
    if [[ "${FAIL_PERSIST:-0}" == 1 ]]; then
        _set_env_vars(){ echo "PERSIST_ATOMIC $*" >> "$CAPTURE"; return 7; }
    fi
    _reload_env                       # load INIT into shell vars
    "$HANDLER"
    echo "=== ENV ==="; cat "$tmp/.env"
    echo "=== CAP ==="; cat "$CAPTURE"
    rm -rf "$tmp"
  ' 2>&1
}

# --- Bazarr ON: enable profile, start container, configure it ---------------
b_on=$(run_toggle action_toggle_bazarr "BAZARR_ENABLED=false")
assert_contains "$b_on" "up -d bazarr" "bazarr ON: starts the bazarr container"
assert_contains "$b_on" "CONFIGURE --only bazarr" "bazarr ON: configures bazarr"
assert_contains "$b_on" "BAZARR_ENABLED='true'" "bazarr ON: .env flag set true (single-quoted)"

# --- Bazarr OFF: stop+remove only the container; data-safe (no down -v) -----
b_off=$(run_toggle action_toggle_bazarr "BAZARR_ENABLED=true")
assert_contains "$b_off" "rm -sf bazarr" "bazarr OFF: removes only the container"
assert_contains "$b_off" "BAZARR_ENABLED='false'" "bazarr OFF: .env flag set false (single-quoted)"
if grep -Eq "down|[[:space:]]-v([[:space:]]|$)" <<<"$b_off"; then
    fail "bazarr OFF: add-only — never 'down' or '-v' (would drop volumes)"
else
    pass "bazarr OFF: add-only — never 'down' or '-v' (would drop volumes)"
fi

# --- Indexers ON: wire into Jackett AND Sonarr/Radarr (regression guard) -----
i_on=$(run_toggle action_toggle_indexers "PUBLIC_INDEXERS_ENABLED=false")
assert_contains "$i_on" "WIZARD" "indexers ON: regenerates config.yml indexer list"
assert_contains "$i_on" "--indexers-only true" "indexers ON: surgical indexers-only apply"
assert_contains "$i_on" "CONFIGURE --only jackett,sonarr,radarr" \
    "indexers ON: wires indexers into Jackett AND Sonarr/Radarr (not Jackett alone)"
assert_contains "$i_on" "PUBLIC_INDEXERS_ENABLED='true'" "indexers ON: .env flag set true (single-quoted)"

# --- Indexers OFF: clear config.yml list; never re-run configure (add-only) --
i_off=$(run_toggle action_toggle_indexers "PUBLIC_INDEXERS_ENABLED=true")
assert_contains "$i_off" "--indexers-only false" "indexers OFF: clears config.yml indexer list"
assert_contains "$i_off" "PUBLIC_INDEXERS_ENABLED='false'" "indexers OFF: .env flag set false (single-quoted)"
if grep -q "CONFIGURE" <<<"$i_off"; then
    fail "indexers OFF: does not re-run configure (existing indexers persist, never deleted)"
else
    pass "indexers OFF: does not re-run configure (existing indexers persist, never deleted)"
fi

# --- SMB ON / OFF: idempotent setup_samba both directions -------------------
s_on=$(run_toggle action_toggle_smb "SMB_ENABLED=false")
assert_contains "$s_on" "SAMBA enabled=true scope=data" "smb ON: runs setup_samba with chosen scope"
assert_contains "$s_on" "SMB_ENABLED='true'" "smb ON: .env flag set true (single-quoted)"
assert_contains "$s_on" "SMB_SHARE_SCOPE='data'" "smb ON: .env scope recorded (single-quoted)"

s_off=$(run_toggle action_toggle_smb "SMB_ENABLED=true")
assert_contains "$s_off" "SAMBA enabled=false" "smb OFF: runs setup_samba cleanup path"
assert_contains "$s_off" "SMB_ENABLED='false'" "smb OFF: .env flag set false (single-quoted)"

# --- UFW ON / OFF: configure via setup_ufw; revert via _uninstall_ufw + latch reset
u_on=$(run_toggle action_toggle_ufw "UFW_ENABLED=false")
assert_contains "$u_on" "UFW_SETUP" "ufw ON: runs setup_ufw"
assert_contains "$u_on" "UFW_ENABLED='true'" "ufw ON: .env flag set true (single-quoted)"

u_off=$(run_toggle action_toggle_ufw "UFW_ENABLED=true")
assert_contains "$u_off" "UFW_UNINSTALL" "ufw OFF: runs _uninstall_ufw (ledger-aware revert)"
assert_contains "$u_off" "STATE_SET UFW_DEFAULTS_APPLIED false" "ufw OFF: resets latch so re-enable reconfigures"
assert_contains "$u_off" "STATE_SET UFW_RULE_COUNT 0" "ufw OFF: resets recorded rule count"
assert_contains "$u_off" "UFW_ENABLED='false'" "ufw OFF: .env flag set false (single-quoted)"

# --- Hardening ON / OFF: apply/revert sysctl + unattended-upgrades ----------
h_on=$(run_toggle action_toggle_hardening "HARDENING_ENABLED=false")
assert_contains "$h_on" "APT_HARDEN" "hardening ON: enables unattended-upgrades"
assert_contains "$h_on" "SYSCTL_HARDEN" "hardening ON: applies kernel sysctl hardening"
assert_contains "$h_on" "HARDENING_ENABLED='true'" "hardening ON: .env flag set true (single-quoted)"

h_off=$(run_toggle action_toggle_hardening "HARDENING_ENABLED=true")
assert_contains "$h_off" "SYSCTL_UNINSTALL" "hardening OFF: reverts kernel sysctl"
assert_contains "$h_off" "APT_UNINSTALL" "hardening OFF: removes unattended-upgrades policy"
assert_contains "$h_off" "HARDENING_ENABLED='false'" "hardening OFF: .env flag set false (single-quoted)"

# --- NAS watchdog ON / OFF: install unit vs stop+disable; flip .env flag ------
w_on=$(run_toggle action_toggle_watchdog $'STORAGE_MODE=nas\nSTORAGE_WATCHDOG=false')
assert_contains "$w_on" "WATCHDOG_INSTALL" "watchdog ON: installs the systemd unit"
assert_contains "$w_on" "STORAGE_WATCHDOG='true'" "watchdog ON: .env flag set true (single-quoted)"

w_off=$(run_toggle action_toggle_watchdog $'STORAGE_MODE=nas\nSTORAGE_WATCHDOG=true')
assert_contains "$w_off" "WATCHDOG_PAUSE" "watchdog OFF: stops+disables the unit"
assert_contains "$w_off" "STORAGE_WATCHDOG='false'" "watchdog OFF: .env flag set false (single-quoted)"
if grep -Eq "down|[[:space:]]-v([[:space:]]|$)" <<<"$w_off"; then
    fail "watchdog OFF: host unit only — never touches docker compose volumes"
else
    pass "watchdog OFF: host unit only — never touches docker compose volumes"
fi

# --- Persistence failure is a hard precondition: no host/container apply ----
# A failed durable write must stop before reload or live mutation. SMB's flag and
# scope are one atomic pair, so neither value may be written or applied alone.
ufw_persist_fail=$(run_toggle action_toggle_ufw "UFW_ENABLED=false" 1)
assert_contains "$ufw_persist_fail" "PERSIST_ATOMIC UFW_ENABLED true" \
    "ufw persist failure: durable write is attempted before apply"
assert_not_contains "$ufw_persist_fail" "UFW_SETUP" \
    "ufw persist failure: setup is blocked when .env write fails"
assert_contains "$ufw_persist_fail" "UFW_ENABLED=false" \
    "ufw persist failure: .env retains old state"
assert_contains "$ufw_persist_fail" "RESULT rc=1" \
    "ufw persist failure: action reports failure"

smb_persist_fail=$(run_toggle action_toggle_smb "SMB_ENABLED=false" 1)
assert_contains "$smb_persist_fail" "PERSIST_ATOMIC SMB_ENABLED true SMB_SHARE_SCOPE data" \
    "smb persist failure: flag and scope use one atomic durable write"
assert_not_contains "$smb_persist_fail" "SAMBA enabled" \
    "smb persist failure: setup is blocked when atomic .env write fails"
assert_not_contains "$smb_persist_fail" "SMB_ENABLED='true'" \
    "smb persist failure: .env does not contain a partial flag"
assert_not_contains "$smb_persist_fail" "SMB_SHARE_SCOPE='data'" \
    "smb persist failure: .env does not contain a partial scope"
assert_contains "$smb_persist_fail" "RESULT rc=1" \
    "smb persist failure: action reports failure"

# ---------------------------------------------------------------------------
# 5. Non-TTY safety + indexer-clobber warning (direct regression guards).
# ---------------------------------------------------------------------------
# Sections 1-4 stub ui_confirm/ui_choose, so they prove dispatch + add-only
# command emission but NOT that the real non-TTY path is hang-free. 5a drives a
# toggle through the REAL ui_confirm against a closed stdin, under a timeout:
# ui_confirm on EOF returns its default with NO re-prompt loop, so the handler
# must TERMINATE (timeout rc 0, never 124) and take the deterministic default
# path. (The SMB toggle's ui_choose intentionally `kill -TERM 0`s the process
# group on EOF, so it is deliberately exercised only via stubs above, never
# here.)
run_real_confirm() {
    local out trc
    # The bash -c body is single-quoted on purpose: $REPO_ROOT/$INIT/$HANDLER are
    # passed via the env-var prefix and expand in the INNER shell, not here.
    # shellcheck disable=SC2016
    out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" HANDLER="$1" INIT="$2" \
        timeout 20 bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; export CAPTURE="$tmp/cap"; : > "$CAPTURE"
      mkdir -p "$tmp/scripts/setup"
      printf "%s\n" "$INIT" > "$tmp/.env"
      cat > "$tmp/scripts/configure.sh" <<"EOF"
#!/usr/bin/env bash
echo "CONFIGURE $*" >> "$CAPTURE"
EOF
      chmod +x "$tmp/scripts/configure.sh"
      _docker_reachable(){ return 0; }
      _regenerate_override(){ :; }
      docker(){ echo "DOCKER $*" >> "$CAPTURE"; }
      # Capture wizard_apply.py calls, but let the real python3 run the .env writer.
      python3(){ if [[ "$1" == "-" ]]; then command python3 "$@"; else echo "WIZARD $*" >> "$CAPTURE"; fi; }
      ui_log(){ :; }; launcher_pause_for_menu(){ :; }; _show_action_result(){ :; }
      # ui_confirm is the REAL primitive — its read sees EOF from </dev/null.
      _reload_env
      "$HANDLER" </dev/null
      cat "$CAPTURE"
      rm -rf "$tmp"
    ' 2>&1)
    trc=$?
    printf "TIMEOUT_RC=%s\n%s\n" "$trc" "$out"
}

# OFF: real ui_confirm default "no" -> EOF returns no -> "No change", clean
# return, no container touched.
rc_off=$(run_real_confirm action_toggle_bazarr "BAZARR_ENABLED=true")
assert_contains "$rc_off" "TIMEOUT_RC=0" \
    "non-TTY: real ui_confirm on closed stdin terminates the toggle (no re-prompt hang)"
if grep -q "DOCKER" <<<"$rc_off"; then
    fail "non-TTY: EOF -> default 'no' = No change, container untouched"
else
    pass "non-TTY: EOF -> default 'no' = No change, container untouched"
fi

# ON: real ui_confirm default "yes" -> EOF returns yes -> proceeds, still
# terminates (no hang).
rc_on=$(run_real_confirm action_toggle_bazarr "BAZARR_ENABLED=false")
assert_contains "$rc_on" "TIMEOUT_RC=0" \
    "non-TTY: real ui_confirm 'yes' default toggle terminates (no re-prompt hang)"
assert_contains "$rc_on" "up -d bazarr" \
    "non-TTY: EOF -> default 'yes' proceeds deterministically"

# 5b. Enabling indexers warns FIRST that it rewrites config.yml's indexer list
#     (the bundled example preset overwrites any hand-added entries).
warn_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"
  printf "PUBLIC_INDEXERS_ENABLED=false\n" > "$tmp/.env"
  _docker_reachable(){ return 0; }
  ui_confirm(){ return 1; }        # decline right after the warning prints
  launcher_pause_for_menu(){ :; }; _show_action_result(){ :; }
  _reload_env
  action_toggle_indexers
  rm -rf "$tmp"
' 2>&1)
assert_contains "$warn_out" "will be overwritten" \
    "indexers ON: warns the config.yml indexer list is rewritten before enabling"

scenario_end "$CURRENT_SCENARIO"
summary

#!/usr/bin/env bash
# Unit test - per-service image policy + update-status detection.
#
# Covers the load-bearing pieces of the "Manage updates" feature without
# DinD/Docker/network:
#   1. override.sh per-service policy: floating one service drops only its digest
#      pin (compose tag preserved) while the rest stay pinned; mem/header intact.
#   2. image_drift.py status: the channel-agnostic 2-state truth table and
#      the hardened running-digest extraction (image-object RepoDigests, repo-matched).
#   3. mediastack launcher: apply floats a pinned service to its compose tag
#      (decided by effective channel, not status text), the flip/reset helpers, and
#      "Update all" WireGuard exclusion. The launcher is sourced (its BASH_SOURCE
#      guard skips main()); override.sh is sourced alongside it for the policy
#      backend (_effective_channel / _service_policy).
#
# Run directly: ./tests/unit/manage-updates.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="manage-updates"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# 1. override.sh per-service policy
# ---------------------------------------------------------------------------
# Each check runs in its own `bash` so stub funcs and a fake SCRIPT_DIR don't
# leak into the launcher source below; results come back as tokens we assert on.
ov_out=$(REPO_ROOT="$REPO_ROOT" bash -c '
  set -uo pipefail
  tmp=$(mktemp -d); mkdir -p "$tmp/docs/operations" "$tmp/config/state"
  cp "$REPO_ROOT/docs/operations/image-digests.lock" "$tmp/docs/operations/"
  SCRIPT_DIR="$tmp"; HOST_MEMORY_MB=8192; STORAGE_MODE=local
  log_warn(){ :; }; log_ok(){ :; }; log_error(){ echo "ERR $*"; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  ov="$tmp/docker-compose.override.yml"

  # (a) global stable + jellyfin floated to its upstream tag
  IMAGE_CHANNEL=stable
  printf "jellyfin\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  generate_override none
  echo "MIXED_PINS=$(grep -c "image: .*@sha256:" "$ov")"
  grep -q "image: jellyfin/jellyfin.*@sha256:" "$ov" && echo "JF=pinned" || echo "JF=floats"
  grep -q "image: linuxserver/sonarr:latest@sha256:" "$ov" && echo "SONARR=pinned" || echo "SONARR=unpinned"
  echo "MEMLINES=$(grep -c "mem_limit:" "$ov")"
  grep -q "Per-service overrides: jellyfin=latest" "$ov" && echo "NOTE=ok" || echo "NOTE=missing"

  # (b) clear the override (return to stable) -> everything pinned again
  rm -f "$tmp/config/state/image-policy.tsv"
  generate_override none
  echo "STABLE_PINS=$(grep -c "image: .*@sha256:" "$ov")"

  # (c) global latest -> no digest pins at all
  IMAGE_CHANNEL=latest
  generate_override none
  echo "LATEST_PINS=$(grep -c "image: .*@sha256:" "$ov")"
  rm -rf "$tmp"
')
assert_contains "$ov_out" "MIXED_PINS=18" "override: floating jellyfin leaves 18 of 19 pinned"
assert_contains "$ov_out" "JF=floats" "override: floated service drops its digest pin"
assert_contains "$ov_out" "SONARR=pinned" "override: other services stay pinned to the lock"
assert_contains "$ov_out" "MEMLINES=19" "override: mem_limit preserved for every service"
assert_contains "$ov_out" "NOTE=ok" "override: header records the per-service override"
assert_contains "$ov_out" "STABLE_PINS=19" "override: clearing the override re-pins all services"
assert_contains "$ov_out" "LATEST_PINS=0" "override: global latest pins nothing"

# ---------------------------------------------------------------------------
# 2. image_drift.py status: truth table + hardened running-digest extraction
# ---------------------------------------------------------------------------
status_out=$(
    REPO_ROOT="$REPO_ROOT" python3 - <<'PY' 2>&1
import importlib.util, os, sys, json
path = os.path.join(os.environ["REPO_ROOT"], "scripts/image_drift.py")
spec = importlib.util.spec_from_file_location("idrift", path)
m = importlib.util.module_from_spec(spec); sys.modules["idrift"] = m; spec.loader.exec_module(m)

LOCK = "sha256:" + "a"*64
UP   = "sha256:" + "b"*64
OLD  = "sha256:" + "c"*64

# Channel-agnostic 2-state truth table: present flag separates absence from
# unknown digest; policy/lock are ignored — a pinned Stable service and an
# upstream-tag service both read "Update available" when they trail their tag.
assert m.derive_status("stable", False, None, UP, LOCK)        == ("Not installed", False)
assert m.derive_status("stable", True,  None, UP, LOCK)        == ("Unknown local digest", False)
assert m.derive_status("stable", True,  LOCK, "unknown", LOCK) == ("Unknown (offline)", False)
assert m.derive_status("stable", True,  LOCK, LOCK, LOCK)      == ("Up to date", False)
assert m.derive_status("stable", True,  LOCK, UP, LOCK)        == ("Update available", True)   # pinned, tag moved ahead
assert m.derive_status("latest", True,  UP, UP, None)          == ("Up to date", False)
assert m.derive_status("latest", True,  OLD, UP, None)         == ("Update available", True)
assert m.derive_status("latest", True,  OLD, "unknown", None)  == ("Unknown (offline)", False)

# Hardened digest extraction: presence (container_image_id) is separate from the
# repo-digest match (image_repo_digest, reads RepoDigests off the image object).
CONTAINER = (0, "sha256:imgid\n")
REPODIGESTS = "[]"
def fake_run(cmd, **kw):
    class R:
        pass
    r = R()
    if cmd[:2] == ["docker", "inspect"]:
        r.returncode, r.stdout = CONTAINER
    elif cmd[:3] == ["docker", "image", "inspect"]:
        r.returncode, r.stdout = 0, REPODIGESTS
    else:
        r.returncode, r.stdout = 1, ""
    return r
m.subprocess.run = fake_run

assert m.container_image_id("sonarr") == "sha256:imgid", "container present -> image id"
CONTAINER = (1, "")
assert m.container_image_id("sonarr") is None, "container absent -> None"
CONTAINER = (0, "sha256:imgid\n")

REPODIGESTS = json.dumps(["jellyfin/jellyfin@" + UP])
assert m.image_repo_digest("id", "jellyfin/jellyfin:latest") == UP, "single repo match"
REPODIGESTS = json.dumps(["other/x@" + OLD, "jellyfin/jellyfin@" + UP])
assert m.image_repo_digest("id", "jellyfin/jellyfin:latest") == UP, "multi-repo: pick matching"
REPODIGESTS = json.dumps(["docker.io/jellyfin/jellyfin@" + UP])
assert m.image_repo_digest("id", "jellyfin/jellyfin:latest") == UP, "docker.io normalization"
REPODIGESTS = json.dumps([])
assert m.image_repo_digest("id", "jellyfin/jellyfin:latest") is None, "empty RepoDigests -> unresolvable"

# TSV shape consumed by the launcher (5 columns incl. override).
rows = [{"service": "sonarr", "policy": "stable", "override": "default",
         "status": "Up to date", "updatable": False}]
assert m.format_status_tsv(rows) == "sonarr\tstable\tdefault\tUp to date\tfalse"
print("PYOK")
PY
)
rc=$?
assert_eq "0" "$rc" "image-drift status: python checks exit zero"
assert_contains "$status_out" "PYOK" "image-drift status: truth table + digest extraction pass"

# ---------------------------------------------------------------------------
# 3. mediastack launcher: apply/flip/reset behaviour
# ---------------------------------------------------------------------------
# The apply/flip helpers call the override.sh policy backend
# (_effective_channel / _service_policy), which the launcher itself sources only
# lazily inside submenu_manage_updates. These subshells invoke the helpers
# directly, so each sources override.sh alongside the launcher and points
# SCRIPT_DIR at a tmp dir holding a real config/state/image-policy.tsv.

# "Update all" applies every updatable service, excludes WireGuard (its own
# confirm path force-prompts), and skips non-updatable rows. It keys on the
# updatable flag ($5), never the status text.
wg_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  # Stub IO + the docker-touching apply AFTER sourcing (later defs win).
  APPLIED=""
  _apply_service_update(){ APPLIED+="$1 "; }
  ui_confirm(){ return 0; }
  ui_log(){ :; }
  launcher_pause_for_menu(){ :; }
  tsv=$(printf "jellyfin\tlatest\tmanual\tUpdate available\ttrue\nsonarr\tstable\tdefault\tUp to date\tfalse\nwireguard\tlatest\tmanual\tUpdate available\ttrue\n")
  _menu_update_all "$tsv"
  echo "APPLIED=[$APPLIED]"
' 2>&1)
assert_contains "$wg_out" "jellyfin" "update-all: applies updatable services"
if grep -q "wireguard" <<<"$wg_out"; then
    fail "update-all: WireGuard excluded from bulk update"
else
    pass "update-all: WireGuard excluded from bulk update"
fi
if grep -q "sonarr" <<<"$wg_out"; then
    fail "update-all: non-updatable services skipped"
else
    pass "update-all: non-updatable services skipped"
fi

# Apply floats a *pinned* service (effective channel stable) to its tag - writing
# a sticky latest policy row - and leaves an already-tracking service (effective
# latest) as-is (a plain pull, no policy change). The float decision is the
# service's real pin state, never the status text.
apply_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  docker(){ return 0; }
  pol(){ grep -v "^#" "$tmp/config/state/image-policy.tsv" 2>/dev/null | tr "\n\t" "  "; }

  IMAGE_CHANNEL=stable
  _apply_service_update sonarr                        # pinned -> floats to its tag
  echo "AFTER_PINNED=[$(pol)]"
  printf "radarr\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _apply_service_update radarr                        # already tracking tag -> plain pull
  echo "AFTER_TRACKING=[$(pol)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$apply_out" "AFTER_PINNED=[sonarr latest" "apply: a pinned service floats to its tag (writes latest)"
assert_contains "$apply_out" "AFTER_TRACKING=[radarr latest" "apply: an already-tracking service keeps its single latest row (plain pull)"

# Safety gate: floating a pinned service MUST confirm first. Decline (ui_confirm
# -> 1) writes no policy row and returns success; skip_confirm=1 (the bulk path)
# floats without prompting.
decline_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }
  ui_log(){ :; }; ui_confirm(){ return 1; }
  docker(){ return 0; }
  pol(){ grep -v "^#" "$tmp/config/state/image-policy.tsv" 2>/dev/null | tr "\n\t" "  "; }

  IMAGE_CHANNEL=stable
  _apply_service_update sonarr
  echo "DECLINE_RC=$?"
  echo "DECLINE_POLICY=[$(pol)]"
  # skip_confirm=1 ($2) bypasses the decline and floats even with ui_confirm -> 1.
  _apply_service_update radarr 1
  echo "SKIP_POLICY=[$(pol)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$decline_out" "DECLINE_RC=0" "apply: declined float returns success (no error)"
assert_contains "$decline_out" "DECLINE_POLICY=[]" "apply: declined float writes no policy row"
assert_contains "$decline_out" "SKIP_POLICY=[radarr" "apply: skip_confirm bypasses the prompt and floats anyway"

# WireGuard single-service float: its own "Update WireGuard now?" confirm already
# carries the off-baseline warning and gates the float, so the generic float
# branch must NOT re-prompt - exactly one confirm, and accepting still floats.
wg_float_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }
  N=0
  ui_log(){ :; }; ui_confirm(){ N=$((N+1)); return 0; }
  docker(){ return 0; }
  pol(){ grep -v "^#" "$tmp/config/state/image-policy.tsv" 2>/dev/null | tr "\n\t" "  "; }

  IMAGE_CHANNEL=stable
  _apply_service_update wireguard
  echo "WG_CONFIRMS=$N"
  echo "WG_POLICY=[$(pol)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$wg_float_out" "WG_CONFIRMS=1" "apply: single-service WireGuard float prompts once (no double-confirm)"
assert_contains "$wg_float_out" "WG_POLICY=[wireguard" "apply: accepted WireGuard float still floats to its tag"

# Reset-to-default lists only services with an *explicit* manual override, and
# never a Not-installed one (must not start uninstalled services).
reset_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_log(){ :; }
  launcher_pause_for_menu(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  _reset_service_to_default(){ echo "RESET:$1"; }
  # jellyfin: manual + installed; sonarr: no override (installed image); bazarr: manual but Not installed.
  tsv=$(printf "jellyfin\tlatest\tmanual\tUp to date\tfalse\nsonarr\tstable\tdefault\tUp to date\tfalse\nbazarr\tlatest\tmanual\tNot installed\tfalse\n")
  _menu_reset_default "$tsv"; echo "BACK_RC=$?"   # ui_choose stub returns Back -> no-op
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
' 2>&1)
assert_contains "$reset_out" "jellyfin" "reset: lists an installed manual override"
if grep -q "sonarr" <<<"$reset_out"; then
    fail "reset: excludes services with no override (still on their installed image)"
else
    pass "reset: excludes services with no override (still on their installed image)"
fi
if grep -q "bazarr" <<<"$reset_out"; then
    fail "reset: excludes Not-installed services (never starts them)"
else
    pass "reset: excludes Not-installed services (never starts them)"
fi
assert_contains "$reset_out" "BACK_RC=1" "reset: a no-op revert (Back) returns non-zero so the caller skips a rescan"
# _recreate_service must never start a stopped container: it pulls + stages, but
# only runs `up -d` when the service is already running.
guard_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  _wait_service_running(){ :; }
  ui_log(){ shift; echo "LOG:$*"; }
  _service_profile_flag(){ echo ""; }
  run_case(){
    CALLS=$(mktemp); RUNNING_STATE="$1"
    docker(){ echo "$*" >> "$CALLS"; [[ "$1" == "inspect" ]] && echo "$RUNNING_STATE"; return 0; }
    _recreate_service sonarr "done"
    echo "CASE_$1=[$(tr "\n" "|" < "$CALLS")]"
  }
  run_case false
  run_case true
' 2>&1)
cf=$(grep "CASE_false=" <<<"$guard_out")
ct=$(grep "CASE_true=" <<<"$guard_out")
if grep -q "up -d" <<<"$cf"; then
    fail "guard: stopped service is staged, not started"
else
    pass "guard: stopped service is staged, not started"
fi
if grep -q "up -d" <<<"$ct"; then
    pass "guard: running service is recreated"
else
    fail "guard: running service is recreated"
fi
assert_contains "$guard_out" "staged and applies next time" "guard: stopped update is staged with a message"
# shellcheck source=manage-updates/unhealthy-recreate.sh
source "$SCRIPT_DIR/manage-updates/unhealthy-recreate.sh"
# _mu_flip_row rewrites a just-updated service's row to "Up to date" locally so the
# Manage-Updates table reflects the action without a fresh registry scan. It re-reads
# the live policy file: a floated service now has a manual latest row (-> Tracking
# tag *); a plain-pull service keeps its columns. updatable clears; other rows pass
# through untouched and tabs are preserved.
flip_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  # (a) a floated service: the policy file records jackett=latest, so the flip reads
  #     it back as a manual override even though the pre-flip row said stable|default.
  printf "jackett\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  tsv=$(printf "jackett\tstable\tdefault\tUpdate available\ttrue\nradarr\tstable\tdefault\tUp to date\tfalse\n")
  echo "FLOAT=[$(_mu_flip_row "$tsv" jackett | grep ^jackett | tr "\t" "|")]"
  echo "PASS=[$(_mu_flip_row "$tsv" jackett | grep ^radarr | tr "\t" "|")]"
  # (b) no policy row (a plain-pull update on an already-tracking service): keep the
  #     existing pol/override columns, just mark Up to date.
  rm -f "$tmp/config/state/image-policy.tsv"
  tsvl=$(printf "jackett\tlatest\tdefault\tUpdate available\ttrue\n")
  echo "NOROW=[$(_mu_flip_row "$tsvl" jackett | grep ^jackett | tr "\t" "|")]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$flip_out" "FLOAT=[jackett|latest|manual|Up to date|false]" \
    "flip: a floated service reads its live latest policy -> manual, Up to date, cleared"
assert_contains "$flip_out" "PASS=[radarr|stable|default|Up to date|false]" \
    "flip: untargeted rows pass through unchanged (tabs preserved)"
assert_contains "$flip_out" "NOROW=[jackett|latest|default|Up to date|false]" \
    "flip: a plain-pull service keeps its columns, just marked Up to date"

# The table only flips a row green when the container is actually running the new
# image (running == upstream by construction). A staged (stopped) service and a
# pull-failure-cached recreate leave the OLD image in place, so neither is flipped.
gate_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  IMAGE_CHANNEL=latest                              # already tracking tag: plain pull, no float
  _recreate_service(){ _MU_PULL_OK=1; return 0; }   # pull succeeded
  _service_is_running(){ return 0; }                # running the new image
  _MU_APPLIED=(); _apply_service_update sonarr; echo "RUN=[${_MU_APPLIED[*]}]"
  _service_is_running(){ return 1; }                # stopped -> staged only
  _MU_APPLIED=(); _apply_service_update sonarr; echo "STAGED=[${_MU_APPLIED[*]}]"
  _recreate_service(){ _MU_PULL_OK=0; return 0; }   # pull failed, cached image
  _service_is_running(){ return 0; }
  _MU_APPLIED=(); _apply_service_update sonarr; echo "PULLFAIL=[${_MU_APPLIED[*]}]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$gate_out" "RUN=[sonarr]" "flip gate: running + fresh pull records the update"
assert_contains "$gate_out" "STAGED=[]" "flip gate: staged (stopped) service is not flipped green"
assert_contains "$gate_out" "PULLFAIL=[]" "flip gate: pull-failure-cached recreate is not flipped green"

# An update marks a service a manual 'latest' override on ANY channel - so on
# a Latest install (where an update otherwise writes no policy row) the service still
# becomes revertable to its installed image.
mark_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }; _service_is_running(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  docker(){ return 0; }
  pol(){ grep -v "^#" "$tmp/config/state/image-policy.tsv" 2>/dev/null | tr "\n\t" "  "; }
  IMAGE_CHANNEL=latest
  _apply_service_update sonarr                        # Latest install, default service
  echo "AFTER_LATEST=[$(pol)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$mark_out" "AFTER_LATEST=[sonarr latest" \
    "apply: a Latest-install update marks the service manual (revertable on any channel)"

# Updating a *pinned* (reverted) service floats it back to its tag - the pin is
# overwritten with a latest row, never left to silently no-op the update.
unpin_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }; _service_is_running(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  docker(){ return 0; }
  D="sha256:$(printf "a%.0s" {1..64})"
  IMAGE_CHANNEL=latest
  printf "sonarr\tlscr.io/linuxserver/sonarr:latest@%s\n" "$D" > "$tmp/config/state/image-policy.tsv"
  _apply_service_update sonarr                        # pinned -> must float, not no-op
  echo "AFTER_UNPIN=[$(grep -v ^# "$tmp/config/state/image-policy.tsv" | tr "\n\t" "  ")]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$unpin_out" "AFTER_UNPIN=[sonarr latest" \
    "apply: updating a pinned service clears the pin and floats to its tag"

# Revert re-pins a service to its recorded install digest on ANY channel, and
# the regenerated compose line emits that pinned image@digest.
revert_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }; _service_is_running(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  _recreate_service(){ _MU_PULL_OK=1; return 0; }
  D="sha256:$(printf "b%.0s" {1..64})"
  IMAGE_CHANNEL=latest                                # revert must work off the lock
  printf "radarr\tlscr.io/linuxserver/radarr:latest\t%s\n" "$D" > "$tmp/config/state/image-install.tsv"
  printf "radarr\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _reset_service_to_default radarr
  echo "PINROW=[$(grep ^radarr "$tmp/config/state/image-policy.tsv" | tr "\t" "|")]"
  echo "COMPOSE=[$(_compose_image_line radarr)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$revert_out" "PINROW=[radarr|lscr.io/linuxserver/radarr:latest@sha256:bbbb" \
    "revert: pins the service to its recorded install image@digest (any channel)"
assert_contains "$revert_out" "COMPOSE=[    image: lscr.io/linuxserver/radarr:latest@sha256:bbbb" \
    "revert: the regenerated compose line emits the install-digest pin"

# A revert whose recreate fails (e.g. install digest GC'd upstream) restores the
# prior policy row - never leaving a dead pin - and returns non-zero.
revfail_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }; _service_is_running(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  _recreate_service(){ _MU_PULL_OK=0; return 1; }     # every recreate fails
  D="sha256:$(printf "c%.0s" {1..64})"
  IMAGE_CHANNEL=latest
  printf "radarr\tlscr.io/linuxserver/radarr:latest\t%s\n" "$D" > "$tmp/config/state/image-install.tsv"
  printf "radarr\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _reset_service_to_default radarr; echo "RC=$?"
  echo "RESTORED=[$(grep ^radarr "$tmp/config/state/image-policy.tsv" | tr "\t" "|")]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$revfail_out" "RC=1" "revert-fail: returns non-zero"
assert_contains "$revfail_out" "RESTORED=[radarr|latest]" \
    "revert-fail: restores the prior policy row (no dead digest pin left behind)"

# Backward-compat: reverting a service with NO recorded install digest (an
# install that predates this feature - no image-install.tsv) falls back to clearing
# the override, never writing a pin it can't resolve.
compat_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  log_error(){ :; }
  source "$REPO_ROOT/scripts/setup/override.sh"
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }; _service_is_running(){ return 0; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  _recreate_service(){ _MU_PULL_OK=1; return 0; }
  IMAGE_CHANNEL=latest
  # No image-install.tsv on disk; radarr carries a manual latest override.
  printf "radarr\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _reset_service_to_default radarr; echo "RC=$?"
  echo "AFTER=[$(grep -c "^radarr" "$tmp/config/state/image-policy.tsv")]"   # 0 = row cleared
  rm -rf "$tmp"
' 2>&1)
assert_contains "$compat_out" "RC=0" "revert-compat: no install digest recorded -> succeeds"
assert_contains "$compat_out" "AFTER=[0]" \
    "revert-compat: falls back to clearing the override (no unresolvable pin written)"
# The status table renders a digest-pinned service as 'Pinned (install)' with no
# '*' (a pin is the opposite of "tracking its upstream tag"), while a floated row keeps
# its star. The POLICY column arrives already normalized to the 'pinned' token.
table_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tsv=$(printf "sonarr\tpinned\tmanual\tUpdate available\ttrue\nradarr\tlatest\tmanual\tUp to date\tfalse\n")
  _render_update_table "$tsv"
' 2>&1)
assert_contains "$table_out" "Pinned (install)" "table: a digest-pinned service reads 'Pinned (install)'"
if grep -q "Pinned (install) \*" <<<"$table_out"; then
    fail "table: a pinned row must not carry the manual-override star"
else
    pass "table: a pinned row must not carry the manual-override star"
fi
assert_contains "$table_out" "Tracking tag *" "table: a floated row still carries its star"
scenario_end "$CURRENT_SCENARIO"
summary

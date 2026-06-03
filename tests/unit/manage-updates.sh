#!/usr/bin/env bash
# Unit test - per-service image policy + update-status detection (ADR-30).
#
# Covers the three load-bearing pieces of the "Manage updates" feature without
# DinD/Docker/network:
#   1. override.sh per-service policy: floating one service drops only its digest
#      pin (compose tag preserved) while the rest stay pinned; mem/header intact.
#   2. image-drift.py status: the policy-branched truth table and the hardened
#      running-digest extraction (image-object RepoDigests, repo-matched).
#   3. mediastack launcher: "Update all" excludes WireGuard and non-updatable
#      services. The launcher is sourced (its BASH_SOURCE guard skips main()).
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
assert_contains "$ov_out" "MIXED_PINS=18"  "override: floating jellyfin leaves 18 of 19 pinned"
assert_contains "$ov_out" "JF=floats"      "override: floated service drops its digest pin"
assert_contains "$ov_out" "SONARR=pinned"  "override: other services stay pinned to the lock"
assert_contains "$ov_out" "MEMLINES=19"    "override: mem_limit preserved for every service"
assert_contains "$ov_out" "NOTE=ok"        "override: header records the per-service override"
assert_contains "$ov_out" "STABLE_PINS=19" "override: clearing the override re-pins all services"
assert_contains "$ov_out" "LATEST_PINS=0"  "override: global latest pins nothing"

# ---------------------------------------------------------------------------
# 2. image-drift.py status: truth table + hardened running-digest extraction
# ---------------------------------------------------------------------------
status_out=$(REPO_ROOT="$REPO_ROOT" python3 - <<'PY' 2>&1
import importlib.util, os, sys, json
path = os.path.join(os.environ["REPO_ROOT"], "scripts/image-drift.py")
spec = importlib.util.spec_from_file_location("idrift", path)
m = importlib.util.module_from_spec(spec); sys.modules["idrift"] = m; spec.loader.exec_module(m)

LOCK = "sha256:" + "a"*64
UP   = "sha256:" + "b"*64
OLD  = "sha256:" + "c"*64

# Policy-branched truth table (present flag separates absence from unknown digest).
assert m.derive_status("stable", False, None, UP, LOCK)        == ("Not installed", False)
assert m.derive_status("stable", True,  None, UP, LOCK)        == ("Unknown local digest", False)
assert m.derive_status("stable", True,  OLD, UP, LOCK)         == ("Tested Stable update available", True)
assert m.derive_status("stable", True,  LOCK, LOCK, LOCK)      == ("On tested Stable", False)
assert m.derive_status("stable", True,  LOCK, UP, LOCK)        == ("Untested upstream update available", True)
assert m.derive_status("stable", True,  LOCK, "unknown", LOCK) == ("On tested Stable", False)
assert m.derive_status("latest", True,  UP, UP, None)          == ("Up to date", False)
assert m.derive_status("latest", True,  OLD, UP, None)         == ("Upstream update available", True)
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
         "status": "On tested Stable", "updatable": False}]
assert m.format_status_tsv(rows) == "sonarr\tstable\tdefault\tOn tested Stable\tfalse"
print("PYOK")
PY
)
rc=$?
assert_eq "0" "$rc" "image-drift status: python checks exit zero"
assert_contains "$status_out" "PYOK" "image-drift status: truth table + digest extraction pass"

# ---------------------------------------------------------------------------
# 3. mediastack launcher: "Update all" excludes WireGuard + non-updatable
# ---------------------------------------------------------------------------
wg_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  # Stub IO + the docker-touching apply AFTER sourcing (later defs win).
  APPLIED=""
  _apply_service_update(){ APPLIED+="$1 "; }
  ui_confirm(){ return 0; }
  ui_log(){ :; }
  pause_for_menu(){ :; }
  tsv=$(printf "jellyfin\tlatest\tmanual\tUpstream update available\ttrue\nsonarr\tstable\tdefault\tOn tested Stable\tfalse\nwireguard\tlatest\tmanual\tUpstream update available\ttrue\n")
  _menu_update_all "$tsv"
  echo "APPLIED=[$APPLIED]"
' 2>&1)
assert_contains "$wg_out" "jellyfin"          "update-all: applies updatable services"
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

# Status-aware apply: an upstream update floats to latest (sticky), but a
# "Tested Stable update available" applies in-channel without floating.
apply_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state"
  IMAGE_CHANNEL=stable
  _regenerate_override(){ return 0; }
  storage_guard_before_start(){ return 0; }
  _wait_service_running(){ :; }
  ui_log(){ :; }; ui_confirm(){ return 0; }
  docker(){ return 0; }
  pol(){ grep -v "^#" "$tmp/config/state/image-policy.tsv" 2>/dev/null | tr "\n" " "; }

  _apply_service_update sonarr "Untested upstream update available"
  echo "AFTER_UPSTREAM=[$(pol)]"
  rm -f "$tmp/config/state/image-policy.tsv"
  _apply_service_update radarr "Tested Stable update available"
  echo "AFTER_TESTED=[$(pol)]"
  rm -rf "$tmp"
' 2>&1)
assert_contains "$apply_out" "AFTER_UPSTREAM=[sonarr" "apply: upstream update floats the service to Upstream tag"
assert_contains "$apply_out" "AFTER_TESTED=[]"        "apply: tested Stable update stays on Stable (no float)"

# Reset-to-default lists only services with an *explicit* manual override, and
# never a Not-installed one (Finding 1: must not start uninstalled services).
reset_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_log(){ :; }
  pause_for_menu(){ :; }
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
  _reset_service_to_default(){ echo "RESET:$1"; }
  # jellyfin: manual + installed; sonarr: inherited default; bazarr: manual but Not installed.
  tsv=$(printf "jellyfin\tlatest\tmanual\tUp to date\tfalse\nsonarr\tstable\tdefault\tOn tested Stable\tfalse\nbazarr\tlatest\tmanual\tNot installed\tfalse\n")
  _menu_reset_default "$tsv"
  echo "LABELS=[$(tr "\n" "|" < "$LABELS")]"
' 2>&1)
assert_contains "$reset_out" "jellyfin" "reset: lists an installed manual override"
if grep -q "sonarr" <<<"$reset_out"; then
    fail "reset: excludes services merely inheriting the default channel"
else
    pass "reset: excludes services merely inheriting the default channel"
fi
if grep -q "bazarr" <<<"$reset_out"; then
    fail "reset: excludes Not-installed services (never starts them)"
else
    pass "reset: excludes Not-installed services (never starts them)"
fi

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

scenario_end "$CURRENT_SCENARIO"
summary

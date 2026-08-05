#!/usr/bin/env bash
# Probe configured services on a lan-host target. Reads API keys from the target's
# .env (remotely), so it works after either a Mode A or Mode B install.
# Mirrors the probe blocks documented in tests/lan-host/README.md.
#
# usage: probe-services.sh [--service NAME] [--nvidia-autoheal]
#   NAME in: containers fail2ban sonarr radarr jackett qbittorrent channel bazarr quality indexers gpu
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

SERVICE="" NV_AUTOHEAL=0
while (($#)); do
    case "$1" in
        --service)
            SERVICE="${2:-}"
            shift
            ;;
        --service=*) SERVICE="${1#*=}" ;;
        --nvidia-autoheal) NV_AUTOHEAL=1 ;;
        -h | --help)
            echo "usage: probe-services.sh [--service NAME] [--nvidia-autoheal]"
            exit 0
            ;;
        *) die "unknown arg: $1" ;;
    esac
    shift
done

# Validate --service against the known set so a typo (e.g. `--service sonar`) fails loudly
# instead of silently matching no `want` check and reporting "passed". Keep in sync with the
# `want NAME` checks in the remote script below.
KNOWN_SERVICES="containers fail2ban sonarr radarr jackett qbittorrent channel bazarr smb quality indexers gpu health"
if [[ -n "$SERVICE" ]] && [[ " $KNOWN_SERVICES " != *" $SERVICE "* ]]; then
    die "unknown --service '$SERVICE' (known: $KNOWN_SERVICES)"
fi

load_env
RP=$(shq "$TARGET_PATH")

step "Container health + service probes${SERVICE:+ (service=$SERVICE)}"
# Run the checks on the box so we can source its .env for API keys and hit
# localhost. The remote script prints its own ✓/✗ lines and exits non-zero on
# any failure; we record one local pass/fail in FAILS[].
if ssh -o StrictHostKeyChecking=no "$SSH_DEST" "TARGET_PATH=$RP SERVICE=$(shq "$SERVICE") LANHOST_REMOTE=$LANHOST_REMOTE LANHOST_INDEXERS=$LANHOST_INDEXERS LANHOST_GPU=$(shq "$LANHOST_GPU") LANHOST_CHANNEL=$(shq "$LANHOST_CHANNEL") LANHOST_QUALITY=$(shq "$LANHOST_QUALITY") LANHOST_BAZARR=$(shq "$LANHOST_BAZARR") LANHOST_SMB=$(shq "$LANHOST_SMB") bash -s" <<'REMOTE'; then
set -uo pipefail
cd "$TARGET_PATH"
[ -f ./.env ] && . ./.env || true
fail=0
want() { [ -z "${SERVICE:-}" ] || [ "$SERVICE" = "$1" ]; }

if want containers; then
  # Tight + mode-agnostic: assert EVERY compose-managed container is running and none unhealthy,
  # plus a sane minimum exist (the stack actually came up). A service that never started shows as
  # created/exited here, so `running != total` catches it — a fixed count floor would not (the
  # real count is 13-14 with autoheal). Derived from the active-profile set the install wrote, so
  # it tracks bazarr/autoheal/remote automatically. compose ps | wc/grep read all input (no
  # SIGPIPE); we are already `cd $TARGET_PATH` so compose finds the project.
  total=$(docker compose ps -aq 2>/dev/null | wc -l | tr -dc 0-9)
  running=$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -dc 0-9)
  unhealthy=$(docker compose ps -a --format '{{.Health}}' 2>/dev/null | grep -c unhealthy || true)
  if [ "${total:-0}" -lt 12 ]; then
    echo "  ✗ only ${total:-0} compose containers exist (stack did not come up)"; fail=1
  elif [ "${running:-0}" != "${total:-0}" ]; then
    echo "  ✗ ${running:-0}/${total} compose containers running (a service never started or exited)"; fail=1
  elif [ "${unhealthy:-0}" -gt 0 ]; then
    echo "  ✗ ${unhealthy} container(s) unhealthy"; fail=1
  else
    echo "  ✓ ${running}/${total} compose containers running, none unhealthy"
  fi
fi

if want fail2ban; then
  # fail2ban is profile-gated — it deploys only with the remote/NPM path, so in a LAN
  # baseline it isn't running. Only assert it when remote is enabled (or it was
  # explicitly requested via --service fail2ban).
  if [ "${LANHOST_REMOTE:-0}" = 1 ] || [ "${SERVICE:-}" = fail2ban ]; then
    jails=$(docker exec fail2ban fail2ban-client status 2>/dev/null | grep 'Number of jail' | tr -d '\r' || true)
    # 3 active jails by default (jellyfin/npm/seerr); npm-ratelimit ships disabled (ADR-35).
    case "$jails" in *3*) echo "  ✓ fail2ban: $jails" ;; *) echo "  ✗ fail2ban: ${jails:-unreachable}"; fail=1 ;; esac
  else
    echo "  ↷ fail2ban skipped (LAN baseline; deploys with --remote)"
  fi
fi

check_api() {  # name url [header]
  local name="$1" url="$2" code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url" ${3:+-H "$3"} 2>/dev/null || echo 000)
  if [ "$code" = 200 ]; then echo "  ✓ $name API ($code)"; else echo "  ✗ $name API ($code)"; fail=1; fi
}
want sonarr  && check_api sonarr  "http://localhost:8989/api/v3/system/status" "X-Api-Key: ${SONARR_API_KEY:-}"
want radarr  && check_api radarr  "http://localhost:7878/api/v3/system/status" "X-Api-Key: ${RADARR_API_KEY:-}"
if want jackett; then
  # Only meaningful when the public-indexer preset is enabled. Gate on the indexers toggle.
  if [ "${LANHOST_INDEXERS:-0}" = 1 ] || [ "${SERVICE:-}" = jackett ]; then
    # Jackett's API key lives in config/jackett/Jackett/ServerConfig.json, NOT .env, so read it
    # via the PRODUCT's own api_get_jackett_key (needs SCRIPT_DIR), then probe the apikey-authed
    # Torznab caps endpoint exactly like tests/assertions/jackett.sh. The old check hit
    # /api/v2.0/server/config with ${JACKETT_API_KEY} (always empty) — that's a session/UI route
    # that 302-redirects regardless of key, a false failure even though indexers work end-to-end.
    jkey=$(SCRIPT_DIR="$TARGET_PATH" bash -c 'source scripts/lib/common.sh 2>/dev/null && api_get_jackett_key' 2>/dev/null)
    if [ -n "$jkey" ] && [ "${#jkey}" -ge 20 ]; then
      # Capture then scan: piping into `grep -q` would SIGPIPE curl and flip the result non-zero
      # under pipefail even on a match (false failure). See feedback_sigpipe_pipefail_flake.
      caps=$(curl -sf --max-time 15 "http://localhost:9117/api/v2.0/indexers/all/results/torznab/?apikey=${jkey}&t=caps" 2>/dev/null)
      case "$caps" in
        *'<caps>'*) echo "  ✓ jackett serves Torznab caps (apikey-authed, via api_get_jackett_key)" ;;
        *)          echo "  ✗ jackett Torznab caps not served (key len ${#jkey}; Jackett API unreachable/unauthed)"; fail=1 ;;
      esac
    else
      echo "  ✗ jackett API key missing/short via api_get_jackett_key (len ${#jkey}; expected ≥20 with indexers enabled)"; fail=1
    fi
  else
    echo "  ↷ jackett skipped (public indexers disabled)"
  fi
fi

if want indexers; then
  # Read back the applied indexers axis: PUBLIC_INDEXERS_ENABLED in .env, plus live proof
  # (mirrors tests/assertions/sonarr.sh:105) that — when enabled — the running Sonarr actually
  # has ≥1 indexer wired from Jackett, not just the config flag flipped.
  pie=$(grep -m1 '^PUBLIC_INDEXERS_ENABLED=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
  exp=$([ "${LANHOST_INDEXERS:-0}" = 1 ] && echo true || echo false)
  if [ "$pie" = "$exp" ]; then echo "  ✓ PUBLIC_INDEXERS_ENABLED=$pie"; else echo "  ✗ PUBLIC_INDEXERS_ENABLED=${pie:-unset} (expected $exp)"; fail=1; fi
  if [ "$exp" = true ] && [ -n "${SONARR_API_KEY:-}" ]; then
    n=$(curl -sf -m 5 -H "X-Api-Key: ${SONARR_API_KEY}" http://localhost:8989/api/v3/indexer 2>/dev/null \
      | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)" 2>/dev/null)
    if [ "${n:-0}" -ge 1 ]; then echo "  ✓ Sonarr has $n live indexer(s) wired"; else echo "  ✗ Sonarr live indexer count=${n:-0} (expected ≥1 with indexers enabled)"; fail=1; fi
  fi
fi

if want qbittorrent; then
  # MediaStack runs qBittorrent with localhost/subnet auth bypassed (LocalHostAuth=false,
  # AuthSubnetWhitelist=172.16.0.0/12), so /auth/login returns an empty body (nothing to
  # authenticate) while authed endpoints answer directly. Probe an authed endpoint.
  ver=$(curl -s -m 5 http://localhost:8080/api/v2/app/version 2>/dev/null || true)
  case "$ver" in v[0-9]*) echo "  ✓ qbittorrent WebUI ($ver)" ;; *) echo "  ✗ qbittorrent WebUI (${ver:-no response})"; fail=1 ;; esac
fi

# --- Applied-choice assertions. A green "containers up" doesn't prove the wizard actually
# applied the matrix axes (channel/quality/bazarr); read back what it persisted and compare
# to the toggles. These also hold for the DEMO baseline (stable/balanced/bazarr-off), so they
# strengthen it too.
if want channel; then
  ch=$(grep -m1 '^IMAGE_CHANNEL=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
  if [ "$ch" = "${LANHOST_CHANNEL:-stable}" ]; then echo "  ✓ IMAGE_CHANNEL=$ch"; else echo "  ✗ IMAGE_CHANNEL=${ch:-unset} (expected ${LANHOST_CHANNEL:-stable})"; fail=1; fi
fi

if want bazarr; then
  be=$(grep -m1 '^BAZARR_ENABLED=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
  exp=$([ "${LANHOST_BAZARR:-0}" = 1 ] && echo true || echo false)
  if [ "$be" = "$exp" ]; then echo "  ✓ BAZARR_ENABLED=$be"; else echo "  ✗ BAZARR_ENABLED=${be:-unset} (expected $exp)"; fail=1; fi
  if [ "$exp" = true ]; then
    # Capture then scan: piping `docker ps` into `grep -qx` would let grep close the pipe on a
    # match, hand docker SIGPIPE, and (under set -o pipefail) flip the result non-zero EVEN WHEN
    # bazarr is running — a false failure. See feedback_sigpipe_pipefail_flake.
    names=$(docker ps --format '{{.Names}}')
    if grep -qx bazarr <<<"$names"; then echo "  ✓ bazarr container running (subtitles profile)"; else echo "  ✗ bazarr container not running (BAZARR_ENABLED=true)"; fail=1; fi
  fi
fi

if want smb; then
  # SMB is a HOST-level samba service (apt 'samba' + /etc/samba/smb.conf.d/mediastack.conf
  # via hardening.sh:setup_samba), NOT a compose container — so probe the host, not docker.
  # Read back the applied toggle (like channel/bazarr), and when enabled prove smbd is
  # actually serving the MediaStack [Media] share.
  se=$(grep -m1 '^SMB_ENABLED=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
  exp=$([ "${LANHOST_SMB:-0}" = 1 ] && echo true || echo false)
  if [ "$se" = "$exp" ]; then echo "  ✓ SMB_ENABLED=$se"; else echo "  ✗ SMB_ENABLED=${se:-unset} (expected $exp)"; fail=1; fi
  if [ "$exp" = true ]; then
    sc=$(grep -m1 '^SMB_SHARE_SCOPE=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
    [ "$sc" = data ] && echo "  ✓ SMB_SHARE_SCOPE=data" || { echo "  ✗ SMB_SHARE_SCOPE=${sc:-unset} (expected data)"; fail=1; }
    # smbd actually running as a host service (setup_samba does `systemctl enable --now smbd`).
    act=$(systemctl is-active smbd 2>/dev/null || true)
    [ "$act" = active ] && echo "  ✓ smbd host service active" || { echo "  ✗ smbd host service ${act:-inactive}"; fail=1; }
    # Prove MediaStack configured AND WIRED its own [Media] share, by asserting the
    # MediaStack-managed include FILE (hardening.sh:SAMBA_INCLUDE_FILE) + the include line in
    # main smb.conf. This is unambiguous even when the host already has a [Media] share defined
    # elsewhere (a merged-effective `testparm` grep would pass spuriously on that pre-existing
    # share); the managed include file is written ONLY by setup_samba. Data scope ⇒ [Media] at
    # DATA_DIR with 3-space-indented `   path = …` (hardening.sh heredoc). grep -Fxq = fixed,
    # whole-line, quiet — no SIGPIPE (grep reads stdin from a file, not a pipe).
    ddir=$(grep -m1 '^DATA_DIR=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'"); : "${ddir:=/data}"
    inc=/etc/samba/smb.conf.d/mediastack.conf
    if sudo test -f "$inc" \
       && sudo grep -Fxq '[Media]' "$inc" 2>/dev/null \
       && sudo grep -Fxq "   path = ${ddir}" "$inc" 2>/dev/null; then
      echo "  ✓ MediaStack samba include defines [Media] at ${ddir}"
    else
      echo "  ✗ MediaStack samba include missing/incomplete ($inc)"; fail=1
    fi
    if sudo grep -Fq '# MEDIASTACK include' /etc/samba/smb.conf 2>/dev/null; then
      echo "  ✓ MediaStack include wired into main smb.conf"
    else
      echo "  ✗ MediaStack include not wired into main smb.conf (orphan share)"; fail=1
    fi
  fi
fi

if want quality; then
  # Compose the EXPECTED profile name from presets.yml the way the product does
  # ("{resolution} {size}") — no hardcoded name map to drift from — and assert
  # config.yml's applied quality_profile.name matches the chosen cell.
  q=$(python3 - "${LANHOST_QUALITY:-1080p-balanced}" <<'PY' 2>/dev/null
import sys, yaml
token = sys.argv[1]
res_key, _, size_key = token.partition("-")
def pick(path, *keys):
    try:
        d = yaml.safe_load(open(path)) or {}
        for k in keys:
            d = (d or {}).get(k, {}) if isinstance(d, dict) else {}
        return d if isinstance(d, str) else ""
    except Exception:
        return ""
res_disp  = pick("scripts/setup/presets.yml", "resolutions", res_key, "display_name")
size_disp = pick("scripts/setup/presets.yml", "sizes", size_key, "display_name")
want = (res_disp + " " + size_disp) if res_disp and size_disp else ""
got  = pick("config.yml", "quality_profile", "name")
print(("match" if want and want == got else "MISMATCH") + "|" + want + "|" + got)
PY
)
  status=${q%%|*}; rest=${q#*|}; want_name=${rest%%|*}; got_name=${rest#*|}
  if [ "$status" = match ]; then
    echo "  ✓ quality cell '${LANHOST_QUALITY:-1080p-balanced}' applied (profile '$got_name')"
  else
    echo "  ✗ quality cell '${LANHOST_QUALITY:-1080p-balanced}': expected profile '${want_name:-?}', config.yml has '${got_name:-?}'"; fail=1
  fi
  # Live proof (mirrors tests/assertions/sonarr.sh:41): the running Sonarr actually exposes the
  # chosen profile, not just config.yml. Skips cleanly if Sonarr has no API key yet.
  if [ -n "$want_name" ] && [ -n "${SONARR_API_KEY:-}" ]; then
    has=$(curl -sf -m 5 -H "X-Api-Key: ${SONARR_API_KEY}" http://localhost:8989/api/v3/qualityprofile 2>/dev/null \
      | python3 -c "import sys,json
try: ps=json.load(sys.stdin)
except Exception: ps=[]
print('yes' if any(p.get('name')==sys.argv[1] for p in ps) else 'no')" "$want_name" 2>/dev/null)
    case "$has" in
      yes) echo "  ✓ Sonarr exposes live quality profile '$want_name'" ;;
      no)  echo "  ✗ Sonarr missing live quality profile '$want_name' (config.yml said '$got_name')"; fail=1 ;;
      *)   echo "  ↷ Sonarr quality-profile probe skipped (no API response)" ;;
    esac
  fi
fi

# GPU passthrough — only when a GPU mode was installed. Proves the override wired the
# device through and the jellyfin container can actually see it (the real-silicon proof
# DinD and a GPU-less cloud VM can't give).
if want gpu && [ "${LANHOST_GPU:-none}" != none ]; then
  case "$LANHOST_GPU" in
    nvidia*)
      g=$(grep -m1 '^JELLYFIN_GPU='       .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
      st=$(grep -m1 '^STAGE_3_GPU_STATE='  .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
      md=$(grep -m1 '^NVIDIA_DRIVER_MODE=' .env 2>/dev/null | cut -d= -f2 | tr -d "\"'")
      # Expected driver mode = the persona's GPU minus the 'nvidia-' prefix (existing|standard|
      # unlock) — the product writes that into NVIDIA_DRIVER_MODE. Asserting it stops
      # nvidia-existing and nvidia-standard being conflated when both just reach 'complete'.
      exp_md=${LANHOST_GPU#nvidia-}
      [ "$g"  = nvidia ]      && echo "  ✓ JELLYFIN_GPU=nvidia"                  || { echo "  ✗ JELLYFIN_GPU=${g:-unset}"; fail=1; }
      [ "$st" = complete ]    && echo "  ✓ STAGE_3_GPU_STATE=complete"           || { echo "  ✗ STAGE_3_GPU_STATE=${st:-unset}"; fail=1; }
      [ "$md" = "$exp_md" ]   && echo "  ✓ NVIDIA_DRIVER_MODE=$md (matches $LANHOST_GPU)" || { echo "  ✗ NVIDIA_DRIVER_MODE=${md:-unset} (expected $exp_md for $LANHOST_GPU)"; fail=1; }
      # Capture then take the first line — piping nvidia-smi into `head -1` would close the pipe
      # early, hand nvidia-smi SIGPIPE, and (under set -o pipefail) flip the substitution non-zero
      # even on success, falsely failing the single most important GPU-passthrough assertion.
      smi_out=$(docker exec jellyfin nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null); smi_rc=$?
      name=${smi_out%%$'\n'*}
      if [ "$smi_rc" = 0 ] && [ -n "$name" ]; then
        echo "  ✓ jellyfin sees GPU via nvidia-smi: $name"
      else
        echo "  ✗ jellyfin nvidia-smi failed (GPU not passed into the container)"; fail=1
      fi
      ;;
    *) echo "  ↷ GPU probe for '$LANHOST_GPU' not implemented yet" ;;
  esac
fi

if want health; then
  # Day-2 health-check library — READ-ONLY checks only (disk / firewall). The
  # active-probe fail2ban regex check writes a benign login, so it is exercised by
  # the DinD fresh-install scenario (assert_fail2ban_configured), not in this
  # read-only probe. Run in a subshell so health.sh's defs don't leak.
  ( . scripts/lib/health.sh 2>/dev/null; hf=0
    for chk in health_disk_pct health_ufw_active health_docker_user_restrict; do
      v=$($chk); st=${v%%|*}; msg=${v#*|}
      case "$st" in
        ok)   echo "  ✓ $msg" ;;
        warn) echo "  ! $msg" ;;
        skip) echo "  ↷ $msg" ;;
        *)    echo "  ✗ ${msg:-$chk failed}"; hf=1 ;;
      esac
    done; exit $hf ) || fail=1
fi

exit "$fail"
REMOTE
    ok "service probes passed"
else
    bad "service probes reported failures"
fi

if ((NV_AUTOHEAL)); then
    step "NVIDIA healthcheck + autoheal probe (up to ~12 min; does not break the host driver)"
    # Shim a failing nvidia-smi inside Jellyfin, confirm the healthcheck trips and
    # autoheal stop/starts the container (PID changes), then recovers. Expected:
    # healthy -> unhealthy -> PID change -> healthy, final nvidia-smi succeeds.
    if ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no "$SSH_DEST" bash -s <<'REMOTE'; then
set -uo pipefail
before_pid=$(docker inspect jellyfin --format '{{.State.Pid}}')
printf '%s\n' '#!/bin/sh' \
  'if [ -f /tmp/force-nvidia-smi-fail ]; then echo "simulated stale NVIDIA runtime" >&2; exit 255; fi' \
  'exec /usr/bin/nvidia-smi "$@"' \
  | docker exec -i jellyfin sh -c 'cat > /usr/local/bin/nvidia-smi && chmod +x /usr/local/bin/nvidia-smi'
docker exec jellyfin touch /tmp/force-nvidia-smi-fail
removed=0
for i in $(seq 1 72); do
  health=$(docker inspect jellyfin --format '{{.State.Health.Status}}')
  pid=$(docker inspect jellyfin --format '{{.State.Pid}}')
  echo "  t=$((i*10))s health=$health pid=$pid"
  if [ "$pid" != "$before_pid" ] && [ "$removed" = 0 ]; then
    docker exec jellyfin rm -f /tmp/force-nvidia-smi-fail
    removed=1
  fi
  if [ "$removed" = 1 ] && [ "$health" = healthy ]; then
    docker exec jellyfin sh -c 'rm -f /usr/local/bin/nvidia-smi /tmp/force-nvidia-smi-fail'
    docker exec jellyfin nvidia-smi >/dev/null
    echo "  recovered"
    exit 0
  fi
  sleep 10
done
docker exec jellyfin sh -c 'rm -f /usr/local/bin/nvidia-smi /tmp/force-nvidia-smi-fail' 2>/dev/null || true
exit 1
REMOTE
        ok "NVIDIA autoheal recovered (healthcheck tripped, container stop/started, nvidia-smi ok)"
    else
        bad "NVIDIA autoheal probe did not recover within the timeout"
    fi
fi

summary "LAN-HOST PROBE"

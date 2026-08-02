#!/usr/bin/env python3
"""Emit the wizard_pty.py steps-JSON for a full live `setup.sh --full` run, composed
from the LANHOST_* choice-matrix toggles.

The lan-host harness drives the REAL, un-stubbed wizard (all stages co-located on the
target), so this composes Stage 1 (parameterised by the toggles) + the Stage 2 offer
(skipped — remote is the GCP harness's job) + Stage 3 (skipped, or the GPU path).

Prompt regexes come from the shared SSOT (`tests/lib/wizard_prompts.json`) that the DinD
`wizard-ui-*` scenarios also build from, so this generator and those scenarios track the
real stage{1,2,3}.sh wizard from one place. wizard_pty.py's per-step expect-timeout turns
any prompt drift into a loud failure (exit 124) instead of a silent desync (F-001).

Reads toggles from the environment; writes the JSON array to stdout. Exits non-zero
(with a message on stderr) for combinations the LAN live-drive does not support.
"""

from __future__ import annotations

import json
import os
import sys


def env(name: str, default: str) -> str:
    value = os.environ.get(name, "")
    return value if value else default


# Prompt regexes come from the shared SSOT (tests/lib/wizard_prompts.json), so this
# generator and the DinD wizard-ui-* scenarios both track the real wizard from ONE place
# (no silent drift — the F-001 failure class).
_PROMPTS_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "wizard_prompts.json"
)
try:
    with open(_PROMPTS_PATH) as _f:
        P = json.load(_f)["prompts"]
except (OSError, KeyError, ValueError) as _exc:
    sys.exit(f"wizard-steps: cannot load shared prompts from {_PROMPTS_PATH}: {_exc}")


GPU = env("LANHOST_GPU", "none")
INDEXERS = env("LANHOST_INDEXERS", "0")
CHANNEL = env("LANHOST_CHANNEL", "stable")
QUALITY = env("LANHOST_QUALITY", "1080p-balanced")
BAZARR = env("LANHOST_BAZARR", "0")
SMB = env("LANHOST_SMB", "0")
REMOTE = env("LANHOST_REMOTE", "0")
EMAIL = env("LANHOST_ADMIN_EMAIL", "admin@lan.test")

# Timeouts (seconds). The first wizard prompt follows prereq install + OS hardening;
# the Stage 3 (transcoding) offer follows the full Stage 1 install (image pulls +
# healthchecks); the Stage 2 offer follows Stage 3; DRIVER covers the apt + dkms driver
# build in the from-scratch nvidia-standard path (slow on old silicon). UNLOCK is wider:
# the Unlock .run path downloads a ~200MB installer and (when nouveau unloads pre-reboot)
# compiles the kernel module before the next prompt — heavier than the apt build.
DETECT, STEP, INSTALL, POST, DRIVER, UNLOCK = 900, 60, 900, 300, 1200, 1800

# Menu orderings, confirmed against scripts/setup/stages/stage1.sh and the shared
# two-axis picker scripts/lib/quality_select.sh. LANHOST_QUALITY is a combined
# "<resolution>-<size>" token (e.g. 1080p-balanced); the two prompts are walked
# in order (resolution, then size).
RESOLUTION_CHOICE = {"720p": "1", "1080p": "2"}
SIZE_CHOICE = {"compact": "1", "balanced": "2", "large": "3"}
CHANNEL_CHOICE = {"stable": "1", "latest": "2"}


def die(msg: str) -> None:
    sys.exit(f"wizard-steps: {msg}")


def yn(flag: str) -> str:
    return "y\n" if flag == "1" else "\n"


if REMOTE == "1":
    die(
        "LANHOST_REMOTE=1 is not supported on the LAN live-drive — a home LAN collides "
        "with the existing stack/reverse-proxy. Remote/WAN proof is the GCP harness's "
        "job (tests/gcp-vm/). See tests/lan-host/README.md."
    )
try:
    Q_RES, Q_SIZE = QUALITY.split("-", 1)
except ValueError:
    die(f"invalid LANHOST_QUALITY={QUALITY!r} (want <resolution>-<size>, e.g. 1080p-balanced)")
if Q_RES not in RESOLUTION_CHOICE or Q_SIZE not in SIZE_CHOICE:
    die(
        f"invalid LANHOST_QUALITY={QUALITY!r} "
        f"(resolution {list(RESOLUTION_CHOICE)}, size {list(SIZE_CHOICE)})"
    )
if CHANNEL not in CHANNEL_CHOICE:
    die(f"invalid LANHOST_CHANNEL={CHANNEL!r}")

# --- Stage 1 (real prompts; see tests/scenarios/wizard-ui-stage1-local.sh) ----------
steps: list[dict] = [
    {"expect": P["stage1_continue_detected"], "send": "1\n", "timeout": DETECT},
    {"expect": P["stage1_admin_username"], "send": "\n", "timeout": STEP},
    {"expect": P["stage1_admin_email"], "send": EMAIL + "\n", "timeout": STEP},
    {"expect": P["stage1_admin_password"], "send": "WizardAdminPw123\n", "timeout": STEP},
    {
        "expect": P["stage1_admin_confirm"],
        "send": "1\n",
        "timeout": STEP,
    },  # ui_choose: "Use these details"
    {"expect": P["stage1_storage_location"], "send": "1\n", "timeout": STEP},
    {
        "expect": P["stage1_data_directory"],
        "send": "\n",
        "timeout": STEP,
    },  # accept the /data default
    {
        "expect": P["stage1_storage_confirm"],
        "send": "1\n",
        "timeout": STEP,
    },  # "Use these storage choices?" -> accept
]

# Subtitles (Bazarr) section: enable toggle, then (only when enabled) the language list,
# then the section confirm. Languages are gated on _WIZ_BAZARR_ENABLED (#100), so with
# Bazarr off (the LANHOST_BAZARR=0 default) the wizard skips straight to the confirm — the
# step must be conditional or the `expect` blocks and times out.
steps.append({"expect": P["stage1_bazarr"], "send": yn(BAZARR), "timeout": STEP})
if BAZARR == "1":
    steps.append({"expect": P["stage1_subtitle_langs"], "send": "\n", "timeout": STEP})
steps.append({"expect": P["stage1_subtitle_confirm"], "send": "1\n", "timeout": STEP})

# File sharing (SMB) section. Enable → 'y' then the data-only scope (ui_choose option 1:
# "Media files only (…) — Recommended"); the share lands at DATA_DIR. Disable → a single
# ENTER accepts the "no" default. Then the section confirm. The port-conflict prompt
# (stage1_smb_port_conflict) is NOT included: validate_smb_port(445) returns success when
# the port is free (first run) OR already owned by MediaStack's own smbd (re-run), so the
# scope prompt — not the conflict menu — always follows the 'y' here. See
# tests/scenarios/wizard-ui-stage1-smb-retry.sh for the conflict-path coverage (DinD).
if SMB == "1":
    steps += [
        {"expect": P["stage1_smb"], "send": "y\n", "timeout": STEP},
        {"expect": P["stage1_smb_scope"], "send": "1\n", "timeout": STEP},
    ]
else:
    steps.append({"expect": P["stage1_smb"], "send": "\n", "timeout": STEP})
steps.append({"expect": P["stage1_smb_confirm"], "send": "1\n", "timeout": STEP})

steps += [
    # Library quality section.
    {
        "expect": P["stage1_quality_resolution"],
        "send": RESOLUTION_CHOICE[Q_RES] + "\n",
        "timeout": STEP,
    },
    {"expect": P["stage1_quality_size"], "send": SIZE_CHOICE[Q_SIZE] + "\n", "timeout": STEP},
    {
        "expect": P["stage1_quality_confirm"],
        "send": "1\n",
        "timeout": STEP,
    },  # "Use these library choices?" -> accept
    # Search indexers section.
    {"expect": P["stage1_indexers"], "send": yn(INDEXERS), "timeout": STEP},
    {
        "expect": P["stage1_indexers_confirm"],
        "send": "1\n",
        "timeout": STEP,
    },  # "Use this indexer choice?" -> accept
    {"expect": P["stage1_image_channel"], "send": CHANNEL_CHOICE[CHANNEL] + "\n", "timeout": STEP},
    {"expect": P["stage1_qbt_download"], "send": "\n", "timeout": STEP},
    {"expect": P["stage1_qbt_upload"], "send": "\n", "timeout": STEP},
    {"expect": P["stage1_qbt_port"], "send": "\n", "timeout": STEP},
    {
        "expect": P["stage1_qbit_confirm"],
        "send": "1\n",
        "timeout": STEP,
    },  # "Use these qBittorrent settings?" -> accept
    # Security section (added with the UFW/hardening opt-in) — accept the recommended defaults.
    {"expect": P["stage1_security_ufw"], "send": "\n", "timeout": STEP},
    {"expect": P["stage1_security_hardening"], "send": "\n", "timeout": STEP},
    {"expect": P["stage1_proceed"], "send": "1\n", "timeout": STEP},
]

# Stage order matters: wizard.sh runs run_stage1 -> run_hardware_transcoding_addon
# (Stage 3) -> run_stage2 (Stage 2). So the *transcoding* offer is the first prompt
# after the long Stage 1 install (hence the INSTALL timeout), and the *remote* offer
# comes after Stage 3 — not the other way around.

# --- Stage 3 (transcoding) + Stage 2 (remote). Real flow (wizard.sh:167-181): stage1 ->
# transcoding addon (Stage 3) -> stage2 (Stage 2 offer) -> if a driver reboot is pending,
# an end-of-wizard "Reboot now?" prompt. The target has a real GPU, so the transcoding
# offer always appears. Each branch emits its own Stage 2 (remote) step.
TRANSCODE = P["transcode_offer"]
DRIVER_Q = P["driver_mode"]
REMOTE_Q = P["remote_offer"]

if GPU == "none":
    steps.append({"expect": TRANSCODE, "send": "2\n", "timeout": INSTALL})  # skip GPU
    steps.append({"expect": REMOTE_Q, "send": "2\n", "timeout": POST})  # skip remote
elif GPU == "nvidia-existing":
    # Pre-installed (.run) driver: choosing Standard makes the apt path report a foreign
    # driver and the wizard offers to use it as-is (no reboot needed).
    steps += [
        {"expect": TRANSCODE, "send": "1\n", "timeout": INSTALL},
        {"expect": DRIVER_Q, "send": "1\n", "timeout": STEP},
        {"expect": P["use_existing"], "send": "1\n", "timeout": STEP},
        {"expect": REMOTE_Q, "send": "2\n", "timeout": POST},
    ]
elif GPU == "nvidia-standard":
    # Fresh apt driver install (run after a --nvidia wipe removed any driver): Standard ->
    # [apt + dkms build, slow] -> Stage 2 offer -> OPTIONAL end-of-wizard "Reboot now?". The
    # Stage 2 offer is the prompt that follows the build, so it carries the DRIVER timeout.
    # The reboot prompt is optional because Stage 3 shows it only when a reboot is actually
    # needed (stage3_reboot_prompt_needed): when the freshly-installed driver loads + verifies
    # LIVE (nvidia-smi works right after apt — e.g. the GPU was warm from a prior cell), Stage
    # 3 finalizes in-line and skips the prompt. We answer reboot-later when it appears;
    # run-fresh.sh then either reboots+finalizes (marker) or accepts the in-line finalize
    # (STAGE_3_GPU_STATE=complete). Either way the GPU is validated by the step-4 probe.
    steps += [
        {"expect": TRANSCODE, "send": "1\n", "timeout": INSTALL},
        {"expect": DRIVER_Q, "send": "1\n", "timeout": STEP},
        {"expect": REMOTE_Q, "send": "2\n", "timeout": DRIVER},
        {"expect": P["reboot_now"], "send": "2\n", "timeout": STEP, "optional": True},
    ]
elif GPU == "nvidia-unlock":
    # Patch-managed .run driver (run after a --nvidia wipe removed any driver): Unlock ->
    # confirm patch -> [.run download + kernel-module build + nvidia-patch, slow] -> Stage 2
    # offer -> end-of-wizard "Reboot now?". Same from-scratch reboot cycle as Standard, but
    # via the .run path: _stage3_choose_nvidia_mode asks driver_mode (2 = Unlock) then the
    # ui_confirm "Install the patch-managed driver and apply nvidia-patch?" (y), and
    # install_nvidia_drivers builds/caches the .run before the Stage 2 offer (hence UNLOCK
    # timeout on REMOTE_Q). On a clean no-driver box nvidia_driver_source != debian, so the
    # Standard->Unlock conversion branch is skipped; the new .run driver needs a reboot, so
    # the wizard queues it (mode=unlock, source=run). run-fresh.sh reboots and waits for the
    # post-boot finalize, which (mode=unlock) re-applies nvidia-patch. The "Reboot now?" step
    # is optional for the same reason as Standard (skipped if the .run driver verifies live and
    # no reboot is needed); run-fresh.sh accepts the in-line finalize via STAGE_3_GPU_STATE.
    steps += [
        {"expect": TRANSCODE, "send": "1\n", "timeout": INSTALL},
        {"expect": DRIVER_Q, "send": "2\n", "timeout": STEP},
        {"expect": P["unlock_patch_offer"], "send": "y\n", "timeout": STEP},
        {"expect": REMOTE_Q, "send": "2\n", "timeout": UNLOCK},
        {"expect": P["reboot_now"], "send": "2\n", "timeout": STEP, "optional": True},
    ]
else:
    die(
        f"GPU mode {GPU!r} is not yet wired into the LAN live-drive "
        "(supported now: none, nvidia-existing, nvidia-standard, nvidia-unlock; "
        "intel/amd need real Intel/AMD silicon — not present on the NVIDIA test box)."
    )

json.dump(steps, sys.stdout, indent=2)
sys.stdout.write("\n")

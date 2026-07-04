#!/usr/bin/env python3
"""Check whether compose image tags now resolve to new remote digests.

This is intentionally a lightweight alert, not an integration test. It resolves
remote manifests with Docker Buildx but does not pull layers, start containers,
or run DinD.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import quote

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised in CI shell, not unit tests
    raise SystemExit("python3-yaml is required") from exc


@dataclass(frozen=True)
class ImageDigest:
    service: str
    image: str
    digest: str
    tested_at_utc: str = ""
    preflight: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Alert when docker-compose.yml image tags resolve to new remote digests."
    )
    parser.add_argument("--compose", default="docker-compose.yml", help="Compose file to read")
    parser.add_argument(
        "--previous",
        default="docs/operations/image-digests.lock",
        help="Tested digest record to compare against",
    )
    parser.add_argument(
        "--upgrades",
        default="docs/operations/upgrades.md",
        help="Upgrade manifest to read preflight tokens from",
    )
    parser.add_argument("--write-current", help="Write the current digest TSV here")
    parser.add_argument(
        "--snapshot-current",
        help="Write a current digest TSV and exit successfully without accepting it",
    )
    parser.add_argument(
        "--record-install",
        metavar="PATH",
        help=(
            "Record each running service's local install digest (service<TAB>image<TAB>digest) "
            "to PATH and exit. Overwrites PATH with the current full set (ADR-30)."
        ),
    )
    parser.add_argument(
        "--current-file",
        help="Use an existing current digest TSV instead of resolving remote manifests",
    )
    parser.add_argument(
        "--require-previous",
        action="store_true",
        help="Fail if the tested digest record is missing",
    )
    parser.add_argument(
        "--tested-at",
        help="UTC timestamp to stamp onto new or changed digest rows; defaults to now",
    )
    parser.add_argument(
        "--restamp-all",
        action="store_true",
        help="Stamp every current row, even if the digest did not change",
    )
    parser.add_argument(
        "--accept-current",
        action="store_true",
        help="Exit successfully after writing current digests, even if they differ",
    )
    parser.add_argument(
        "--accept-services",
        action="append",
        metavar="SVC[,SVC...]",
        help=(
            "Selectively accept only these drifted services into the lock, preserving "
            "every other row and its timestamp. Repeatable and comma-separated. Requires "
            "--current-file and --write-current; mutually exclusive with --accept-current. "
            "Refused when the snapshot adds or removes services (use --accept-current to "
            "re-baseline the full service set)."
        ),
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Print a per-service update status table (user-facing) and exit",
    )
    parser.add_argument(
        "--status-tsv",
        action="store_true",
        help="Print per-service status as TSV (service, policy, override, status, updatable) and exit",
    )
    parser.add_argument(
        "--readme-badges",
        action="store_true",
        help="Print the generated README Stable-baseline badge block and exit",
    )
    parser.add_argument(
        "--write-readme-badges",
        metavar="PATH",
        help="Replace the marked README Stable-baseline badge block in PATH",
    )
    parser.add_argument(
        "--check-readme-badges",
        metavar="PATH",
        help="Fail if the marked README Stable-baseline badge block in PATH is stale",
    )
    return parser.parse_args()


def load_compose_images(path: pathlib.Path) -> list[tuple[str, str]]:
    data = yaml.safe_load(path.read_text()) or {}
    services = data.get("services") or {}
    images: list[tuple[str, str]] = []
    for service, spec in services.items():
        if isinstance(spec, dict) and spec.get("image"):
            images.append((service, str(spec["image"])))
    if not images:
        raise SystemExit(f"no images found in {path}")
    return images


def resolve_digest(image: str) -> str:
    cmd = ["docker", "buildx", "imagetools", "inspect", image]
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RuntimeError(
            f"failed to inspect {image}:\n{proc.stderr.strip() or proc.stdout.strip()}"
        )
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Digest:"):
            digest = stripped.split(":", 1)[1].strip()
            if digest.startswith("sha256:"):
                return digest
    raise RuntimeError(f"could not find digest in docker output for {image}")


def current_digests(compose_path: pathlib.Path) -> list[ImageDigest]:
    rows: list[ImageDigest] = []
    for service, image in load_compose_images(compose_path):
        rows.append(ImageDigest(service=service, image=image, digest=resolve_digest(image)))
    return rows


def read_tsv(path: pathlib.Path | None) -> list[ImageDigest]:
    if path is None or not path.exists():
        return []
    rows: list[ImageDigest] = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("service\timage\tdigest"):
            continue
        parts = line.split("\t")
        if len(parts) not in (3, 5):
            raise SystemExit(f"invalid digest row in {path}: {raw!r}")
        tested_at_utc = parts[3] if len(parts) == 5 else ""
        preflight = parts[4] if len(parts) == 5 else ""
        rows.append(
            ImageDigest(
                service=parts[0],
                image=parts[1],
                digest=parts[2],
                tested_at_utc=tested_at_utc,
                preflight=preflight,
            )
        )
    return rows


def write_tsv(path: pathlib.Path, rows: list[ImageDigest]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# MediaStack tested image digest record v1",
        "# Update only after the matching local DinD preflight has passed.",
        "service\timage\tdigest\ttested_at_utc\tpreflight",
    ]
    for row in rows:
        lines.append(
            f"{row.service}\t{row.image}\t{row.digest}\t{row.tested_at_utc}\t{row.preflight}"
        )
    path.write_text("\n".join(lines) + "\n")


README_BADGES_START = "<!-- stable-image-badges:start -->"
README_BADGES_END = "<!-- stable-image-badges:end -->"


def _shield_segment(value: str) -> str:
    # Shields static badge URLs escape literal hyphens as "--" inside path segments.
    return quote(value.replace("-", "--"), safe="")


def _shield_badge(
    alt: str,
    label: str,
    message: str,
    color: str,
    link: str,
    query: str = "",
) -> str:
    url = (
        "https://img.shields.io/badge/"
        f"{_shield_segment(label)}-{_shield_segment(message)}-{color}"
    )
    if query:
        url = f"{url}?{query}"
    return f"[![{alt}]({url})]({link})"


def format_readme_badges(rows: list[ImageDigest]) -> str:
    count = len(rows)
    lines = [
        README_BADGES_START,
        _shield_badge(
            f"Stable image baseline: {count} pinned digests",
            "Stable image baseline",
            f"{count} pinned digests",
            "2ea44f",
            "docs/operations/day-2.md",
            query="logo=docker&logoColor=white",
        ),
        README_BADGES_END,
    ]
    return "\n".join(lines)


def _replace_readme_badges(text: str, block: str) -> str:
    pattern = re.compile(
        rf"{re.escape(README_BADGES_START)}.*?{re.escape(README_BADGES_END)}",
        re.S,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError(
            f"expected exactly one README badge block marked by {README_BADGES_START}"
        )
    return text[: matches[0].start()] + block + text[matches[0].end() :]


def run_readme_badges(args: argparse.Namespace) -> int:
    actions = [
        bool(args.readme_badges),
        bool(args.write_readme_badges),
        bool(args.check_readme_badges),
    ]
    if sum(actions) != 1:
        print(
            "choose exactly one of --readme-badges, --write-readme-badges, or --check-readme-badges",
            file=sys.stderr,
        )
        return 2

    previous_path = pathlib.Path(args.previous) if args.previous else None
    rows = read_tsv(previous_path)
    if not rows:
        print(f"tested digest record missing or empty: {previous_path}", file=sys.stderr)
        return 1
    block = format_readme_badges(rows)

    if args.readme_badges:
        print(block)
        return 0

    readme_path = pathlib.Path(args.write_readme_badges or args.check_readme_badges)
    try:
        current = readme_path.read_text()
        expected = _replace_readme_badges(current, block)
    except (OSError, ValueError) as exc:
        print(f"README badge update failed: {exc}", file=sys.stderr)
        return 1

    if args.check_readme_badges:
        if expected != current:
            print(
                "README Stable-baseline badge is out of date; run "
                f"python3 scripts/image-drift.py --write-readme-badges {readme_path}",
                file=sys.stderr,
            )
            return 1
        print("README Stable-baseline badge is current.")
        return 0

    if expected == current:
        print(f"README Stable-baseline badge is already current in {readme_path}.")
        return 0
    readme_path.write_text(expected)
    print(f"README Stable-baseline badge updated in {readme_path}.")
    return 0


def read_preflights(path: pathlib.Path) -> dict[str, str]:
    text = path.read_text()
    match = re.search(
        r"<!--\s*upgrades-manifest:start\s*-->(.*?)<!--\s*upgrades-manifest:end\s*-->",
        text,
        re.S,
    )
    if not match:
        return {}
    preflights: dict[str, str] = {}
    for raw in match.group(1).splitlines():
        line = raw.strip()
        if not line.startswith("|") or set(line.replace("|", "").strip()) <= {"-", ":"}:
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 4 or cells[0] == "Service":
            continue
        preflights[cells[0]] = cells[3]
    return preflights


def enrich_rows(
    current: list[ImageDigest],
    previous: list[ImageDigest],
    preflights: dict[str, str],
    tested_at_utc: str,
    restamp_all: bool = False,
) -> list[ImageDigest]:
    previous_by_service = {row.service: row for row in previous}
    enriched: list[ImageDigest] = []
    for row in current:
        previous_row = previous_by_service.get(row.service)
        unchanged = (
            previous_row is not None
            and previous_row.image == row.image
            and previous_row.digest == row.digest
        )
        enriched.append(
            ImageDigest(
                service=row.service,
                image=row.image,
                digest=row.digest,
                tested_at_utc=tested_at_utc
                if restamp_all or not unchanged or not previous_row or not previous_row.tested_at_utc
                else previous_row.tested_at_utc,
                preflight=preflights.get(row.service)
                or (previous_row.preflight if previous_row else ""),
            )
        )
    return enriched


def compare(
    previous: list[ImageDigest], current: list[ImageDigest]
) -> tuple[list[ImageDigest], list[tuple[ImageDigest, ImageDigest]], list[ImageDigest]]:
    previous_by_service = {row.service: row for row in previous}
    current_by_service = {row.service: row for row in current}

    added = [row for row in current if row.service not in previous_by_service]
    changed = [
        (previous_by_service[row.service], row)
        for row in current
        if row.service in previous_by_service
        and (
            previous_by_service[row.service].image != row.image
            or previous_by_service[row.service].digest != row.digest
        )
    ]
    removed = [row for row in previous if row.service not in current_by_service]
    return added, changed, removed


def parse_service_selection(values: list[str]) -> list[str]:
    """Flatten repeated and comma-separated --accept-services values, in order.

    ``action="append"`` gives a list of raw strings; each may itself be a
    comma-separated list. Whitespace is stripped and empty tokens dropped, so
    ``--accept-services "sonarr, radarr" --accept-services qbittorrent`` and the
    comma-only form behave identically.
    """
    services: list[str] = []
    for value in values:
        for part in value.split(","):
            name = part.strip()
            if name:
                services.append(name)
    return services


def resolve_accept_services(
    values: list[str],
    previous: list[ImageDigest],
    current: list[ImageDigest],
    added: list[ImageDigest],
    removed: list[ImageDigest],
) -> set[str]:
    """Validate a selective-accept request and return the selected service set.

    Selective accept only handles digest drift on an unchanged service *set*, so
    a snapshot that adds or removes services is refused (the maintainer must
    re-baseline with --accept-current). Raises SystemExit (exit 1, message on
    stderr — the same idiom as read_tsv) on any invalid request so a maintainer
    never silently accepts the wrong rows.
    """
    if added or removed:
        details = []
        if added:
            details.append("added: " + ", ".join(sorted(row.service for row in added)))
        if removed:
            details.append("removed: " + ", ".join(sorted(row.service for row in removed)))
        raise SystemExit(
            "--accept-services only handles digest drift on existing services, but the "
            f"snapshot changes the service set ({'; '.join(details)}). Re-baseline the full "
            "set with --accept-current."
        )

    selected = parse_service_selection(values)
    if not selected:
        raise SystemExit("--accept-services requires at least one service name")

    seen: set[str] = set()
    duplicates: set[str] = set()
    for name in selected:
        if name in seen:
            duplicates.add(name)
        seen.add(name)
    if duplicates:
        raise SystemExit(
            "--accept-services lists duplicate service(s): " + ", ".join(sorted(duplicates))
        )

    previous_by_service = {row.service: row for row in previous}
    current_by_service = {row.service: row for row in current}
    for name in selected:
        if name not in current_by_service:
            raise SystemExit(
                f"--accept-services: unknown service '{name}' (not in the current snapshot)"
            )
        previous_row = previous_by_service[name]
        current_row = current_by_service[name]
        if (
            previous_row.image == current_row.image
            and previous_row.digest == current_row.digest
        ):
            raise SystemExit(
                f"--accept-services: '{name}' has not drifted; it already matches the lock"
            )
    return seen


def merge_selective(
    previous: list[ImageDigest], current: list[ImageDigest], selected: set[str]
) -> list[ImageDigest]:
    """Lock rows after a selective accept: previous rows, selected ones swapped.

    Because selective accept is refused when the service set changes, ``previous``
    and ``current`` cover the same services; iterating ``previous`` preserves the
    lock's order, every unselected row (and its timestamp) verbatim, and replaces
    only the selected services with their freshly enriched current row.
    """
    current_by_service = {row.service: row for row in current}
    return [
        current_by_service[row.service] if row.service in selected else row
        for row in previous
    ]


def preflight_command(row: ImageDigest) -> str:
    if row.preflight.startswith("scenario:"):
        scenario = row.preflight.split(":", 1)[1]
        image_ref = f"{row.image}@{row.digest}"
        return f'MS_TEST_IMAGE_OVERRIDES="{row.service}={image_ref}" ./tests/run.sh {scenario}'
    if row.preflight.startswith("unit:"):
        return f"bash {row.preflight.split(':', 1)[1]}"
    if row.preflight == "compose-only":
        return "docker compose config --quiet"
    return "manual verification required"


def markdown_summary(
    added: list[ImageDigest],
    changed: list[tuple[ImageDigest, ImageDigest]],
    removed: list[ImageDigest],
) -> str:
    lines = ["## MediaStack image drift"]
    if not added and not changed and not removed:
        lines.append("")
        lines.append("No compose image digest changes detected.")
        return "\n".join(lines) + "\n"

    lines.extend(
        [
            "",
            "Remote image tags now resolve differently than the previous baseline.",
            "Run the affected service preflight from `docs/operations/upgrades.md` locally with DinD before accepting the new baseline.",
        ]
    )
    # Jellyfin/seerr preflight is scenario:fresh-install, which also runs
    # assert_fail2ban_configured — the only automated check that their fail2ban
    # filter still matches the new log format. Surface that here so a maintainer
    # accepting the bump knows brute-force protection was re-verified (ADR-44).
    drift_services = {c.service for _, c in changed} | {a.service for a in added}
    if drift_services & {"jellyfin", "seerr"}:
        lines.append(
            "For **jellyfin**/**seerr**, that `fresh-install` preflight also re-verifies the service's "
            "fail2ban filter still matches the new log format (`assert_fail2ban_configured`) — the only "
            "automated signal for a log-format change that would silently stop brute-force bans."
        )
    lines.extend(
        [
            "",
            "| Service | Previous | Current | Local preflight |",
            "|---|---|---|---|",
        ]
    )
    for previous, current in changed:
        before = f"`{previous.image}`<br>`{previous.digest}`"
        after = f"`{current.image}`<br>`{current.digest}`"
        lines.append(
            f"| `{current.service}` | {before} | {after} | `{preflight_command(current)}` |"
        )
    for row in added:
        lines.append(
            f"| `{row.service}` | new service | `{row.image}`<br>`{row.digest}` | `{preflight_command(row)}` |"
        )
    for row in removed:
        lines.append(f"| `{row.service}` | `{row.image}`<br>`{row.digest}` | removed | n/a |")
    lines.extend(
        [
            "",
            "Before running local preflights, freeze the exact digest snapshot you will test:",
            "",
            "```bash",
            "mkdir -p .tmp",
            "python3 scripts/image-drift.py --snapshot-current .tmp/image-digests.current.tsv",
            "python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv",
            "```",
            "",
            "After every affected preflight passes, accept that same snapshot and commit it:",
            "",
            "```bash",
            "python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current",
            "```",
        ]
    )
    if changed and not added and not removed:
        drifted = ",".join(current.service for _, current in changed)
        lines.extend(
            [
                "",
                "To accept only the services whose preflight passed and leave the other "
                "drifted rows pending, name them explicitly (preserves every other row):",
                "",
                "```bash",
                "python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv "
                "--write-current docs/operations/image-digests.lock "
                f"--accept-services {drifted}",
                "```",
            ]
        )
    lines.extend(
        [
            "",
            "Then regenerate the README Stable-baseline badge from the accepted lock and commit "
            "everything together — the `tests/unit/upgrades-manifest.sh` CI check fails the "
            "build if this step is skipped:",
            "",
            "```bash",
            "python3 scripts/image-drift.py --write-readme-badges README.md",
            "```",
        ]
    )
    return "\n".join(lines) + "\n"


# --- User-facing per-service update status (Manage updates menu) ------------
# The maintainer drift check above compares compose tags to the tested lock.
# This scan instead answers, per service: "is a newer image available for me?"
# Fully channel-agnostic (#206): stable/latest is an install-time choice, so the
# label no longer branches on channel — a pinned Stable service and an upstream-tag
# service both read "Update available" when they trail their compose tag.
# See ADR-30 and scripts/setup/override.sh (_effective_channel).

IMAGE_POLICY_FILE = "config/state/image-policy.tsv"


def _norm_repo(repo: str) -> str:
    """Normalize a repo for comparison (Docker omits docker.io/library prefixes)."""
    for prefix in ("docker.io/", "index.docker.io/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix) :]
    if repo.startswith("library/"):
        repo = repo[len("library/") :]
    return repo


def repo_of(image: str) -> str:
    """Strip any @digest and :tag from an image ref, leaving the repository."""
    ref = image.split("@", 1)[0]
    slash = ref.rfind("/")
    colon = ref.rfind(":")
    if colon > slash:  # a ':' after the last '/' is a tag, not a registry port
        ref = ref[:colon]
    return ref


def container_image_id(service: str) -> str | None:
    """The image ID a container currently runs, or None when no container exists.

    Container presence is separate from digest resolution (see image_repo_digest):
    a present-but-undigestable image must read as "Unknown local digest", not
    "Not installed".
    """
    cont = subprocess.run(
        ["docker", "inspect", "--format", "{{.Image}}", service],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if cont.returncode != 0 or not cont.stdout.strip():
        return None
    return cont.stdout.strip()


def image_repo_digest(image_id: str, image: str) -> str | None:
    """Repo digest (sha256:...) for an image ID, matched to the compose repo.

    RepoDigests lives on the *image* object, not the container. Empty RepoDigests
    (locally built/imported, or tag-detached) or no repo match returns None
    ("digest unresolvable") — which the caller surfaces as "Unknown local digest"
    for a running container, not "Not installed".
    """
    img = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", image_id],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if img.returncode != 0:
        return None
    try:
        repo_digests = json.loads(img.stdout.strip() or "[]")
    except json.JSONDecodeError:
        return None
    want = _norm_repo(repo_of(image))
    only: str | None = None
    for entry in repo_digests:
        repo, _, dig = entry.partition("@")
        if not dig.startswith("sha256:"):
            continue
        only = dig
        if _norm_repo(repo) == want:
            return dig
    # Single-repo image whose host normalized differently: trust the lone entry.
    return only if len(repo_digests) == 1 else None


def _is_pin(value: str) -> bool:
    """A per-service policy value that is a literal digest pin (ADR-30 #208)."""
    return "@sha256:" in value


def record_install(compose_path: pathlib.Path, out_path: pathlib.Path) -> int:
    """Record each running service's local install digest to out_path (overwrite).

    Reuses the local digest readers (no registry) — the digest a service is
    actually running right after install. Overwritten on every install run so a
    `down -v && ./setup.sh --full` rebuild re-baselines (ADR-30 #208). Services
    with no resolvable local digest are skipped, not recorded as revertable.
    """
    rows: list[tuple[str, str, str]] = []
    for service, image in load_compose_images(compose_path):
        image_id = container_image_id(service)
        if image_id is None:
            continue
        digest = image_repo_digest(image_id, image)
        if not digest:
            continue
        rows.append((service, image, digest))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# MediaStack per-service install digests - the image each service was installed running.",
        "# Format: service<TAB>image<TAB>digest. Overwritten on each install run (ADR-30).",
    ]
    lines += [f"{service}\t{image}\t{digest}" for service, image, digest in rows]
    out_path.write_text("\n".join(lines) + "\n")
    return 0


def read_policy(path: pathlib.Path) -> dict[str, str]:
    """Per-service policy overrides: {service: 'stable'|'latest'|'<image>@sha256:...'}.

    A digest-pin value (#208 "Revert to installed image") is a real override too,
    so it's kept — presence drives the `manual` override flag; the value is
    normalized to the display token `pinned` by the status formatters.
    """
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2 and (parts[1] in ("stable", "latest") or _is_pin(parts[1])):
            out[parts[0]] = parts[1]
    return out


def derive_status(
    policy: str, present: bool, running: str | None, upstream: str, lock: str | None
) -> tuple[str, bool]:
    """Return (status_text, updatable). upstream == 'unknown' means offline.

    Channel-agnostic (#206): stable/latest is an install-time choice, so the day-2
    status answers one question for every service regardless of channel — "does a
    newer image exist for this compose tag?" ``policy`` and ``lock`` are retained
    for signature + CLI-column compatibility but no longer branch the label; a
    pinned Stable service and an upstream-tag service both read "Update available"
    when the running digest trails the tag, and applying either floats the service
    to its tag.

    present=False ⇒ no container. present=True with running=None ⇒ the container
    exists but its local repo digest can't be resolved ("Unknown local digest").
    """
    if not present:
        return ("Not installed", False)
    if running is None:
        return ("Unknown local digest", False)
    if upstream == "unknown":
        return ("Unknown (offline)", False)
    if running == upstream:
        return ("Up to date", False)
    return ("Update available", True)


def scan_status(
    compose_path: pathlib.Path,
    lock_path: pathlib.Path | None,
    policy_path: pathlib.Path,
    global_channel: str,
    progress: bool = False,
) -> list[dict]:
    lock = {row.service: row.digest for row in read_tsv(lock_path)}
    policy = read_policy(policy_path)
    images = load_compose_images(compose_path)

    def scan_one(item: tuple[str, str]) -> dict:
        service, image = item
        # "manual" = an explicit per-service row; "default" = inherits the global
        # channel. The launcher uses this to offer reset only for real overrides.
        override = "manual" if service in policy else "default"
        effective = policy.get(service, global_channel)
        image_id = container_image_id(service)
        present = image_id is not None
        running = image_repo_digest(image_id, image) if image_id is not None else None
        try:
            upstream = resolve_digest(image)
        except RuntimeError:
            upstream = "unknown"
        if progress:
            print(".", end="", file=sys.stderr, flush=True)
        status, updatable = derive_status(effective, present, running, upstream, lock.get(service))
        return {
            "service": service,
            "image": image,
            "policy": effective,
            "override": override,
            "status": status,
            "updatable": updatable,
        }

    # Each row is dominated by a network `docker buildx imagetools inspect` in
    # resolve_digest; run them concurrently (subprocess releases the GIL) so the
    # launcher's status scan takes ~one round-trip, not the sum of ~19. Threads
    # (not processes) keep the docker calls and stderr progress dots simple, and
    # `.map` preserves compose order for the table.
    workers = min(8, len(images))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        rows = list(pool.map(scan_one, images))
    if progress:
        print("", file=sys.stderr)
    return rows


_POLICY_LABEL = {"stable": "Pinned", "latest": "Tracking tag", "pinned": "Pinned (install)"}


def _policy_display(value: str) -> str:
    """Normalize a policy value to a short display token (digest pin -> 'pinned')."""
    return "pinned" if _is_pin(value) else value


def format_status_tsv(rows: list[dict]) -> str:
    # Columns: service, policy, override(manual|default), status, updatable.
    # A digest pin is emitted as the short token `pinned`, never the raw digest.
    return "\n".join(
        f"{r['service']}\t{_policy_display(r['policy'])}\t{r['override']}\t{r['status']}"
        f"\t{'true' if r['updatable'] else 'false'}"
        for r in rows
    )


def format_status_table(rows: list[dict]) -> str:
    head = ("SERVICE", "POLICY", "STATUS")

    def is_pin_row(r: dict) -> bool:
        return _is_pin(r["policy"])

    def label(r: dict) -> str:
        base = _POLICY_LABEL.get(_policy_display(r["policy"]), r["policy"])
        # The `*` footnote means "tracking its upstream tag" — the opposite of a
        # pinned service, so pins get the label without the star.
        return base + " *" if r["override"] == "manual" and not is_pin_row(r) else base

    body = [(r["service"], label(r), r["status"]) for r in rows]
    w0 = max([len(head[0])] + [len(b[0]) for b in body], default=len(head[0]))
    w1 = max([len(head[1])] + [len(b[1]) for b in body], default=len(head[1]))
    lines = [f"{head[0]:<{w0}}  {head[1]:<{w1}}  {head[2]}"]
    lines.append(f"{'-' * w0}  {'-' * w1}  {'-' * len(head[2])}")
    for service, lbl, status in body:
        lines.append(f"{service:<{w0}}  {lbl:<{w1}}  {status}")
    if any(r["override"] == "manual" and not is_pin_row(r) for r in rows):
        lines.append("")
        lines.append("* manual override — tracking its upstream tag, not the image it was installed with")
    return "\n".join(lines)


def _channel_from_env_file(compose_path: pathlib.Path) -> str | None:
    """Read IMAGE_CHANNEL from the .env beside the compose file (best-effort)."""
    env_path = compose_path.resolve().parent / ".env"
    if not env_path.exists():
        return None
    try:
        for raw in env_path.read_text().splitlines():
            line = raw.strip()
            if line.startswith("IMAGE_CHANNEL="):
                val = line.split("=", 1)[1].strip().strip("\"'").lower()
                return val or None
    except OSError:
        return None
    return None


def run_status(args: argparse.Namespace) -> int:
    compose_path = pathlib.Path(args.compose)
    lock_path = pathlib.Path(args.previous) if args.previous else None
    policy_path = pathlib.Path(os.environ.get("IMAGE_POLICY_FILE", IMAGE_POLICY_FILE))
    # Prefer the exported var (the launcher sources .env); fall back to reading
    # .env so the documented direct command isn't mislabeled on a Latest install.
    global_channel = (os.environ.get("IMAGE_CHANNEL") or _channel_from_env_file(compose_path) or "stable").strip().lower()
    if global_channel not in ("stable", "latest"):
        global_channel = "stable"
    try:
        rows = scan_status(
            compose_path, lock_path, policy_path, global_channel, progress=not args.status_tsv
        )
    except (RuntimeError, OSError) as exc:
        print(f"status scan failed: {exc}", file=sys.stderr)
        return 1
    print(format_status_tsv(rows) if args.status_tsv else format_status_table(rows))
    return 0


def main() -> int:
    args = parse_args()
    if args.readme_badges or args.write_readme_badges or args.check_readme_badges:
        return run_readme_badges(args)
    if args.status or args.status_tsv:
        return run_status(args)
    if args.record_install:
        return record_install(pathlib.Path(args.compose), pathlib.Path(args.record_install))
    previous_path = pathlib.Path(args.previous) if args.previous else None
    current_path = pathlib.Path(args.write_current) if args.write_current else None
    snapshot_path = pathlib.Path(args.snapshot_current) if args.snapshot_current else None
    upgrades_path = pathlib.Path(args.upgrades)
    tested_at_utc = args.tested_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.accept_services:
        if args.accept_current:
            print(
                "--accept-services and --accept-current are mutually exclusive; choose "
                "selective or full acceptance",
                file=sys.stderr,
            )
            return 1
        if not args.current_file:
            print(
                "--accept-services requires --current-file so the accepted digest snapshot is the one that was preflighted",
                file=sys.stderr,
            )
            return 1
        if not args.write_current:
            print(
                "--accept-services requires --write-current <lock> to write the merged baseline",
                file=sys.stderr,
            )
            return 1

    if args.accept_current and not args.current_file:
        print(
            "--accept-current requires --current-file so the accepted digest snapshot is the one that was preflighted",
            file=sys.stderr,
        )
        return 1

    try:
        previous = read_tsv(previous_path)
        if args.require_previous and not previous:
            print(f"tested digest record missing or empty: {previous_path}", file=sys.stderr)
            return 1
        if args.current_file:
            current = read_tsv(pathlib.Path(args.current_file))
        else:
            current = current_digests(pathlib.Path(args.compose))
        current = enrich_rows(
            current,
            previous,
            read_preflights(upgrades_path),
            tested_at_utc,
            restamp_all=args.restamp_all,
        )
        if snapshot_path:
            write_tsv(snapshot_path, current)
            print(f"Current image digest snapshot written to {snapshot_path}.")
            return 0
    except (RuntimeError, OSError) as exc:
        print(f"image drift check failed: {exc}", file=sys.stderr)
        return 1
    if not previous:
        if args.accept_services:
            print(
                "--accept-services requires an existing baseline lock to preserve unselected rows",
                file=sys.stderr,
            )
            return 1
        if current_path:
            write_tsv(current_path, current)
        print("No previous image digest baseline found; current digests recorded as baseline.")
        summary = markdown_summary([], [], [])
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            pathlib.Path(os.environ["GITHUB_STEP_SUMMARY"]).write_text(summary)
        return 0

    added, changed, removed = compare(previous, current)

    if args.accept_services:
        # Selective accept resolves and writes the merged lock here, then returns
        # before the full-snapshot write below, so it never clobbers the merge.
        selected = resolve_accept_services(args.accept_services, previous, current, added, removed)
        merged = merge_selective(previous, current, selected)
        write_tsv(current_path, merged)
        print(
            "Selectively accepted drifted services: "
            + ", ".join(sorted(selected))
            + "; all other rows preserved."
        )
        pending = sorted({current.service for _, current in changed} - selected)
        if pending:
            print("Drifted services left pending: " + ", ".join(pending) + ".")
        return 0

    if current_path:
        write_tsv(current_path, current)
    summary = markdown_summary(added, changed, removed)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        pathlib.Path(os.environ["GITHUB_STEP_SUMMARY"]).write_text(summary)

    if added or changed or removed:
        if args.accept_current:
            print("Image drift accepted; current digests will become the next baseline.")
            return 0
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

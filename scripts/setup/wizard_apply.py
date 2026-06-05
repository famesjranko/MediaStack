#!/usr/bin/env python3
"""Apply a quality preset and subtitle languages to config.yml.

Uses section-targeted replacement to preserve comments in untouched sections.
Each replaced section is identified by its YAML comment-divider header.
"""
import argparse
import os
import re
import sys

import yaml


def load_presets(presets_path):
    with open(presets_path) as f:
        return yaml.safe_load(f)["presets"]


def load_public_indexers(indexers_path):
    """Load the canonical public-tracker indexer list (id/type entries)."""
    with open(indexers_path) as f:
        data = yaml.safe_load(f) or {}
    return data.get("indexers") or []


def render_quality_profile(preset):
    """Render the quality_profile YAML section from a preset dict."""
    lines = [
        "quality_profile:",
        f'  name: "{preset["profile_name"]}"',
        f"  cutoff_id: {preset['cutoff_id']}",
        f"  upgrade_allowed: {'true' if preset['upgrade_allowed'] else 'false'}",
        "  sonarr_qualities:",
    ]
    for qid in preset["sonarr_qualities"]:
        lines.append(f"    - {qid}")
    lines.append("  radarr_qualities:")
    for qid in preset["radarr_qualities"]:
        lines.append(f"    - {qid}")
    return "\n".join(lines)


def render_quality_definitions(preset):
    """Render the quality_definitions YAML section from a preset dict."""
    lines = ["quality_definitions:"]
    for app in ("sonarr", "radarr"):
        defs = preset.get("quality_definitions", {}).get(app)
        if not defs:
            continue
        lines.append(f"  {app}:")
        for name, vals in defs.items():
            lines.append(
                f"    {name + ':':19s}"
                f"{{ min: {vals['min']}, "
                f"preferred: {vals['preferred']}, "
                f"max: {vals['max']} }}"
            )
    return "\n".join(lines)


def render_custom_formats(preset):
    """Render the custom_formats YAML section from a preset dict."""
    scores = preset.get("custom_format_scores", {})
    if not scores:
        return None
    lines = ["custom_formats:"]
    for name, score in scores.items():
        lines.append(f'  "{name}":{" " * max(1, 14 - len(name))}{score}')
    return "\n".join(lines)


def render_bazarr(languages):
    """Render the bazarr YAML section from a language list."""
    lines = ["bazarr:", "  languages:"]
    for lang in languages:
        lines.append(f"    - {lang}")
    return "\n".join(lines)


def render_indexers(enabled, indexers):
    """Render the Jackett indexer section from the canonical list.

    Emits bare id/type entries; per-indexer descriptions live in the source
    file (config/examples/public-indexers.yml), not in generated config.yml.
    """
    if not enabled:
        return "indexers: []"

    lines = ["indexers:"]
    for idx in indexers:
        lines.append(f"  - id: {idx['id']}")
        lines.append(f"    type: {idx.get('type', 'general')}")
    return "\n".join(lines)


# Section dividers in config.yml look like:
#   # ---------------------------------------------------------------------------
#   # Section Title
#   # ---------------------------------------------------------------------------
# We match the title line to find where each section starts.
SECTION_PATTERNS = {
    "indexers": re.compile(
        r"^# Jackett", re.MULTILINE
    ),
    "quality_profile": re.compile(
        r"^# Quality Profile\s*$", re.MULTILINE
    ),
    "quality_definitions": re.compile(
        r"^# Quality Definitions", re.MULTILINE
    ),
    "custom_formats": re.compile(
        r"^# Custom Formats", re.MULTILINE
    ),
    "bazarr": re.compile(
        r"^# Bazarr", re.MULTILINE
    ),
}

# Each section ends at the next divider block (line starting with # followed
# by a row of dashes) or end-of-file.
DIVIDER_RE = re.compile(r"^# -{10,}", re.MULTILINE)


def find_section_span(text, section_key):
    """Return (start, end) byte offsets for a config.yml section.

    'start' is the first # of the divider header; 'end' is the first # of
    the next divider header (or len(text)).
    """
    title_match = SECTION_PATTERNS[section_key].search(text)
    if not title_match:
        return None

    # Walk backwards to find the opening divider line (# ---...---)
    prefix = text[: title_match.start()]
    last_divider = None
    for m in DIVIDER_RE.finditer(prefix):
        last_divider = m
    section_start = last_divider.start() if last_divider else title_match.start()

    # Find the next divider header AFTER the title
    body_start = title_match.end()
    # Skip the closing divider of this header
    closing_div = DIVIDER_RE.search(text, body_start)
    if closing_div:
        search_from = closing_div.end()
    else:
        search_from = body_start

    next_div = DIVIDER_RE.search(text, search_from)
    section_end = next_div.start() if next_div else len(text)

    return (section_start, section_end)


def rebuild_section(header_title, header_comment, body):
    """Rebuild a full section with divider + comment + body."""
    divider = "# " + "-" * 75
    lines = [divider, f"# {header_title}", divider]
    if header_comment:
        for line in header_comment:
            lines.append(f"# {line}" if line else "#")
    lines.append(body)
    lines.append("")
    lines.append("")  # blank line separating from next section
    return "\n".join(lines)


# The Jackett indexers section header/comment — shared by the full preset apply
# and the day-2 indexers-only apply so the two cannot drift.
INDEXERS_SECTION_TITLE = "Jackett Indexers"
INDEXERS_SECTION_COMMENT = [
    "Public releases ship with no indexers enabled by default. Add only the",
    "indexers you are legally allowed to use, then re-run ./scripts/configure.sh.",
    "The setup wizard can enable an example public-tracker preset, and the same",
    "example lives at config/examples/public-indexers.yml.",
    "",
    "Format: id: description (description is for humans only)",
]


def apply_preset(config_text, preset, languages, public_indexers_enabled,
                 public_indexers):
    """Replace wizard-controlled sections."""
    cf_body = render_custom_formats(preset)

    replacements = [
        (
            "indexers",
            INDEXERS_SECTION_TITLE,
            INDEXERS_SECTION_COMMENT,
            render_indexers(public_indexers_enabled, public_indexers),
        ),
        (
            "quality_profile",
            "Quality Profile",
            [],
            render_quality_profile(preset),
        ),
        (
            "quality_definitions",
            "Quality Definitions — per-tier file-size bounds",
            [],
            render_quality_definitions(preset),
        ),
        (
            "bazarr",
            "Bazarr - Subtitle Management",
            [],
            render_bazarr(languages),
        ),
    ]

    if cf_body is not None:
        replacements.insert(2, (
            "custom_formats",
            "Custom Formats — TRaSH Guides scoring",
            [
                "Scores custom release attributes within a quality tier. Higher scores are",
                "preferred; negative scores penalise. -10000 effectively blocks.",
                "Set to 0 to disable a format's scoring (format still exists but is neutral).",
                "Delete this section to skip custom format configuration entirely.",
                "",
                "Format definitions: scripts/lib/arr/custom_formats.yml",
            ],
            cf_body,
        ))

    for section_key, title, comment, body in reversed(replacements):
        span = find_section_span(config_text, section_key)
        if span is None:
            print(f"warning: section '{section_key}' not found in config.yml",
                  file=sys.stderr)
            continue
        replacement = rebuild_section(title, comment, body)
        config_text = config_text[: span[0]] + replacement + config_text[span[1]:]

    return config_text


def apply_indexers_only(config_text, enabled, indexers):
    """Rewrite ONLY the Jackett indexers section of config.yml.

    Unlike apply_preset (which rewrites indexers + quality + custom-formats +
    subtitles together, keyed off the chosen preset/languages), this touches
    nothing else — so the day-2 launcher can flip public indexers on/off without
    clobbering the user's quality profile or subtitle languages.
    """
    span = find_section_span(config_text, "indexers")
    if span is None:
        print("warning: section 'indexers' not found in config.yml",
              file=sys.stderr)
        return config_text
    replacement = rebuild_section(
        INDEXERS_SECTION_TITLE,
        INDEXERS_SECTION_COMMENT,
        render_indexers(enabled, indexers),
    )
    return config_text[: span[0]] + replacement + config_text[span[1]:]


def resolve_public_indexers(file_arg):
    """Resolve and load the canonical public-indexer list; exit on error."""
    indexers_file = file_arg
    if indexers_file is None:
        indexers_file = os.path.normpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "..", "config", "examples", "public-indexers.yml",
        ))
    try:
        indexers = load_public_indexers(indexers_file)
    except FileNotFoundError:
        print(f"error: indexer list not found: {indexers_file}",
              file=sys.stderr)
        sys.exit(1)
    if not indexers:
        print(f"error: no indexers found in {indexers_file}", file=sys.stderr)
        sys.exit(1)
    return indexers


def apply_bitrate_limit(config_text, limit):
    if limit is None:
        return config_text
    jf_match = re.search(r'^jellyfin:\s*\n', config_text, re.MULTILINE)
    if jf_match is None:
        return config_text
    jf_start = jf_match.end()
    next_key = re.search(r'^(?=[^\s#\n])', config_text[jf_start:], re.MULTILINE)
    jf_end = jf_start + next_key.start() if next_key else len(config_text)
    jf_section = config_text[jf_start:jf_end]

    key_match = re.search(
        r'^(\s*remote_bitrate_limit:\s*)(\d+)[^\n#]*(#[^\n]*)?$',
        jf_section, re.MULTILINE,
    )
    if key_match:
        comment = (key_match.group(3) or "").strip()
        new_value = f"  remote_bitrate_limit: {limit}"
        if comment:
            padding = max(1, 40 - len(new_value))
            new_value += " " * padding + comment
        new_section = jf_section[:key_match.start()] + new_value + jf_section[key_match.end():]
        return config_text[:jf_start] + new_section + config_text[jf_end:]

    return re.sub(
        r'^(jellyfin:\s*\n)', rf'\g<1>  remote_bitrate_limit: {limit}\n',
        config_text, flags=re.MULTILINE,
    )


def add_wizard_marker(config_text):
    """Add wizard_completed: true if not already present."""
    if "wizard_completed:" in config_text:
        config_text = re.sub(
            r"^wizard_completed:.*$", "wizard_completed: true",
            config_text, flags=re.MULTILINE,
        )
    else:
        config_text = config_text.rstrip("\n") + "\n\nwizard_completed: true\n"
    return config_text


def main():
    parser = argparse.ArgumentParser(
        description="Apply a quality preset to config.yml"
    )
    parser.add_argument(
        "--preset",
        help="Preset name (compact, balanced, quality). "
             "Required unless --indexers-only is given.",
    )
    parser.add_argument(
        "--languages", default="english",
        help="Comma-separated subtitle languages",
    )
    parser.add_argument(
        "--config", default="config.yml",
        help="Path to config.yml",
    )
    parser.add_argument(
        "--bitrate-limit", type=int, default=None,
        help="Remote streaming bitrate limit in Mbps (0 = unlimited)",
    )
    parser.add_argument(
        "--public-indexers", choices=("true", "false"), default="false",
        help="Enable the example public-tracker indexer preset",
    )
    parser.add_argument(
        "--indexers-only", choices=("true", "false"), default=None,
        help="Day-2 toggle: rewrite ONLY the indexers section of config.yml and "
             "exit, leaving quality/subtitle config untouched. --preset is "
             "ignored in this mode.",
    )
    parser.add_argument(
        "--presets-file", default=None,
        help="Path to presets.yml (default: same dir as this script)",
    )
    parser.add_argument(
        "--public-indexers-file", default=None,
        help="Path to the canonical public indexer list "
             "(default: config/examples/public-indexers.yml)",
    )
    args = parser.parse_args()

    # Day-2 "Features" toggle: rewrite ONLY the indexers section and exit. The
    # launcher uses this so flipping public indexers on/off post-install never
    # clobbers the user's quality profile or subtitle languages (apply_preset
    # rewrites those alongside indexers).
    if args.indexers_only is not None:
        enabled = args.indexers_only == "true"
        indexers = resolve_public_indexers(args.public_indexers_file) if enabled else []
        with open(args.config) as f:
            config_text = f.read()
        config_text = apply_indexers_only(config_text, enabled, indexers)
        with open(args.config, "w") as f:
            f.write(config_text)
        print("Public indexer preset: "
              f"{'enabled' if enabled else 'disabled'} (indexers only)")
        return

    if args.preset is None:
        parser.error("--preset is required unless --indexers-only is given")

    presets_file = args.presets_file
    if presets_file is None:
        presets_file = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "presets.yml"
        )

    presets = load_presets(presets_file)
    if args.preset not in presets:
        print(f"error: unknown preset '{args.preset}'. "
              f"Available: {', '.join(presets.keys())}", file=sys.stderr)
        sys.exit(1)

    preset = presets[args.preset]
    languages = [lang.strip() for lang in args.languages.split(",") if lang.strip()]
    if not languages:
        languages = ["english"]

    with open(args.config) as f:
        config_text = f.read()

    public_indexers_enabled = args.public_indexers == "true"
    public_indexers = []
    if public_indexers_enabled:
        public_indexers = resolve_public_indexers(args.public_indexers_file)

    config_text = apply_preset(
        config_text, preset, languages, public_indexers_enabled,
        public_indexers,
    )
    config_text = apply_bitrate_limit(config_text, args.bitrate_limit)
    config_text = add_wizard_marker(config_text)

    with open(args.config, "w") as f:
        f.write(config_text)

    print(f"Applied preset '{args.preset}' ({preset['profile_name']})")
    if languages:
        print(f"Subtitle languages: {', '.join(languages)}")
    print(
        "Public indexer preset: "
        f"{'enabled' if public_indexers_enabled else 'disabled'}"
    )


if __name__ == "__main__":
    main()

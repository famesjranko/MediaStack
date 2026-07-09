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


def load_quality_model(presets_path):
    """Load the resolution × size quality model (quality_ids/resolutions/sizes)."""
    with open(presets_path) as f:
        return yaml.safe_load(f)


def compose_cell(model, resolution_key, size_key):
    """Compose a (resolution × size) cell into a flat preset-equivalent dict.

    Returns the exact keys the render_* functions consume (profile_name,
    cutoff_id, upgrade_allowed, sonarr/radarr_qualities, custom_format_scores,
    quality_definitions) so config.yml's output shape — and the downstream
    renderer — stay unchanged. The 2D model lives only here and in presets.yml.
    """
    quality_ids = model.get("quality_ids") or {}
    resolutions = model.get("resolutions") or {}
    sizes = model.get("sizes") or {}

    if resolution_key not in resolutions:
        raise KeyError(
            f"unknown resolution '{resolution_key}'. "
            f"Available: {', '.join(resolutions.keys())}")
    if size_key not in sizes:
        raise KeyError(
            f"unknown size '{size_key}'. Available: {', '.join(sizes.keys())}")

    res = resolutions[resolution_key]
    size = sizes[size_key]
    tiers = res.get("tiers") or []

    def ids_for(app):
        app_ids = quality_ids.get(app) or {}
        out = []
        for name in tiers:
            if name not in app_ids:
                raise KeyError(
                    f"resolution '{resolution_key}' enables tier '{name}' but "
                    f"quality_ids.{app} has no id for it (add it to presets.yml)")
            out.append(app_ids[name])
        return out

    def defs_for(app):
        app_bounds = (size.get("bounds") or {}).get(app) or {}
        # Mask the (full) size bounds table down to this resolution's tiers,
        # preserving the resolution's floor→ceiling tier order.
        return {name: app_bounds[name] for name in tiers if name in app_bounds}

    return {
        "profile_name": f"{res['display_name']} {size['display_name']}",
        "cutoff_id": res["cutoff_group"],
        "upgrade_allowed": True,
        "sonarr_qualities": ids_for("sonarr"),
        "radarr_qualities": ids_for("radarr"),
        "custom_format_scores": size.get("custom_format_scores", {}),
        "quality_definitions": {
            "sonarr": defs_for("sonarr"),
            "radarr": defs_for("radarr"),
        },
    }


def list_axes(model):
    """Emit the resolution/size menu metadata for the shell picker as TSV.

    Row types (authoring order in presets.yml is preserved = menu order):
      RESOLUTION<TAB>key<TAB>display<TAB>description<TAB>
      SIZE<TAB>key<TAB>display<TAB>description<TAB>
      HINT<TAB>size_key<TAB>res_key<TAB>hint        (one per resolution x size)

    The GB/movie size hint is a CELL (resolution x size) value, so it ships as
    HINT rows rather than on the SIZE row — the picker can't know the chosen
    resolution until after the resolution prompt. The hint sits in the 4th
    (description) column on purpose: scripts/lib/quality_select.sh reads with
    `IFS=$'\\t'`, and tab is IFS-whitespace, so an empty *interior* column would
    collapse — a padded 5th column would never survive. Consumed only by
    quality_select.sh; no YAML parsing in bash, single parse home here.
    """
    lines = []
    for key, res in (model.get("resolutions") or {}).items():
        lines.append("\t".join([
            "RESOLUTION", key,
            str(res.get("display_name", key)),
            str(res.get("description", "")),
            "",
        ]))
    for key, size in (model.get("sizes") or {}).items():
        lines.append("\t".join([
            "SIZE", key,
            str(size.get("display_name", key)),
            str(size.get("description", "")),
            "",
        ]))
    # Per-cell GB hints. Guarded .get so a data-only future resolution without a
    # size_hints block can't crash --list-axes; the picker just omits the hint.
    for rkey, res in (model.get("resolutions") or {}).items():
        for skey, hint in (res.get("size_hints") or {}).items():
            lines.append("\t".join(["HINT", skey, rkey, str(hint)]))
    return "\n".join(lines)


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

# The three quality section headers/comments — shared by the full preset apply
# and the day-2 quality-only apply (issue #71) so the two cannot drift, exactly
# as the indexers section is shared above.
QUALITY_PROFILE_SECTION_TITLE = "Quality Profile"
QUALITY_DEFINITIONS_SECTION_TITLE = "Quality Definitions — per-tier file-size bounds"
CUSTOM_FORMATS_SECTION_TITLE = "Custom Formats — release-quality scoring"
CUSTOM_FORMATS_SECTION_COMMENT = [
    "Scores release attributes to STEER selection within a quality tier. Higher",
    "scores are preferred; negative scores penalise but do NOT block. No default",
    "format hard-blocks — file size is gated by the quality_definitions bounds,",
    "not here. (-10000 still hard-blocks if you want it; none does by default.)",
    "Set a score to 0 to make a format neutral. Delete this section to skip.",
    "",
    "Format definitions: scripts/lib/arr/custom_formats.yml",
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
            QUALITY_PROFILE_SECTION_TITLE,
            [],
            render_quality_profile(preset),
        ),
        (
            "quality_definitions",
            QUALITY_DEFINITIONS_SECTION_TITLE,
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
            CUSTOM_FORMATS_SECTION_TITLE,
            CUSTOM_FORMATS_SECTION_COMMENT,
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


def apply_quality_only(config_text, preset):
    """Rewrite ONLY the three quality sections of config.yml (quality_profile,
    quality_definitions, custom_formats) from a composed cell.

    The day-2 "change quality profile" launcher action (issue #71) uses this so
    re-picking resolution/size never clobbers the user's indexers, subtitle
    languages, or remote-streaming bitrate (apply_preset rewrites those
    alongside quality). Mirrors apply_indexers_only's single-purpose discipline,
    extended to the three contiguous quality sections.

    Each section is located independently by find_section_span against the
    current text, so the order here does not matter — a missing section (e.g.
    custom_formats absent because scores are empty) is warned and skipped, never
    fatal.
    """
    replacements = [
        (
            "quality_profile",
            QUALITY_PROFILE_SECTION_TITLE,
            [],
            render_quality_profile(preset),
        ),
        (
            "quality_definitions",
            QUALITY_DEFINITIONS_SECTION_TITLE,
            [],
            render_quality_definitions(preset),
        ),
    ]
    cf_body = render_custom_formats(preset)
    if cf_body is not None:
        replacements.append((
            "custom_formats",
            CUSTOM_FORMATS_SECTION_TITLE,
            CUSTOM_FORMATS_SECTION_COMMENT,
            cf_body,
        ))

    for section_key, title, comment, body in replacements:
        span = find_section_span(config_text, section_key)
        if span is None:
            print(f"warning: section '{section_key}' not found in config.yml",
                  file=sys.stderr)
            continue
        replacement = rebuild_section(title, comment, body)
        config_text = config_text[: span[0]] + replacement + config_text[span[1]:]

    return config_text


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


def _mbps_decimal(value):
    """argparse type for --bitrate-limit: same grammar as the wizard's
    validate_mbps_decimal (whole or fractional Mbps; 0 = unlimited). Kept as a
    string so '7' stays '7' and '3.5' stays '3.5' — float() would rewrite '7'
    as '7.0'."""
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', value):
        raise argparse.ArgumentTypeError(
            f"invalid Mbps value '{value}' (decimals OK, e.g. 3.5; 0 = unlimited)")
    return value


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
        r'^(\s*remote_bitrate_limit:\s*)(\d+(?:\.\d+)?)[^\n#]*(#[^\n]*)?$',
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
        "--resolution",
        help="Resolution ceiling (e.g. 720p, 1080p). Required with --size "
             "unless --indexers-only/--list-axes is given.",
    )
    parser.add_argument(
        "--size",
        help="Size envelope (compact, balanced, large). Required with "
             "--resolution unless --indexers-only/--list-axes is given.",
    )
    parser.add_argument(
        "--list-axes", action="store_true",
        help="Print resolution/size menu metadata (TSV) for the wizard picker "
             "and exit.",
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
        "--bitrate-limit", type=_mbps_decimal, default=None,
        help="Remote streaming bitrate limit in Mbps (0 = unlimited)",
    )
    parser.add_argument(
        "--public-indexers", choices=("true", "false"), default="false",
        help="Enable the example public-tracker indexer preset",
    )
    parser.add_argument(
        "--indexers-only", choices=("true", "false"), default=None,
        help="Day-2 toggle: rewrite ONLY the indexers section of config.yml and "
             "exit, leaving quality/subtitle config untouched. Quality "
             "selection is ignored in this mode.",
    )
    parser.add_argument(
        "--quality-only", action="store_true",
        help="Day-2 change: rewrite ONLY the quality sections (quality_profile, "
             "quality_definitions, custom_formats) of config.yml from "
             "--resolution/--size and exit, leaving indexers, subtitle "
             "languages, and remote bitrate untouched.",
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

    presets_file = args.presets_file
    if presets_file is None:
        presets_file = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "presets.yml"
        )

    # Emit the resolution/size menu metadata for the wizard picker and exit.
    if args.list_axes:
        print(list_axes(load_quality_model(presets_file)))
        return

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

    # Day-2 "change quality profile": rewrite ONLY the three quality sections
    # and exit. The launcher uses this so re-picking resolution/size post-install
    # never clobbers the user's indexers, subtitle languages, or remote bitrate
    # (apply_preset rewrites those alongside quality).
    if args.quality_only:
        if args.resolution is None or args.size is None:
            parser.error("--quality-only requires --resolution and --size")
        model = load_quality_model(presets_file)
        try:
            preset = compose_cell(model, args.resolution, args.size)
        except KeyError as e:
            print(f"error: {e}", file=sys.stderr)
            sys.exit(1)
        with open(args.config) as f:
            config_text = f.read()
        config_text = apply_quality_only(config_text, preset)
        with open(args.config, "w") as f:
            f.write(config_text)
        print(f"Applied quality profile '{preset['profile_name']}' "
              f"({args.resolution} x {args.size}) — quality sections only")
        return

    if args.resolution is None or args.size is None:
        parser.error("--resolution and --size are required unless "
                     "--indexers-only or --list-axes is given")

    model = load_quality_model(presets_file)
    try:
        preset = compose_cell(model, args.resolution, args.size)
    except KeyError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

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

    print(f"Applied quality profile '{preset['profile_name']}' "
          f"({args.resolution} x {args.size})")
    if languages:
        print(f"Subtitle languages: {', '.join(languages)}")
    print(
        "Public indexer preset: "
        f"{'enabled' if public_indexers_enabled else 'disabled'}"
    )


if __name__ == "__main__":
    main()

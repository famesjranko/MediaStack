#!/usr/bin/env python3
"""Determine which custom formats need to be created in Sonarr/Radarr.

Stdin: JSON array of existing custom formats from GET /api/v3/customformat.
Env:
    FORMATS_FILE — path to custom_formats.yml (format definitions).
    SCORES       — JSON object of name→score from config.yml.

Stdout: one line per format to create, as <name>\t<post-body-json>.
Skips formats already present (matched by name).
"""
import json
import os
import sys

import yaml


def main() -> int:
    formats_file = os.environ["FORMATS_FILE"]
    scores = json.loads(os.environ.get("SCORES", "{}"))

    with open(formats_file) as f:
        definitions = yaml.safe_load(f).get("formats", [])

    existing = json.load(sys.stdin)
    existing_names = {cf.get("name", "") for cf in existing}

    for fmt in definitions:
        name = fmt["name"]
        if name not in scores:
            continue
        if name in existing_names:
            continue
        body = {
            "name": name,
            "includeCustomFormatWhenRenaming": fmt.get(
                "includeCustomFormatWhenRenaming", False
            ),
            "specifications": fmt.get("specifications", []),
        }
        sys.stdout.write(f"{name}\t{json.dumps(body)}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())

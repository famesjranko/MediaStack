#!/usr/bin/env python3
"""Emit a wizard_pty.py steps-JSON from named prompts in tests/lib/wizard_prompts.json.

Usage:  wizard_steps_build.py NAME SEND [NAME SEND ...]
  NAME  a key in wizard_prompts.json (its expect regex) — or 'literal:<regex>' for a
        deliberate one-off prompt not worth a shared name. Append '@<seconds>' to set a
        custom per-step expect timeout (e.g. 'stage2_https_not_ready@30' for a prompt that
        follows a slow operation); without it wizard_pty.py uses its default step timeout.
  SEND  the keystroke(s) to send after that prompt; a trailing newline is added
        automatically. Special tokens: 'ENTER' = send just a newline (accept the
        default), 'NONE' = an expect with no send at all.

Both wizard-driven test surfaces build their steps from the SAME definitions, so a wizard
prompt change is made once (in wizard_prompts.json) and both surfaces track it — no silent
drift. Emits separate {"expect":...} and {"send":...} objects to match the hand-written
steps format the scenarios used before.
"""

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def load_prompts() -> dict:
    with open(os.path.join(_HERE, "wizard_prompts.json")) as f:
        return json.load(f)["prompts"]


def regex_for(name: str, prompts: dict) -> str:
    if name.startswith("literal:"):
        return name[len("literal:") :]
    if name not in prompts:
        sys.exit(f"wizard_steps_build: unknown prompt {name!r} (not in wizard_prompts.json)")
    return prompts[name]


def main() -> int:
    args = sys.argv[1:]
    if len(args) % 2 != 0:
        sys.exit("wizard_steps_build: expected NAME SEND pairs (got an odd number of args)")
    prompts = load_prompts()
    steps: list[dict] = []
    for i in range(0, len(args), 2):
        name, send = args[i], args[i + 1]
        timeout = None
        if "@" in name and not name.startswith("literal:"):
            base, suffix = name.rsplit("@", 1)
            if suffix.isdigit():
                name, timeout = base, int(suffix)
        expect: dict[str, str | int] = {"expect": regex_for(name, prompts)}
        if timeout is not None:
            expect["timeout"] = timeout
        steps.append(expect)
        if send == "NONE":
            pass  # expect with no send
        elif send == "ENTER":
            steps.append({"send": "\n"})  # accept the default
        else:
            steps.append({"send": send + "\n"})
    json.dump(steps, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

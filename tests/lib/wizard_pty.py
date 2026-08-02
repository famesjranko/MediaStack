#!/usr/bin/env python3
"""Drive MediaStack wizard prompts through a pseudo-terminal.

The DinD scenario harness uses this for UI/UX flows where a plain pipe is not
representative enough. Steps wait for text/regex in the ANSI-stripped transcript
before sending input, which keeps prompt tests deterministic and catches hangs.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def tail_lines(text: str, count: int = 80) -> str:
    lines = text.splitlines()
    return "\n".join(lines[-count:])


def read_available(master_fd: int) -> str:
    chunks: list[bytes] = []
    while True:
        ready, _, _ = select.select([master_fd], [], [], 0)
        if not ready:
            break
        try:
            data = os.read(master_fd, 8192)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks).decode("utf-8", errors="replace")


def wait_for_pattern(
    proc: subprocess.Popen[bytes],
    master_fd: int,
    pattern: str,
    timeout: float,
    raw_parts: list[str],
    optional: bool = False,
) -> str | None:
    # An optional step models a prompt that only appears under some runtime conditions —
    # e.g. the Stage 3 "Reboot now?" prompt is shown only when a reboot is actually needed
    # (stage3_reboot_prompt_needed); when the NVIDIA driver loads + verifies live, Stage 3
    # finalizes in-line and the prompt never appears. For an optional step, a clean process
    # exit (or a timeout) WITHOUT a match returns None ("not matched, skip the send") instead
    # of failing the run. A required step keeps the original loud-failure behaviour.
    deadline = time.monotonic() + timeout
    compiled = re.compile(pattern, re.MULTILINE | re.DOTALL)
    while time.monotonic() < deadline:
        raw = read_available(master_fd)
        if raw:
            raw_parts.append(raw)
        plain = strip_ansi("".join(raw_parts))
        if compiled.search(plain):
            return plain
        if proc.poll() is not None:
            raw = read_available(master_fd)
            if raw:
                raw_parts.append(raw)
            plain = strip_ansi("".join(raw_parts))
            if compiled.search(plain):
                return plain
            if optional:
                return None
            raise RuntimeError(
                f"process exited before pattern matched: {pattern!r}\n"
                f"--- transcript tail ---\n{tail_lines(plain)}"
            )
        time.sleep(0.05)
    if optional:
        return None
    plain = strip_ansi("".join(raw_parts))
    raise TimeoutError(
        f"timed out waiting for pattern: {pattern!r}\n--- transcript tail ---\n{tail_lines(plain)}"
    )


def kill_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)


def run(args: argparse.Namespace) -> int:
    steps = json.loads(Path(args.steps).read_text())
    master_fd, slave_fd = pty.openpty()
    raw_parts: list[str] = []

    proc = subprocess.Popen(
        ["bash", "-lc", args.command],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        cwd=args.cwd,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave_fd)

    exit_code: int | None = None
    try:
        for step in steps:
            timeout = float(step.get("timeout", args.step_timeout))
            expect = step.get("expect")
            optional = bool(step.get("optional", False))
            matched = True
            if expect:
                result = wait_for_pattern(
                    proc, master_fd, expect, timeout, raw_parts, optional=optional
                )
                matched = result is not None
            # Skip the send for an optional step whose prompt never appeared.
            if matched and "send" in step:
                os.write(master_fd, str(step["send"]).encode("utf-8"))

        deadline = time.monotonic() + float(args.exit_timeout)
        while time.monotonic() < deadline:
            raw = read_available(master_fd)
            if raw:
                raw_parts.append(raw)
            exit_code = proc.poll()
            if exit_code is not None:
                break
            time.sleep(0.05)
        else:
            raise TimeoutError("timed out waiting for process exit")

        raw = read_available(master_fd)
        if raw:
            raw_parts.append(raw)
    except Exception as exc:
        kill_process_group(proc)
        raw = read_available(master_fd)
        if raw:
            raw_parts.append(raw)
        raw_text = "".join(raw_parts)
        plain_text = strip_ansi(raw_text)
        Path(args.raw_log).write_text(raw_text)
        Path(args.plain_log).write_text(plain_text)
        print(f"wizard_pty: {exc}", file=sys.stderr)
        print(tail_lines(plain_text), file=sys.stderr)
        return 124
    finally:
        with contextlib.suppress(OSError):
            os.close(master_fd)

    raw_text = "".join(raw_parts)
    plain_text = strip_ansi(raw_text)
    Path(args.raw_log).write_text(raw_text)
    Path(args.plain_log).write_text(plain_text)

    if exit_code != args.expect_exit:
        print(
            f"wizard_pty: expected exit {args.expect_exit}, got {exit_code}",
            file=sys.stderr,
        )
        print(tail_lines(plain_text), file=sys.stderr)
        return exit_code if exit_code is not None else 125
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True)
    parser.add_argument("--steps", required=True)
    parser.add_argument("--raw-log", required=True)
    parser.add_argument("--plain-log", required=True)
    parser.add_argument("--cwd", default="/root/MediaStack")
    parser.add_argument("--step-timeout", type=float, default=10.0)
    parser.add_argument("--exit-timeout", type=float, default=30.0)
    parser.add_argument("--expect-exit", type=int, default=0)
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())

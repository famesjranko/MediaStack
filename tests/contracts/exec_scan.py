"""Find the ``docker exec`` calls in a script, for check.py's two-way exec check.

A call is ``docker exec [flags] CONTAINER COMMAND...``. The container must be
a literal service name, or a variable whose assignments in the same function
(or at file level) are all that one literal name. A variable subcommand,
``docker "${args[@]}"`` or ``docker "$kind"``, is read through the literal
array or ``for`` list that assigns it. A call that cannot be read this way is
an error, never a skip: an unread call is an unchecked touchpoint.

The command is the words after the container, up to the first shell operator
or newline. Quotes are removed; a variable stays as written, so ``"$jail"``
becomes ``$jail`` and matches no literal entry word.
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Callable
from dataclasses import dataclass, field

import inventory
from inventory import ExecEntry

EXEC_RE = re.compile(r"\bdocker[ \t]+exec\b")
# Other exec forms the docker shim does not record, so the check refuses them.
OTHER_EXEC_RE = re.compile(r"\bdocker[ \t]+(?:container|compose)\b[^\n;&|]*?[ \t]exec\b")
# A variable subcommand only in command position, so `usermod -aG docker "$USER"` is no call.
DYNAMIC_RE = re.compile(
    r"(?:^|[;&|!{(]|\b(?:then|do|else|elif|if|while|until))[ \t]*docker[ \t]+"
    r"\"?\$(?:\{(?P<braced>[A-Za-z_]\w*)(?P<array>\[@\])?\}|(?P<plain>[A-Za-z_]\w*))",
    re.MULTILINE,
)
OPERATORS = ";&|<>()\n"
VALUE_FLAGS = frozenset({"-u", "-e", "-w", "--user", "--env", "--workdir", "--env-file"})
BOOLEAN_FLAGS = frozenset(
    {"-i", "-t", "-d", "-it", "-ti", "--interactive", "--tty", "--detach", "--privileged"}
)
# The flags array of a call, as in docker exec "${tflag[@]}" -u user ...
FLAG_ARRAY_RE = re.compile(r"\$\{\w+\[@\]\}")
VARIABLE_RE = re.compile(r"\$\{?(?P<name>[A-Za-z_]\w*)\}?")
SERVICE_NAME_RE = re.compile(r"[a-z][a-z0-9-]*")
# Containers that are not services, by caller and variable, each with its reason.
NOT_SERVICES = {
    # The dry-run sandbox: a throwaway container of tests/Dockerfile.dry-run.
    ("scripts/lib/dry-run.sh", "cname"),
}


@dataclass
class ExecScan:
    """The exec entries scanned against, the calls that reached them, and errors."""

    found: list[ExecEntry]
    calls: list[tuple[ExecEntry, str]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Script:
    """One script's text and the scope of each position in it."""

    relative: str
    text: str
    scope_of: Callable[[int], int | None]


def _lexer(text: str) -> shlex.shlex:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=OPERATORS)
    lexer.whitespace = " \t"
    lexer.whitespace_split = True
    return lexer


def words(text: str) -> list[str] | None:
    """The words of one simple command, up to its first operator; None if unparseable."""
    lexer, found = _lexer(text), list[str]()
    try:
        for token in iter(lexer.get_token, lexer.eof):
            if token is None:
                break
            if token and all(char in OPERATORS for char in token):
                # A redirection's file descriptor, as in 2>&1, is not a word.
                if token[0] in "<>" and found and found[-1].isdigit():
                    found.pop()
                break
            found.append(token)
    except ValueError:
        return None
    return found


def split_exec(args: list[str]) -> tuple[str, list[str]] | None:
    """The container and command of ``docker exec`` arguments; None if unreadable."""
    index = 0
    while index < len(args) and (args[index][:1] == "-" or FLAG_ARRAY_RE.fullmatch(args[index])):
        flag = args[index]
        if flag in VALUE_FLAGS:
            index += 2
        elif flag in BOOLEAN_FLAGS or FLAG_ARRAY_RE.fullmatch(flag) or "=" in flag:
            index += 1
        else:
            return None
    if index + 1 >= len(args):
        return None
    return args[index], args[index + 1 :]


def _assigned_words(script: Script, name: str, position: int) -> set[str]:
    """Every literal value assigned to ``name`` in the scope of ``position``."""
    pattern = re.compile(rf"(?:\blocal[ \t]+)?\b{name}=(?P<value>[^\s;]*)")
    scope = script.scope_of(position)
    return {
        (words(match.group("value")) or [""])[0]
        for match in pattern.finditer(script.text)
        if script.scope_of(match.start()) == scope
    }


def _container_service(script: Script, container: str, position: int) -> str | None:
    """The service a container word names, '' for a known non-service, or None."""
    if SERVICE_NAME_RE.fullmatch(container):
        return container
    variable = VARIABLE_RE.fullmatch(container)
    if not variable:
        return None
    if (script.relative, variable.group("name")) in NOT_SERVICES:
        return ""
    values = _assigned_words(script, variable.group("name"), position)
    only = next(iter(values)) if len(values) == 1 else ""
    return only if SERVICE_NAME_RE.fullmatch(only) else None


def _resolve_program(script: Script, command: list[str], position: int) -> list[str]:
    """Read a program held in a variable, as in ffmpeg_path=/usr/lib/.../ffmpeg."""
    variable = VARIABLE_RE.fullmatch(command[0])
    if not variable:
        return command
    values = _assigned_words(script, variable.group("name"), position)
    return [next(iter(values)), *command[1:]] if len(values) == 1 else command


def _label(container: str, command: list[str]) -> str:
    shown = " ".join(command)
    return f"{container} {shown[:60]}{'...' if len(shown) > 60 else ''}"


def _record(scan: ExecScan, script: Script, args: list[str] | None, position: int) -> None:
    parsed = split_exec(args) if args is not None else None
    service = parsed and _container_service(script, parsed[0], position)
    if not parsed or service is None:
        line = script.text[position : script.text.find("\n", position)].strip()
        scan.errors.append(f"unparseable exec: {script.relative}: {line[:100]}")
        return
    if service == "":
        return
    command = _resolve_program(script, parsed[1], position)
    entry = inventory.exec_match(scan.found, service, command)
    if entry is None:
        scan.errors.append(f"missing contract: {script.relative} exec {_label(service, command)}")
    else:
        scan.calls.append((entry, script.relative))


def _is_message(text: str, start: int) -> bool:
    """Whether ``docker exec`` at ``start`` is in a comment or a double-quoted message."""
    before = text[text.rfind("\n", 0, start) + 1 : start]
    if before.lstrip().startswith("#"):
        return True
    quotes = [match.end() for match in re.finditer(r'(?<!\\)"', before)]
    # Inside an open double quote, a command substitution is still a call.
    return len(quotes) % 2 == 1 and "$(" not in before[quotes[-1] :]


def _array_words(script: Script, name: str, position: int) -> list[str] | None:
    """The literal elements of the array ``name`` as first assigned in the same scope."""
    pattern = re.compile(rf"(?:\blocal[ \t]+)?\b{name}=\(")
    scope = script.scope_of(position)
    for match in pattern.finditer(script.text):
        if script.scope_of(match.start()) == scope:
            end = script.text.find(")", match.end())
            body = script.text[match.end() : end].replace("\n", " ")
            return words(body)
    return None


def _for_words(script: Script, name: str) -> list[str] | None:
    match = re.search(rf"\bfor[ \t]+{name}[ \t]+in[ \t]+(?P<list>[^;\n]*)", script.text)
    return words(match.group("list")) if match else None


def _scan_dynamic(scan: ExecScan, script: Script) -> None:
    for match in DYNAMIC_RE.finditer(script.text):
        position = match.start()
        name = match.group("braced") or match.group("plain")
        if match.group("array"):
            elements = _array_words(script, name, position)
            if elements and elements[0] == "exec":
                _record(scan, script, elements[1:], position)
                continue
        else:
            elements = _for_words(script, name)
        if not elements or "exec" in elements or "$" in elements[0]:
            line = script.text[position : script.text.find("\n", position)].strip()
            scan.errors.append(f"unparseable exec: {script.relative}: {line[:100]}")


def scan_script(scan: ExecScan, script: Script) -> None:
    """Record each exec call of one script, or an error naming it."""
    for match in EXEC_RE.finditer(script.text):
        if not _is_message(script.text, match.start()):
            _record(scan, script, words(script.text[match.end() :]), match.start())
    for match in OTHER_EXEC_RE.finditer(script.text):
        if not _is_message(script.text, match.start()):
            line = script.text[match.start() : script.text.find("\n", match.start())]
            scan.errors.append(f"unparseable exec: {script.relative}: {line.strip()[:100]}")
    _scan_dynamic(scan, script)

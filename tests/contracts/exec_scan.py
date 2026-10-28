"""Find the ``docker exec`` calls in a script, for check.py's two-way exec check.

A call is ``docker exec [flags] CONTAINER COMMAND...``. The container must be
a literal service name, or a variable that takes only that one literal name in
the same function (or at file level). A variable subcommand, ``docker
"${args[@]}"`` or ``docker "$kind"``, is read through the one literal array or
the ``for`` lists and assignments that bind it. A call that cannot be read
this way is an error, never a skip: an unread call is an unchecked touchpoint.

The command is the words after the container, up to the first shell operator
or newline. Quotes are removed; a variable stays as written, so ``"$jail"``
becomes ``$jail`` and matches no literal entry word.

Any other line that names docker and then an exec word, such as ``docker -H x
exec``, ``$DOCKER exec`` or ``sh -c "docker exec ..."``, is an error too: a
possible call that the scan does not read. Only a comment line, or a line in
``MESSAGES`` that a reader proved runs nothing, is passed over.
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
# Words that may stand before docker in command position: a wrapper such as
# sudo or timeout, its flags and numbers, or a variable assignment.
_PREFIX_WORD = (
    r"(?:sudo|command|nohup|nice|time|timeout|env|stdbuf|exec"
    r"|\w+=\S*|-\S*|\d\S*|\$\(\([^)\n]*\)\))"
)
# A variable subcommand only in command position, so `usermod -aG docker "$USER"` is no call.
DYNAMIC_RE = re.compile(
    r"(?:^|[;&|!{(]|\b(?:then|do|else|elif|if|while|until))[ \t]*"
    rf"(?:{_PREFIX_WORD}[ \t]+)*(?P<docker>docker)[ \t]+"
    r"\"?\$(?:\{(?P<braced>[A-Za-z_]\w*)(?P<array>\[@\])?\}|(?P<plain>[A-Za-z_]\w*))",
    re.MULTILINE,
)
# docker, or a variable named for it, then an exec word later on the same line.
POSSIBLE_RE = re.compile(r"(?i:\$\{?\w*docker\w*|\bdocker\b)[^\n]*?\bexec\b")
OPERATORS = ";&|<>()\n"
VALUE_FLAGS = frozenset({"-u", "-e", "-w", "--user", "--env", "--workdir", "--env-file"})
BOOLEAN_FLAGS = frozenset(
    {"-i", "-t", "-d", "-it", "-ti", "--interactive", "--tty", "--detach", "--privileged"}
)
# The flags array of a call, as in docker exec "${tflag[@]}" -u user ...
FLAG_ARRAY_RE = re.compile(r"\$\{\w+\[@\]\}")
VARIABLE_RE = re.compile(r"\$\{?(?P<name>[A-Za-z_]\w*)\}?")
# A literal service name, and so also a literal docker subcommand.
NAME_RE = re.compile(r"[a-z][a-z0-9-]*")
# Containers that are not services, by caller and variable, each with its reason.
NOT_SERVICES = {
    # The dry-run sandbox: a throwaway container of tests/Dockerfile.dry-run.
    ("scripts/lib/dry-run.sh", "cname"),
}
# Lines that name a docker exec only in text they print, by caller and the
# line's stripped text. A line goes here only after a reader proved that it
# runs nothing; any edit to the line makes the scan read it again.
MESSAGES = frozenset(
    {
        (
            "scripts/services/npm/health.sh",
            'log_error "Unknown corruption - inspect: docker exec npm nginx -t"',
        ),
    }
)


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


def _line(text: str, position: int) -> str:
    """The whole line that holds ``position``."""
    end = text.find("\n", position)
    return text[text.rfind("\n", 0, position) + 1 : end if end >= 0 else len(text)]


def _passed_over(script: Script, position: int) -> bool:
    """Whether the line at ``position`` is a comment or a proven message."""
    line = _line(script.text, position).strip()
    return line.startswith("#") or (script.relative, line) in MESSAGES


def _is_quoted(text: str, start: int) -> bool:
    """Whether ``start`` is inside a double-quoted string on its line.

    Inside an open double quote, a command substitution is still a call, so
    that case is not quoted.
    """
    before = text[text.rfind("\n", 0, start) + 1 : start]
    quotes = [match.end() for match in re.finditer(r'(?<!\\)"', before)]
    return len(quotes) % 2 == 1 and "$(" not in before[quotes[-1] :]


def _in_scope(script: Script, position: int) -> Callable[[re.Match[str]], bool]:
    scope = script.scope_of(position)
    return lambda match: script.scope_of(match.start()) == scope


def _rebound(script: Script, name: str, position: int, appends: bool) -> bool:
    """Whether the scope also binds ``name`` in a way this scan does not follow.

    read, mapfile, getopts, printf -v, an element assignment and a nameref
    all set a value the scan cannot see. ``+=`` changes a scalar, but only
    appends to an array after the words the scan reads, so ``appends`` allows it.
    """
    forms = [
        rf"\b(?:read|mapfile|readarray|getopts|printf[ \t]+-v)\b[^\n;&|]*[ \t]{name}\b",
        rf"\b{name}\[[^]\n]*\]=",
        rf"\b(?:local|declare|typeset)[ \t]+-\w*n\w*[ \t]+{name}\b",
    ]
    if not appends:
        forms.append(rf"\b{name}\+=")
    in_scope = _in_scope(script, position)
    return any(in_scope(match) for match in re.finditer("|".join(forms), script.text))


def scalar_values(script: Script, name: str, position: int) -> list[str] | None:
    """Every literal value ``name`` takes in the scope of ``position``, in order.

    The values are the first word of each assignment and each word of each
    ``for`` list. None when the scope binds the name another way, or loops
    over the positional arguments with ``for name; do``.
    """
    if _rebound(script, name, position, appends=False):
        return None
    in_scope = _in_scope(script, position)
    assigned = re.compile(rf"(?:\blocal[ \t]+)?\b{name}=(?P<value>[^\s;]*)")
    values = [
        (words(match.group("value")) or [""])[0]
        for match in assigned.finditer(script.text)
        if in_scope(match)
    ]
    loops = re.compile(rf"\b(?:for|select)[ \t]+{name}\b(?:[ \t]+in\b(?P<list>[^;\n]*))?")
    for match in filter(in_scope, loops.finditer(script.text)):
        listed = words(match.group("list")) if match.group("list") is not None else None
        if listed is None:
            return None
        values += listed
    return values


def _one_value(script: Script, name: str, position: int) -> str | None:
    """The single literal value of ``name``, or None when it may take another."""
    values = scalar_values(script, name, position)
    if values is None or len(set(values)) != 1:
        return None
    return values[0]


def _container_service(script: Script, container: str, position: int) -> str | None:
    """The service a container word names, '' for a known non-service, or None."""
    if NAME_RE.fullmatch(container):
        return container
    variable = VARIABLE_RE.fullmatch(container)
    if not variable:
        return None
    if (script.relative, variable.group("name")) in NOT_SERVICES:
        return ""
    only = _one_value(script, variable.group("name"), position)
    return only if only and NAME_RE.fullmatch(only) else None


def _resolve_program(script: Script, command: list[str], position: int) -> list[str]:
    """Read a program held in a variable, as in ffmpeg_path=/usr/lib/.../ffmpeg."""
    variable = VARIABLE_RE.fullmatch(command[0])
    only = variable and _one_value(script, variable.group("name"), position)
    return [only, *command[1:]] if only else command


def _label(container: str, command: list[str]) -> str:
    shown = " ".join(command)
    return f"{container} {shown[:60]}{'...' if len(shown) > 60 else ''}"


def _error(scan: ExecScan, script: Script, kind: str, position: int) -> None:
    end = script.text.find("\n", position)
    line = script.text[position : end if end >= 0 else len(script.text)].strip()
    scan.errors.append(f"{kind}: {script.relative}: {line[:100]}")


def _record(scan: ExecScan, script: Script, args: list[str] | None, position: int) -> None:
    parsed = split_exec(args) if args is not None else None
    service = parsed and _container_service(script, parsed[0], position)
    if not parsed or service is None:
        _error(scan, script, "unparseable exec", position)
        return
    if service == "":
        return
    command = _resolve_program(script, parsed[1], position)
    entry = inventory.exec_match(scan.found, service, command)
    if entry is None:
        scan.errors.append(f"missing contract: {script.relative} exec {_label(service, command)}")
    else:
        scan.calls.append((entry, script.relative))


def _array_words(script: Script, name: str, position: int) -> list[str] | None:
    """The literal elements of the array ``name``, assigned exactly once in the scope."""
    if _rebound(script, name, position, appends=True):
        return None
    pattern = re.compile(rf"(?:\blocal[ \t]+)?\b{name}=\(")
    matches = list(filter(_in_scope(script, position), pattern.finditer(script.text)))
    if len(matches) != 1:
        return None
    end = script.text.find(")", matches[0].end())
    return words(script.text[matches[0].end() : end].replace("\n", " "))


def _readable_subcommand(script: Script, match: re.Match[str], elements: list[str] | None) -> bool:
    """Whether a variable subcommand is read and is never exec."""
    if match.group("array"):
        # Only the first element is the subcommand; exec in a later one may
        # follow a global flag, as in (-H host exec ...).
        subcommands = elements[:1] if elements and "exec" not in elements else []
    else:
        name = match.group("plain") or match.group("braced")
        subcommands = scalar_values(script, name, match.start("docker")) or []
    return bool(subcommands) and all(
        NAME_RE.fullmatch(word) and word != "exec" for word in subcommands
    )


def _scan_dynamic(scan: ExecScan, script: Script) -> None:
    for match in DYNAMIC_RE.finditer(script.text):
        position = match.start("docker")
        if _passed_over(script, position):
            continue
        name = match.group("braced")
        elements = _array_words(script, name, position) if match.group("array") else None
        if elements and elements[0] == "exec":
            _record(scan, script, elements[1:], position)
        elif not _readable_subcommand(script, match, elements):
            _error(scan, script, "unparseable exec", position)


def scan_script(scan: ExecScan, script: Script) -> None:
    """Record each exec call of one script, or an error naming it."""
    read: set[int] = set()
    for match in EXEC_RE.finditer(script.text):
        read.add(match.start())
        if _passed_over(script, match.start()):
            continue
        if _is_quoted(script.text, match.start()):
            _error(scan, script, "possible exec call not parsed", match.start())
        else:
            _record(scan, script, words(script.text[match.end() :]), match.start())
    for match in OTHER_EXEC_RE.finditer(script.text):
        read.add(match.start())
        if not _passed_over(script, match.start()):
            _error(scan, script, "unparseable exec", match.start())
    _scan_dynamic(scan, script)
    for match in POSSIBLE_RE.finditer(script.text):
        if match.start() not in read and not _passed_over(script, match.start()):
            _error(scan, script, "possible exec call not parsed", match.start())

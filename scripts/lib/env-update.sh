# =============================================================================
# MediaStack .env updater: atomic KEY=value rewrites and API-key persistence
# =============================================================================
# Owns: _env_write_kv (the one .env-mutation primitive), _env_write_kv_warn
# (shared failure-to-log_warn mapping), and env_save_api_key (the configure-time
# convenience wrapper). Sourced by scripts/lib/common.sh so every existing
# common.sh consumer keeps these names with zero call-site churn.
# Depends on log_warn/log_ok (common.sh) and $SCRIPT_DIR being exported by
# the caller, same contract as the rest of common.sh.

[[ -n "${_MS_ENV_WRITE_SH:-}" ]] && return 0
_MS_ENV_WRITE_SH=1

# General-purpose, hardened "rewrite KEY=value line(s) in .env" primitive.
#
#   _env_write_kv <env_file> <key> <value> [<key> <value> ...]
#
# Takes one or more key->value pairs and applies them all in a SINGLE atomic
# read-modify-write. Single-quotes each value (so spaces, $, \, #, =, ", and
# leading/trailing whitespace round-trip byte-exact when the file is
# re-sourced), rewrites each matching key in place (or appends if absent, in
# argument order) via an atomic temp-file replace that preserves the file mode,
# and leaves every unrelated line untouched. Refuses the WHOLE write (file left
# exactly as it was) if any value contains a single quote or a newline, or any
# key name is invalid. Echoes ONE aggregate status word and returns non-zero on
# failure:
#   changed | unchanged                              -> rc 0
#   invalid-args | invalid-key | invalid-newline
#   invalid-quote | read-error:<reason>
#   write-error:<reason>                             -> rc non-zero
# Side-effect-free beyond the file write: it does NOT log or export — callers
# decide how to surface the outcome. This is the one .env-mutation writer;
# env_save_api_key, the launcher's _set_env_var, storage_env_set, and the stage2/
# stage3 rewriters all route through it (no second hand-rolled implementation).
_env_write_kv() {
    local env_file="$1"
    shift
    python3 - "$env_file" "$@" <<'PY'
import os
import pathlib
import re
import shlex
import stat
import sys
import tempfile

env_path = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
if not args or len(args) % 2 != 0:
    print("invalid-args")
    sys.exit(2)

pairs = list(zip(args[0::2], args[1::2]))

# Validate every key/value up front so a single bad pair refuses the WHOLE
# write — the file is never left half-updated.
for key, value in pairs:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        print("invalid-key")
        sys.exit(2)
    if "\n" in value or "\r" in value:
        print("invalid-newline")
        sys.exit(3)
    if "'" in value:
        print("invalid-quote")
        sys.exit(4)

# A repeated key: last assignment wins (dict semantics).
targets = {key: value for key, value in pairs}
encoded = {key: f"{key}='{value}'\n" for key, value in targets.items()}

try:
    original = env_path.read_text()
    env_stat = env_path.stat()
except OSError as exc:
    print(f"read-error:{exc.strerror or exc.__class__.__name__}")
    sys.exit(5)

lines = original.splitlines(keepends=True)
changed = False
found = set()
new_lines = []

for line in lines:
    body = line[:-1] if line.endswith("\n") else line
    matched = None
    for key in targets:
        if body.startswith(f"{key}="):
            matched = key
            break
    if matched is None:
        new_lines.append(line)
        continue
    found.add(matched)
    raw_current = body.split("=", 1)[1]
    try:
        parsed = shlex.split(raw_current, posix=True)
        current = parsed[0] if parsed else ""
    except ValueError:
        current = None
    if current == targets[matched] and line == encoded[matched]:
        new_lines.append(line)
    else:
        new_lines.append(encoded[matched])
        changed = True

for key in encoded:
    if key not in found:
        if new_lines and not new_lines[-1].endswith("\n"):
            new_lines[-1] += "\n"
        new_lines.append(encoded[key])
        changed = True

if not changed:
    print("unchanged")
    sys.exit(0)

tmp_name = ""
try:
    fd, tmp_name = tempfile.mkstemp(
        prefix=f"{env_path.name}.tmp.",
        dir=str(env_path.parent),
        text=True,
    )
    with os.fdopen(fd, "w") as tmp:
        os.fchmod(tmp.fileno(), stat.S_IMODE(env_stat.st_mode) or 0o600)
        tmp.writelines(new_lines)
    os.replace(tmp_name, env_path)
except OSError as exc:
    if tmp_name:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
    print(f"write-error:{exc.strerror or exc.__class__.__name__}")
    sys.exit(6)

print("changed")
PY
}

# Map an _env_write_kv failure status to a user-facing log_warn line. Shared by
# the writer's callers so the refusal/error messages stay consistent.
_env_write_kv_warn() {
    local key_name="$1" status="$2"
    case "$status" in
        invalid-key)
            log_warn "Refusing to save invalid .env key name: ${key_name}"
            ;;
        invalid-newline)
            log_warn "Refusing to save ${key_name} to .env: value contains a newline"
            ;;
        invalid-quote)
            log_warn "Refusing to save ${key_name} to .env: value contains a single quote"
            ;;
        read-error:* | write-error:*)
            log_warn "Failed to save ${key_name} to .env (${status#*:})"
            ;;
        *)
            log_warn "Failed to save ${key_name} to .env"
            ;;
    esac
}

env_save_api_key() {
    local key_name="$1" key_value="$2" env_file="$SCRIPT_DIR/.env"
    [[ -f "$env_file" ]] || return

    local writer_status
    if ! writer_status=$(_env_write_kv "$env_file" "$key_name" "$key_value"); then
        _env_write_kv_warn "$key_name" "$writer_status"
        return 1
    fi

    if [[ "$writer_status" == "changed" ]]; then
        log_ok "Saved ${key_name} to .env"
    fi
    # Export to the live shell too — later steps in the same configure.sh
    # invocation can then read the value without needing to re-source .env.
    export "${key_name}=${key_value}"
}

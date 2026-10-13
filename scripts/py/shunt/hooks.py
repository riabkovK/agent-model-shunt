"""Claude Code hooks: check-file-size, check-bash-read (PreToolUse) and session-start.

Port of hooks/check-file-size, hooks/check-bash-read and hooks/session-start-orchestrator.
The PreToolUse hooks run on every Read and Bash call, so the common path imports nothing
beyond os, sys and the C JSON scanner (no re, typing or argparse). The tool input is untrusted:
it is read with a cap, parsed as JSON only, never passed to a shell, and any failure allows
the call (fail open, exit 0).
"""

from __future__ import annotations

import os
import stat
import sys

TYPE_CHECKING = False  # `import typing` costs ~2 ms per hook call
if TYPE_CHECKING:
    from collections.abc import Mapping
    from typing import Any

MAX_STDIN_BYTES = 1 << 20
READ_CHUNK = 1 << 20
DEFAULT_MIN_LINES = 350
MAX_MIN_LINES_DIGITS = 18  # more digits than this means "no file is that long"
HOOKS_OFF_VALUES = ("1", "true", "TRUE", "yes", "YES")
ALLOW = '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
DENY = ('{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", '
        '"permissionDecisionReason": "%s"}}')
READ_ADVICE = ("Use the /bulk-reader skill to delegate this read to a custom model instead of reading it "
               "directly. If you need exact content for editing, re-read with an offset/limit for just the "
               "section you need.")
BASH_ADVICE = "Use the /bulk-reader skill to delegate this read to a custom model instead of cat/head/tail."
_READERS = ("cat ", "head ", "tail ", "less ", "more ")
_FLAGS_WITH_VALUE = ("-n", "-c")
JSON_SPACE = " \t\n\r"


def threshold(environ: Mapping[str, str]) -> int:
    """SHUNT_MIN_LINES when it is all ASCII digits, else 350."""
    text = environ.get("SHUNT_MIN_LINES", "")
    if not text or not text.isascii() or not text.isdigit():
        return DEFAULT_MIN_LINES
    return int(text) if len(text.lstrip("0")) <= MAX_MIN_LINES_DIGITS else 10**MAX_MIN_LINES_DIGITS


def count_lines(path: str) -> int | None:
    """Newline count of a regular file (symlinks followed), None when it is not one or cannot be read."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    except (OSError, ValueError):
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        total = 0
        while True:
            chunk = os.read(fd, READ_CHUNK)
            if not chunk:
                return total
            total += chunk.count(b"\n")
    except OSError:
        return None
    finally:
        os.close(fd)


def _no_constant(name: str) -> Any:
    raise ValueError(name)  # NaN and Infinity are not JSON


class _ScanContext:
    """The attributes _json's C scanner reads. Plain JSON, no hooks."""

    strict = True
    object_hook = None
    object_pairs_hook = None
    parse_float = float
    parse_int = int
    parse_constant = staticmethod(_no_constant)
    memo: dict[Any, Any] = {}


def parse_json(text: str) -> Any:
    """json.loads for one JSON document. `import json` pulls in `re` and costs ~5 ms per hook call,
    so the C scanner behind it is used directly, with `json` as the fallback."""
    try:
        from _json import make_scanner
        scan = make_scanner(_ScanContext)
    except (ImportError, TypeError, AttributeError):
        import json
        return json.loads(text)
    body = text.lstrip(JSON_SPACE)
    try:
        value, end = scan(body, 0)
    except StopIteration:
        raise ValueError("no JSON value") from None
    if body[end:].strip(JSON_SPACE):
        raise ValueError("trailing data")
    return value


def tool_input(stdin_fd: int = 0) -> dict[str, Any]:
    """The tool_input object of the hook payload, {} when the payload is missing or malformed."""
    try:
        data = b""
        while len(data) < MAX_STDIN_BYTES:
            chunk = os.read(stdin_fd, min(READ_CHUNK, MAX_STDIN_BYTES - len(data)))
            if not chunk:
                break
            data += chunk
        payload = parse_json(data.decode("utf-8"))
    except (OSError, ValueError, RecursionError):
        return {}
    value = payload.get("tool_input") if isinstance(payload, dict) else None
    return value if isinstance(value, dict) else {}


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _is_set(value: Any) -> bool:
    """jq's `// empty` followed by a non-empty test: null, false and "" count as unset."""
    return value is not None and value is not False and value != ""


def _hooks_disabled(environ: Mapping[str, str]) -> bool:
    return environ.get("SHUNT_HOOKS_DISABLED") in HOOKS_OFF_VALUES


def _delegate_available() -> bool:
    """False only when a registry exists and every delegate is unusable (no candidates or all breakers open)."""
    # Same default as env.models_file_text. Checked first so the no-registry path imports nothing.
    path = os.environ.get("SHUNT_MODELS_FILE") or os.environ.get("HOME", "") + "/.config/agent-model-shunt/models.json"
    if not os.path.isfile(path):
        return True
    from . import breaker, models
    if not models.available(path):
        return True
    try:
        unknown, ids = models.candidates(path, "bulk-read")
        if unknown:
            sys.stderr.write(f"shunt: models registry's active model '{unknown}' is not in the models "
                             "list; falling back to priority order.\n")
        return bool(ids) and breaker.any_closed(os.environ, ids)
    except (models.RegistryUnreadable, OSError, ValueError):
        return False


def decide_read(tool: Mapping[str, Any], environ: Mapping[str, str]) -> str:
    """The hook's JSON answer for a Read call."""
    if _hooks_disabled(environ) or _is_set(tool.get("offset")) or _is_set(tool.get("limit")):
        return ALLOW
    path = _text(tool.get("file_path"))
    if not path:
        return ALLOW
    lines = count_lines(path)
    limit = threshold(environ)
    if lines is None or lines <= limit:
        return ALLOW
    if not _delegate_available():
        return ALLOW
    return DENY % f"File is {lines} lines (threshold: {limit}). {READ_ADVICE}"


def file_argument(command: str) -> str:
    """The first file operand of a plain cat/head/tail/less/more command, else ""."""
    lines = command.split("\n")
    if not any(line.startswith(_READERS) for line in lines):
        return ""
    stripped = [line[line.index(" "):].lstrip(" ") if line.startswith(_READERS) else line for line in lines]
    operands = [w for w in "\n".join(stripped).replace("\t", " ").replace("\n", " ").split(" ") if w]
    skip_next = False
    for operand in operands:
        if skip_next:
            skip_next = False
        elif operand in _FLAGS_WITH_VALUE:
            skip_next = True
        elif not operand.startswith("-"):
            return operand.replace('"', "").replace("'", "")
    return ""


def decide_bash(tool: Mapping[str, Any], environ: Mapping[str, str]) -> str:
    """The hook's JSON answer for a Bash call."""
    if _hooks_disabled(environ):
        return ALLOW
    command = _text(tool.get("command"))
    if not command or "|" in command or ">" in command:
        return ALLOW
    path = file_argument(command)
    lines = count_lines(path) if path else None
    limit = threshold(environ)
    if lines is None or lines <= limit:
        return ALLOW
    return DENY % f"File is {lines} lines (threshold: {limit}). {BASH_ADVICE}"


def session_start(environ: Mapping[str, str]) -> str:
    """The SessionStart JSON (jq -n layout), or "" when nothing should be injected."""
    from . import models, orchestrator
    try:
        text = orchestrator.render(environ)
    except (models.RegistryUnreadable, OSError, ValueError):
        return ""
    if not text:
        return ""
    import json
    doc = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def _answer(name: str) -> str:
    if name == "session-start":
        return session_start(os.environ)
    decide = decide_read if name == "check-file-size" else decide_bash
    return decide(tool_input(), os.environ) + "\n"


def main(argv: list[str], unusable: str | None = None) -> int:
    """Print the hook's answer. Always exit 0: a broken hook must not block a tool call or a session.

    `unusable` is the interpreter problem reported by shunt_main (too old): warn and do nothing.
    """
    name = argv[0] if argv else ""
    try:
        if unusable:
            sys.stderr.write(unusable + "\n")
            raise RuntimeError(unusable)
        out = _answer(name)
    except Exception:  # noqa: BLE001  fail open: the hooks only save tokens, they are not a security gate
        out = "" if name == "session-start" else ALLOW + "\n"
    try:
        if out:
            sys.stdout.buffer.write(out.encode("utf-8", errors="surrogateescape"))
            sys.stdout.buffer.flush()
    except OSError:
        pass  # the reader went away
    return 0

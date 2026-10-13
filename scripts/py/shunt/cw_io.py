"""Output helpers of code-write: exact bytes on stdout and stderr, clean text, bash-style %q quoting.

Arguments and paths come in as str with surrogate escapes (os.fsdecode). They go out through the
binary streams with the same escapes undone, so a name with odd bytes is printed as it is, never
re-encoded and never as a traceback.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Mapping

from . import cw_text

_CNTRL = bytes([*range(0x20), 0x7F])  # tr -d '[:cntrl:]' in the C locale
_ANSI = {7: "\\a", 8: "\\b", 27: "\\E", 12: "\\f", 10: "\\n", 13: "\\r", 9: "\\t", 11: "\\v", 92: "\\\\", 39: "\\'"}
_BACKSLASHED = " ,^'\"\\!`$*{}[]()?<>&;|"  # bash printf %q puts a backslash before these
_FIRST_ONLY = "#~"  # and before these only at the start of the word


class Stop(Exception):
    """End the call. `message` is the stderr text, already complete (it may be empty)."""

    def __init__(self, message: str = "", status: int = 1) -> None:
        super().__init__(message)
        self.message = message
        self.status = status


def fail(text: str) -> Stop:
    """A `shunt:` line and exit status 1, the old shunt_report_error."""
    return Stop(f"shunt: {text}")


def _write(stream: object, text: str) -> None:
    data = os.fsencode(text)
    buffer = stream.buffer  # type: ignore[attr-defined]
    buffer.write(data)
    buffer.flush()


def err(text: str) -> None:
    sys.stdout.flush()
    _write(sys.stderr, text + "\n")


def out(text: str) -> None:
    sys.stderr.flush()
    _write(sys.stdout, text + "\n")


def out_bytes(data: bytes) -> None:
    sys.stdout.flush()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def clean(text: str) -> str:
    """The text without control characters and without the invisible ones, controls first."""
    raw = os.fsencode(text).translate(None, _CNTRL)
    return os.fsdecode(cw_text.strip_invisible(raw))


def _is_utf8_locale(environ: Mapping[str, str]) -> bool:
    for name in ("LC_ALL", "LC_CTYPE", "LANG"):
        value = environ.get(name, "")
        if value:
            return "utf-8" in value.lower() or "utf8" in value.lower()
    return False


def _printable(text: str) -> bool:
    return all(c.isprintable() for c in text)


def quote(raw: bytes, environ: Mapping[str, str] | None = None) -> str:
    """Bash `printf %q`: backslashes for shell characters, $'...' when something is not printable.

    Non-ASCII text counts as printable only in a UTF-8 locale. A non-printable character outside
    ASCII is written as octal bytes (bash 5 would use \\u escapes for some of them).
    """
    if not raw:
        return "''"
    utf8 = _is_utf8_locale(os.environ if environ is None else environ)
    text = None
    if utf8:
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = None
    printable = bool(text is not None and _printable(text)) if utf8 else all(0x20 <= b < 0x7F for b in raw)
    if printable and text is not None:
        return _backslash(text)
    if printable:
        return _backslash(raw.decode("ascii"))
    return "$'" + _ansi(raw, text) + "'"


def _backslash(text: str) -> str:
    pieces = []
    for index, char in enumerate(text):
        if char in _BACKSLASHED or (index == 0 and char in _FIRST_ONLY):
            pieces.append("\\")
        pieces.append(char)
    return "".join(pieces)


def _ansi(raw: bytes, text: str | None) -> str:
    if text is not None:  # a UTF-8 locale: printable characters stay as they are
        return "".join(_ansi_char(c) for c in text)
    return "".join(_ansi_byte(b) for b in raw)


def _ansi_char(char: str) -> str:
    if ord(char) < 0x80:
        return _ansi_byte(ord(char))
    if char.isprintable():
        return char
    return "".join(f"\\{b:03o}" for b in char.encode("utf-8"))


def _ansi_byte(value: int) -> str:
    if value in _ANSI:
        return _ANSI[value]
    if 0x20 <= value < 0x7F:
        return chr(value)
    return f"\\{value:03o}"

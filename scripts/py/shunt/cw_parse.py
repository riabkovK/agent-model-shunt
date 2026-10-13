"""Response protocol of code-write: split a model reply into notes and code, and normalize a path.

Protocol, every tag on a line of its own: SHUNT-NOTES open and close, then SHUNT-CODE
open and close. Tags are whole-line exact matches (one trailing CR tolerated), exactly
one of each, in that order. Only blank lines may come before the first tag, between the
sections and after the closing code tag. Only an outer markdown fence around the whole
code section is removed. All of it works on bytes, as the old awk did under LC_ALL=C.
"""

import os
import re
from dataclasses import dataclass

from . import cw_text

EXIT_OK = 0
EXIT_REFUSAL = 10  # empty code with non-empty notes: not a model failure
EXIT_UNUSABLE = 11  # a model failure (failover and breaker)
DEFAULT_MAX_CODE_BYTES = 262144
DEFAULT_MAX_NOTES_BYTES = 32768
RESPONSE_SLACK_BYTES = 4096  # tag lines, fence lines and CRLF on top of the two caps
MIN_FENCE = 3

_NOTES_OPEN, _NOTES_CLOSE = b"<SHUNT-NOTES>", b"</SHUNT-NOTES>"
_CODE_OPEN, _CODE_CLOSE = b"<SHUNT-CODE>", b"</SHUNT-CODE>"
_BLANK = re.compile(rb"[ \t\r]*")
_FENCE_OPEN = re.compile(rb"(`+)([^`]*)")
_FENCE_CLOSE = re.compile(rb"`+")
_TRAILING_WS = re.compile(rb"[ \t\r]+$")


@dataclass
class _Scan:
    """What one pass over the lines found."""

    notes: list[bytes]
    code: list[bytes]
    count: dict[bytes, int]
    first: dict[bytes, int]
    text_in: set[int]  # sections (0 before, 2 between, 4 after) that hold non-blank text


def _blank(line: bytes) -> bool:
    return _BLANK.fullmatch(line) is not None


def _lines(data: bytes) -> list[bytes]:
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()  # awk sees no extra empty record after the last newline
    return lines


def _scan(lines: list[bytes]) -> _Scan:
    tag_section = {_NOTES_OPEN: 1, _NOTES_CLOSE: 2, _CODE_OPEN: 3, _CODE_CLOSE: 4}
    found = _Scan([], [], dict.fromkeys(tag_section, 0), {}, set())
    section = 0
    for number, line in enumerate(lines, 1):
        tag = line[:-1] if line.endswith(b"\r") else line
        if tag in tag_section:
            found.count[tag] += 1
            found.first.setdefault(tag, number)
            section = tag_section[tag]
        elif section == 1:
            found.notes.append(line)
        elif section == 3:
            found.code.append(line)
        elif not _blank(line):
            found.text_in.add(section)
    return found


def _structure_error(found: _Scan) -> str:
    """The first protocol violation in the fixed order the old awk reported them, else ''."""
    count, first = found.count, found.first
    if not count[_NOTES_OPEN]:
        return "missing-notes-delimiter"
    if not count[_CODE_OPEN]:
        return "missing-code-delimiter"
    if not count[_NOTES_CLOSE] or not count[_CODE_CLOSE]:
        return "missing-closing-tag"
    if count[_NOTES_OPEN] > 1:
        return "duplicate-notes-delimiter"
    if count[_CODE_OPEN] > 1:
        return "duplicate-code-delimiter"
    if count[_NOTES_CLOSE] > 1 or count[_CODE_CLOSE] > 1:
        return "duplicate-closing-tag"
    if not first[_NOTES_OPEN] < first[_NOTES_CLOSE] < first[_CODE_OPEN] < first[_CODE_CLOSE]:
        return "out-of-order"
    for section, reason in ((0, "text-before-delimiter"), (2, "text-between-sections"), (4, "text-after-closing-tag")):
        if section in found.text_in:
            return reason
    return ""


def _unfence(code: list[bytes]) -> list[bytes]:
    """Drop ONLY an outer fence: an opening run of 3+ backticks and a closing run at least as long."""
    filled = [i for i, line in enumerate(code) if not _blank(line)]
    if len(filled) < 2:
        return code
    first, last = filled[0], filled[-1]
    opening = _FENCE_OPEN.fullmatch(_TRAILING_WS.sub(b"", code[first]))
    closing = _TRAILING_WS.sub(b"", code[last])
    if opening and len(opening.group(1)) >= MIN_FENCE and not opening.group(2).count(b"`") \
            and _FENCE_CLOSE.fullmatch(closing) and len(closing) >= len(opening.group(1)):
        return code[first + 1:last]
    return code


def _size(lines: list[bytes]) -> int:
    return sum(len(line) + 1 for line in lines)


def _write(path: bytes, lines: list[bytes]) -> None:
    with open(path, "wb") as handle:
        handle.write(b"".join(line + b"\n" for line in lines))


def _split(data: bytes, max_notes: int, max_code: int) -> tuple[str, list[bytes], list[bytes]]:
    found = _scan(_lines(data))
    reason = _structure_error(found)
    if reason:
        return reason, [], []
    code = _unfence(found.code)
    notes_empty = all(_blank(line) for line in found.notes)
    code_empty = all(_blank(line) for line in code)
    if _size(found.notes) > max_notes:
        return "oversize", [], []
    if code_empty and notes_empty:
        return "empty-code", [], []
    if _size(code) > max_code:
        return "oversize", [], []
    return ("deliberate-refusal" if code_empty else "ok"), found.notes, code


def _env_limit(name: str, default: int) -> int:
    return cw_text.limit(os.environ.get(name, ""), default)


def _remove(out_dir: bytes) -> None:
    for name in (b"code", b"notes"):
        try:
            os.unlink(os.path.join(out_dir, name))
        except FileNotFoundError:
            pass


def _code_reason(path: bytes) -> str:
    return (cw_text.check_code_controls(path) or cw_text.check_invisible(path)
            or cw_text.check_protocol_tags(path))


def parse(response: bytes, out_dir: bytes) -> tuple[str, int]:
    """Split the reply into out_dir/notes and out_dir/code. Returns (reason token, exit status)."""
    _remove(out_dir)
    max_code = _env_limit("SHUNT_CW_MAX_CODE_BYTES", DEFAULT_MAX_CODE_BYTES)
    max_notes = _env_limit("SHUNT_CW_MAX_NOTES_BYTES", DEFAULT_MAX_NOTES_BYTES)
    with open(response, "rb") as handle:
        data = handle.read()
    if not data:
        return "empty-response", EXIT_UNUSABLE
    if len(data) > max_code + max_notes + RESPONSE_SLACK_BYTES:
        return "oversize", EXIT_UNUSABLE
    reason = cw_text.check_text(response)
    if reason:
        return reason, EXIT_UNUSABLE
    reason, notes, code = _split(data, max_notes, max_code)
    if reason not in ("ok", "deliberate-refusal"):
        return reason, EXIT_UNUSABLE
    notes_path, code_path = os.path.join(out_dir, b"notes"), os.path.join(out_dir, b"code")
    try:
        _write(notes_path, notes)
        _write(code_path, code if reason == "ok" else [])
        # Hidden characters, a lone CR, a form feed and a tag line are refused in the code only.
        bad = _code_reason(code_path) if reason == "ok" else ""
    except BaseException:
        _remove(out_dir)
        raise
    if bad:
        _remove(out_dir)
        return bad, EXIT_UNUSABLE
    return reason, EXIT_OK if reason == "ok" else EXIT_REFUSAL


def normalize_path(path: bytes) -> bytes:
    """Lexical clean-up: drop '.' and empty segments, collapse 'a/..'. Symlinks are not looked at.

    An absolute path cannot climb above '/'. A relative one keeps the '..' it cannot
    collapse and becomes '.' when nothing is left. An empty path, one ending in a slash
    and one with control characters come back unchanged (the strict target check refuses them).
    """
    if cw_text.has_unsafe_chars(path) or path == b"" or path.endswith(b"/"):
        return path
    absolute = path.startswith(b"/")
    parts: list[bytes] = []
    for part in path.split(b"/"):
        if part in (b"", b"."):
            continue
        if part != b"..":
            parts.append(part)
        elif parts and parts[-1] != b"..":
            parts.pop()
        elif not absolute:
            parts.append(part)
    joined = b"/".join(parts)
    if absolute:
        return b"/" + joined
    return joined or b"."

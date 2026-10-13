"""Text gates of code-write (port of the first half of scripts/lib/codewrite.sh).

Everything works on raw bytes, never on a locale dependent str, so the answer is
the same under any LC_ALL. The delegate model only returns text, and these
checks decide what text may end up in a file or in a printed line: control and
invisible characters, bidirectional overrides, invalid UTF-8 and look-alikes of
the response protocol tags.
"""

import re

MAX_DIGITS = 15  # a larger number is not trusted as a limit

# Byte patterns of everything strip_invisible removes (UTF-8 encoded).
_INVISIBLE = re.compile(
    rb"\xc2[\x80-\x9f\xad]"  # C1 controls, soft hyphen
    rb"|\xcd\x8f"  # grapheme joiner
    rb"|\xd8\x9c"  # Arabic letter mark
    rb"|\xe1\x85[\x9f\xa0]"  # Hangul fillers
    rb"|\xe1\x9e[\xb4\xb5]"  # Khmer inherent vowels
    rb"|\xe1\xa0\x8e"  # Mongolian vowel separator
    rb"|\xe2\x80[\x8b-\x8f\xa8-\xae]"  # zero width, marks, separators, bidi
    rb"|\xe2\x81[\xa0-\xaf]"  # word joiner, invisible operators, bidi isolates
    rb"|\xe2\xa0\x80"  # Braille blank
    rb"|\xe3\x85\xa4"  # Hangul filler
    rb"|\xef\xb8[\x80-\x8f]"  # variation selectors
    rb"|\xef\xbb\xbf"  # BOM
    rb"|\xef\xbe\xa0"  # halfwidth Hangul filler
    rb"|\xef\xbf[\xb9-\xbb]"  # interlinear annotation
    rb"|\xf0\x9d\x85[\xb3-\xba]"  # musical formatting
    rb"|\xf3\xa0[\x80\x81\x84-\x86][\x80-\xbf]"  # Tag block and variation selectors supplement
    rb"|\xf3\xa0\x87[\x80-\xaf]")
_ALLOWED_IN_CODE = (b"\xe2\x80\x8c", b"\xe2\x80\x8d", b"\xef\xb8\x8f")  # ZWNJ, ZWJ, U+FE0F
_C0_UNSAFE = re.compile(rb"[\x00-\x1f\x7f]")
_C1 = re.compile(rb"\xc2[\x80-\x9f]")
_BIDI = re.compile(rb"\xe2\x80[\xaa-\xae]|\xe2\x81[\xa6-\xa9]")
_RAW_CONTROLS = re.compile(rb"[\x01-\x08\x0b\x0e-\x1f\x7f]")  # all but NUL, tab, LF, FF, CR
_PROTOCOL_TAG = re.compile(rb"[ \t\r]*<{0,3}/?SHUNT-(?:CODE|NOTES)>{0,3}[ \t\r]*", re.IGNORECASE)


def strip_invisible(text: bytes) -> bytes:
    """Drop the characters that hide or reorder what a reader sees.

    Runs to a fixed point: removing one sequence can join the bytes around it
    into a new one, and a single pass would leave that behind.
    """
    while True:
        stripped = _INVISIBLE.sub(b"", text)
        if stripped == text:
            return text
        text = stripped


def has_unsafe_chars(text: bytes) -> bool:
    """True for a C0 control, DEL, or any character strip_invisible removes."""
    return bool(_C0_UNSAFE.search(text)) or strip_invisible(text) != text


def limit(value: str, default: int) -> int:
    """A plain decimal of at most 15 digits, else the default."""
    if re.fullmatch(r"[0-9]{1,%d}" % MAX_DIGITS, value):
        return int(value)
    return default


def _read(path: str) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def check_text(path: str) -> str:
    """Reason token for a file with NUL, control, C1, bidi or invalid UTF-8, else ''."""
    data = _read(path)
    if data is None:
        return "invalid-utf8"
    if b"\x00" in data:
        return "nul-bytes"
    if _RAW_CONTROLS.search(data) or _C1.search(data):
        return "control-characters"
    try:
        data.decode("utf-8")  # strict: no surrogates, no overlongs, nothing above U+10FFFF
    except UnicodeDecodeError:
        return "invalid-utf8"
    if _BIDI.search(data):
        return "bidi-controls"
    return ""


def check_code_controls(path: str) -> str:
    """'control-characters' for a form feed or a CR that is not part of CRLF.

    A final CR counts as lone. An unreadable file counts as a hit.
    """
    data = _read(path)
    if data is None:
        return "control-characters"
    rest = (data + b"x").replace(b"\r\n", b"")
    if b"\r" in rest or b"\f" in rest:
        return "control-characters"
    return ""


def check_invisible(path: str) -> str:
    """'invisible-characters' when the code holds a strip_invisible character.

    ZWNJ, ZWJ and U+FE0F stay allowed (emoji sequences, some scripts). The
    caller has checked for valid UTF-8, so removing them cannot join bytes.
    """
    data = _read(path)
    if data is None:
        return "invisible-characters"
    kept = data
    for allowed in _ALLOWED_IN_CODE:
        kept = kept.replace(allowed, b"")
    return "invisible-characters" if strip_invisible(kept) != kept else ""


def check_protocol_tags(path: str) -> str:
    """'protocol-tag-in-code' when a whole line looks like a protocol tag.

    0 to 3 "<", an optional "/", SHUNT-CODE or SHUNT-NOTES in any case, 0 to 3
    ">", spaces, tabs and CRs around. An unreadable file counts as a hit.
    """
    data = _read(path)
    if data is None:
        return "protocol-tag-in-code"
    for line in data.split(b"\n"):
        if _PROTOCOL_TAG.fullmatch(line):
            return "protocol-tag-in-code"
    return ""

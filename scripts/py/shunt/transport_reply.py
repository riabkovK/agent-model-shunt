"""Reply side of the HTTP transport: the status codes, the safe error excerpt and
the normalized chat completion.

Port of `_shunt_http_excerpt`, `_shunt_http_normalize` and the JSON part of
`_shunt_http_check_reply` from scripts/lib/transport-http.sh. The request key is
only ever used here to scrub it out of text that goes to stderr.
"""

from __future__ import annotations

import json
import math
import re
import unicodedata
from typing import Any

# The SHUNT_TRY_INVOKE_* statuses of scripts/lib/transport.sh, which a test keeps in step.
TIMEOUT, ERROR, EMPTY, AUTH, DEADLINE, OVERSIZE, CONFIG = 124, 2, 3, 4, 5, 6, 7
UNREACHABLE = 8  # no connection within SHUNT_CONNECT_TIMEOUT (Python only, the bash twin never sees it)
NEEDS_CHUNKING = 90  # internal: the size guard says map_reduce

FAILED = 1  # a chunk could not be cut or the reply file not written (not a SHUNT_TRY_INVOKE_* code)


class Abort(Exception):
    """End the call with this status. The reason is already on stderr."""

    def __init__(self, status: int) -> None:
        super().__init__(status)
        self.status = status


EXCERPT_CHARS = 300
EXCERPT_READ_BYTES = 4000
MAX_COUNT = 1e15  # a token count or cost at or above this is treated as absent
_U_ESCAPE = re.compile(r"\\u[0-9A-Fa-f]{4}")


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _tojson_inner(text: str) -> str:
    """The text as jq writes it into a JSON string (without the quotes)."""
    return json.dumps(text, ensure_ascii=False)[1:-1].replace("\x7f", "\\u007f")


_STRIPPED_CATEGORIES = ("Cc", "Cf", "Zl", "Zp")  # controls (also C1), format (bidi), line and paragraph separators


def strip_cntrl(text: str) -> str:
    """Drop every control, format and line/paragraph separator character, so provider or
    file controlled text cannot move the cursor, flip the direction or fake a line on a terminal."""
    return "".join(c for c in text if unicodedata.category(c) not in _STRIPPED_CATEGORIES)


_strip_cntrl = strip_cntrl


def _u_forms(text: str, every_char: bool) -> str:
    """Non-ASCII (or every) character as lower case \\uxxxx, with surrogate pairs above U+FFFF."""
    parts = []
    for ch in text:
        code = ord(ch)
        if code < 128 and not every_char:
            parts.append(_tojson_inner(ch))
        elif code < 0x10000:
            parts.append(f"\\u{code:04x}")
        else:
            code -= 0x10000
            parts.append(f"\\u{0xD800 + (code >> 10):04x}\\u{0xDC00 + (code & 0x3FF):04x}")
    return "".join(parts)


def _key_spellings(key: str) -> list[str]:
    """Every spelling of the key a server might echo, longest source first."""
    plain = _strip_cntrl(key)
    escaped = _tojson_inner(plain)
    forms = [plain, _tojson_inner(key), escaped, escaped.replace("/", "\\/")]
    for source in (plain, key):
        forms += [_u_forms(source, False), _u_forms(source, True)]
    return [form for form in dict.fromkeys(forms) if form]


def excerpt(body: bytes, key: str | None) -> str:
    """One line of the body that is safe for stderr: control characters removed,
    every spelling of the whole key scrubbed, cut to EXCERPT_CHARS characters."""
    text = body[:EXCERPT_READ_BYTES].decode("utf-8", "replace")
    text = _U_ESCAPE.sub(lambda m: m.group(0).lower(), _strip_cntrl(text))
    for form in _key_spellings(key) if key else []:
        text = text.replace(form, "[redacted]")
    return text[:EXCERPT_CHARS]


def _count(value: Any) -> int:
    if _is_number(value) and 0 <= value < MAX_COUNT:
        return math.floor(value)
    return 0


def _index(value: Any, name: str) -> Any:
    """jq `.name`: null stays null, anything but an object is an error."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(name)
    raise TypeError(name)


def _present(value: Any) -> bool:
    """jq `//` keeps a value that is neither null nor false."""
    return value is not None and value is not False


def normalize(body: bytes) -> dict[str, Any] | None:
    """{text, finish_reason[, usage][, cost]} of a chat completion, None for any other body.

    Token counts and cost come from provider data, so they are cleaned: a token
    count is a non-negative whole number (anything else is 0), cost is kept only
    when a non-negative number.
    """
    try:
        doc = json.loads(body)
        choices = _index(doc, "choices")
        if not isinstance(choices, list) or not choices:
            return None
        first = choices[0]
        content = _index(_index(first, "message"), "content")
        finish = _index(first, "finish_reason")
    except (ValueError, TypeError, RecursionError):
        return None
    usage = doc.get("usage")
    result: dict[str, Any] = {
        "text": content if isinstance(content, str) else "",
        "finish_reason": finish if _present(finish) else "",
    }
    if isinstance(usage, dict):
        result["usage"] = {"input": _count(usage.get("prompt_tokens")),
                           "output": _count(usage.get("completion_tokens"))}
    cost = usage.get("cost") if isinstance(usage, dict) else None
    if not _present(cost):
        cost = doc.get("cost")
    if _is_number(cost) and 0 <= cost < MAX_COUNT:
        result["cost"] = cost
    return result


def finish_text(value: Any) -> str:
    """The finish_reason as `jq -r` prints it."""
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))


def dump(result: dict[str, Any]) -> str:
    """Compact JSON for the normalized file. A lone surrogate becomes U+FFFD, as jq reads it."""
    text = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
    return text.encode("utf-8", "surrogatepass").decode("utf-8", "replace") + "\n"

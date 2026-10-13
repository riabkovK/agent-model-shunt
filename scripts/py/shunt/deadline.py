"""Total deadline of one model attempt of the HTTP transport.

Port of scripts/lib/transport-http-deadline.sh. One attempt (a single request,
or every chunk and merge request of a chunked call) must finish within
SHUNT_TOTAL_TIMEOUT_SECONDS. Unset or empty it is TOTAL_TIMEOUT_FACTOR times
SHUNT_TIMEOUT_SECONDS (rounded up to whole seconds), and there is no total
deadline when SHUNT_TIMEOUT_SECONDS is no limit. Each failover candidate runs its
own `shunt_py` process and so starts its own deadline.

The clock is read only through `now_ticks` and `TICKS_PER_SECOND`, so a test can
swap both. It is monotonic, so a wall clock jump cannot end a call early.
"""

from __future__ import annotations

import re
import sys
import time
from collections.abc import Mapping
from dataclasses import dataclass

from .transport_reply import strip_cntrl

TICKS_PER_SECOND = 1000
TOTAL_TIMEOUT_FACTOR = 3
# Longest accepted SHUNT_TOTAL_TIMEOUT_SECONDS, in digits. A SHUNT_TIMEOUT_SECONDS
# with more whole digits is longer than any total can be, so it is no limit.
TOTAL_TIMEOUT_MAX_DIGITS = 9
DEFAULT_TIMEOUT_SECONDS = "300"
SHOWN_VALUE_CHARS = 40
_DIGITS = re.compile(r"[0-9]+")


class DeadlineError(ValueError):
    """A timeout setting is invalid. The text is the stderr message without the `shunt: ` prefix."""


@dataclass(frozen=True)
class RequestTime:
    """The time limit of the next request: seconds (None for no limit) and whether the
    total deadline cut it below SHUNT_TIMEOUT_SECONDS."""

    max_time: float | None
    capped: bool


def now_ticks() -> int:
    return int(time.monotonic() * TICKS_PER_SECOND)


def _shown(value: str) -> str:
    return strip_cntrl(value)[:SHOWN_VALUE_CHARS]


def per_limit(raw: str) -> int | None:
    """SHUNT_TIMEOUT_SECONDS as whole seconds rounded up, 0 for no limit (0, or more
    than TOTAL_TIMEOUT_MAX_DIGITS whole digits), None when it is not a plain decimal number."""
    whole, dot, frac = raw.partition(".")
    if not dot:
        frac = ""
    if not _DIGITS.fullmatch(whole + frac):
        return None
    whole = whole.lstrip("0")
    if len(whole) > TOTAL_TIMEOUT_MAX_DIGITS:
        return 0
    return int(whole or 0) + (1 if frac.strip("0") else 0)


def _total_seconds(raw: str, limit: int) -> int:
    if not raw:
        return limit * TOTAL_TIMEOUT_FACTOR
    if _DIGITS.fullmatch(raw) and len(raw) <= TOTAL_TIMEOUT_MAX_DIGITS and int(raw) > 0:
        return int(raw)
    raise DeadlineError("SHUNT_TOTAL_TIMEOUT_SECONDS must be a positive whole number of seconds "
                        f"(at most {TOTAL_TIMEOUT_MAX_DIGITS} digits), got '{_shown(raw)}'.")


class Deadline:
    """The clock of one model attempt. `total` is 0 when there is no total deadline."""

    def __init__(self, environ: Mapping[str, str]) -> None:
        self.timeout_raw = environ.get("SHUNT_TIMEOUT_SECONDS") or DEFAULT_TIMEOUT_SECONDS
        limit = per_limit(self.timeout_raw)
        if limit is None:
            raise DeadlineError("SHUNT_TIMEOUT_SECONDS must be a non-negative number of seconds (0 for no "
                                f"limit), got '{_shown(self.timeout_raw)}' (config problem, no request sent).")
        self.limit = limit
        self.total = _total_seconds(environ.get("SHUNT_TOTAL_TIMEOUT_SECONDS") or "", limit)
        self.end = now_ticks() + self.total * TICKS_PER_SECOND
        self.chunks_done = 0
        self.chunks_total = 0

    def note(self, model_id: str) -> None:
        """Say on stderr that the total deadline ended the call and how far a chunked call got."""
        progress = f", {self.chunks_done} of {self.chunks_total} chunks finished" if self.chunks_total else ""
        sys.stderr.write(f"shunt: model {model_id}: total deadline of {self.total}s "
                         f"(SHUNT_TOTAL_TIMEOUT_SECONDS) reached{progress}.\n")

    def request_time(self) -> RequestTime | None:
        """The limit for the next request: SHUNT_TIMEOUT_SECONDS, or the time left (whole
        seconds, rounded up, at most the total) when that is shorter or there is no
        per-request limit. None once no time is left: nothing may be sent then."""
        timeout = float(self.timeout_raw) if self.limit else None  # limit 0 (no limit, too many digits) is None
        if self.total <= 0:
            return RequestTime(timeout, False)
        left = self.end - now_ticks()
        if left <= 0:
            return None
        seconds = min(-(-left // TICKS_PER_SECOND), self.total)
        if self.limit == 0 or seconds < self.limit:
            return RequestTime(float(seconds), True)
        return RequestTime(timeout, False)

"""The publish of code-write in one process: content gate, target check, then the three stages.

The stages are those of cw_publish.py (make the directories, stage the temp file, link without
clobbering). The temp file name is chosen BEFORE its stage runs and the created directories are
recorded as they are made, so `Publication.cleanup` can undo a publish that a signal cut short
at any point: a signal handler raises, the stage rolls itself back, and the caller's `finally`
runs `cleanup` for whatever is left. After a finished publish `cleanup` does nothing.
"""

from __future__ import annotations

import contextlib
import os
import random

from . import cw_publish, cw_target, cw_text
from .cw_io import Stop, fail, quote

SEAM_AFTER_MKDIR = "after-mkdir"
SEAM_BEFORE_LINK = "before-link"
_SUFFIX_DIGITS = 9


def seam(_name: str) -> None:
    """Test seam, a no-op in production. Called with SEAM_AFTER_MKDIR and SEAM_BEFORE_LINK so a
    test can act at the exact moments the TOCTOU window opens (tests replace this attribute)."""


def refusal_text(target: bytes, reason: str) -> str:
    """The `shunt: refusing target` line. The target is shown quoted (controls become visible
    escapes) with invisible and bidi characters stripped first, so it can neither reorder the
    line nor carry hidden text."""
    return f"shunt: refusing target {quote(cw_text.strip_invisible(target))}: {reason}"


def check_target(root: str, target: str) -> cw_target.Resolved:
    """Validate a target without touching the disk. Raises Stop with the refusal line."""
    raw = os.fsencode(target)
    try:
        return cw_target.resolve(os.fsencode(root), raw)
    except cw_target.Refusal as exc:
        raise Stop(refusal_text(raw, str(exc))) from None


def _tmp_name() -> bytes:
    digits = "".join(random.SystemRandom().choice("0123456789") for _ in range(_SUFFIX_DIGITS))
    return cw_publish.TMP_PREFIX + f"{os.getpid()}.{digits}".encode()


class Publication:
    """Publishes one file and remembers what it made, for the rollback."""

    def __init__(self) -> None:
        self.tmp: bytes = b""
        self.created: list[bytes] = []

    def cleanup(self) -> None:
        """Remove the temp file, then only the directories this call created, deepest first and only
        when empty. Touches nothing else. Safe at any time."""
        if self.tmp:
            with contextlib.suppress(OSError):
                os.unlink(self.tmp)
            self.tmp = b""
        for path in reversed(self.created):
            with contextlib.suppress(OSError):
                os.rmdir(path)
        self.created = []

    def _failure(self, reason: str) -> Stop:
        self.cleanup()
        return fail(f"cannot write the file: {reason}")

    def publish(self, root: str, target: str, code_file: str) -> str:
        """Create the new file and return its absolute path. Raises Stop with the message on any
        refusal or failure, nothing left behind."""
        code = os.fsencode(code_file)
        message = cw_publish.check_code_file(code)
        if message:
            raise Stop(message)
        found = check_target(root, target)
        final_name = found.missing[-1]
        self.tmp, self.created = b"", []
        try:
            directory, _ = cw_publish.make_dirs(found.ancestor, found.missing, self.created)
            seam(SEAM_AFTER_MKDIR)
            self.tmp = directory + b"/" + _tmp_name()
            cw_publish.stage_tmp(found.root, directory, final_name, code, self.tmp.rsplit(b"/", 1)[1])
            seam(SEAM_BEFORE_LINK)
            linked = cw_publish.link_no_clobber(directory, self.tmp.rsplit(b"/", 1)[1], final_name)
        except cw_publish.PublishError as exc:
            raise self._failure(str(exc)) from None
        if not linked:
            raise self._failure("the file could not be published without overwriting (the target appeared "
                                "or the link was refused), nothing was overwritten.")
        self.tmp, self.created = b"", []
        return os.fsdecode(directory + b"/" + final_name)


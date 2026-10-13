"""Debug capture of unusable code-write answers (port of cw_save_unusable, cw_capped_copy, cw_prune_saved).

With the debug log on, the raw response of an unusable answer is copied to a new 0600 file in an
"unusable-responses" directory next to SHUNT_DEBUG_LOG_PATH, named by UTC timestamp and model slug.
A raw answer can echo anything the model saw, so the capture is small and private: the directory
is 0700 and ours (never a symlink), the copy is cut at SHUNT_CW_MAX_SAVE_BYTES, only the newest
KEEP_SAVED files stay. The capture never changes the outcome of the call and never prints a key.
"""

from __future__ import annotations

import contextlib
import os
import re
import stat
import time
from collections.abc import Mapping

from . import cw_text, env
from .bulk_read import debug_log_enabled
from .cw_io import clean, err

DEFAULT_MAX_SAVE_BYTES = 1048576
KEEP_SAVED = 20
DIR_NAME = "unusable-responses"
MAX_NAME_TRIES = 100
_SAVED_NAME = re.compile(rb"[0-9].*Z-.*\.txt", re.DOTALL)
_SLUG_KEEP = frozenset(b"abcdefghijklmnopqrstuvwxyz0123456789._-")


def _log_path(environ: Mapping[str, str]) -> str:
    return environ.get("SHUNT_DEBUG_LOG_PATH") or str(env.cache_dir(environ) / "usage.jsonl")


def _slug(model_id: str) -> str:
    lowered = os.fsencode(model_id).translate(bytes.maketrans(bytes(range(65, 91)), bytes(range(97, 123))))
    return os.fsdecode(bytes(b if b in _SLUG_KEEP else ord("-") for b in lowered))


def _make_dir(path: str) -> bool:
    """Create the directory 0700 unless it is a symlink. False when it could not be made."""
    if os.path.islink(path):
        return True
    old = os.umask(0o077)
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
    except OSError:
        return False
    finally:
        os.umask(old)
    return True


def _capped(data: bytes, limit: int) -> bytes:
    if len(data) <= limit:
        return data
    return data[:limit] + f"\n[shunt: response truncated, kept {limit} of {len(data)} bytes]\n".encode()


def _write_new(path: str, content: bytes) -> bool:
    """Create the file exclusively (0600, no symlink followed) and write it. False if that failed."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(path, flags, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(path)
        return False
    return True


def _prune(directory: str) -> None:
    """Keep the newest KEEP_SAVED captures (names start with a UTC stamp, so name order is age
    order). Only regular files that match the capture naming, only in this directory."""
    raw = os.fsencode(directory)
    try:
        names = sorted(n for n in os.listdir(raw) if _SAVED_NAME.fullmatch(n))
    except OSError:
        return
    kept = []
    for name in names:
        with contextlib.suppress(OSError):
            if stat.S_ISREG(os.lstat(raw + b"/" + name).st_mode):
                kept.append(name)
    for name in kept[:max(0, len(kept) - KEEP_SAVED)]:
        with contextlib.suppress(OSError):
            os.unlink(raw + b"/" + name)


def save_unusable(response: bytes, model_id: str, environ: Mapping[str, str]) -> str:
    """The path of the saved copy, or '' when nothing was saved (switch off, copy failed, unsafe dir)."""
    if not debug_log_enabled(environ):
        return ""
    directory = os.path.dirname(_log_path(environ)) or "."
    directory += "/" + DIR_NAME
    if not _make_dir(directory):
        return ""
    info = os.lstat(directory) if os.path.lexists(directory) else None
    if info is None or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        err(f"shunt: code-write: the raw answer was not saved: {clean(directory)} must be a real directory "
            "owned by the current user.")
        return ""
    with contextlib.suppress(OSError):
        os.chmod(directory, 0o700)
    limit = cw_text.limit(environ.get("SHUNT_CW_MAX_SAVE_BYTES", ""), DEFAULT_MAX_SAVE_BYTES)
    content = _capped(response, limit)
    stem = f"{directory}/{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{_slug(model_id)}"
    for attempt in range(MAX_NAME_TRIES):
        path = f"{stem}.txt" if attempt == 0 else f"{stem}-{attempt}.txt"
        if _write_new(path, content):
            _prune(directory)
            return path
    return ""

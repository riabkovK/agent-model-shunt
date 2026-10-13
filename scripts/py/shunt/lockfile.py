"""Exclusive inter-process lock on <file>.lock using fcntl.flock.

Mirrors the former shunt_providers_lock of scripts/lib/providers.sh: the lock file is
opened for append (created 0666 minus umask), polled with a non-blocking
lock every 0.1 s until the timeout, and nested use in one process only counts
depth. There is no mkdir fallback: fcntl is present on Linux and macOS.
Not thread safe: the nesting table is per process.
"""

import errno
import fcntl
import math
import os
import stat
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

POLL_INTERVAL = 0.1
DEFAULT_TIMEOUT = 10.0
LOCK_FILE_MODE = 0o666  # like bash `>>`: umask decides the final bits

_held: dict[str, list[int]] = {}  # lock path -> [fd, depth]


class LockTimeout(TimeoutError):
    """The lock was not acquired within the timeout."""


def lock_path_for(path: str | os.PathLike[str]) -> Path:
    target = Path(path)
    return target.with_name(target.name + ".lock")


def _check_timeout(timeout: float) -> None:
    if not math.isfinite(timeout) or timeout < 0:
        raise ValueError(f"timeout must be a finite non-negative number, got {timeout!r}")


def _open_lock(lock: Path) -> int:
    """Open the lock file without following a symlink or blocking on a FIFO."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    fd = os.open(lock, flags, LOCK_FILE_MODE)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, "the lock path is not a regular file", str(lock))
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _acquire(lock: Path, target: Path, timeout: float) -> int:
    fd = _open_lock(lock)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LockTimeout(f"timed out waiting for the lock on {target}") from None
                time.sleep(POLL_INTERVAL)
    except BaseException:
        os.close(fd)
        raise


@contextmanager
def file_lock(path: str | os.PathLike[str], timeout: float = DEFAULT_TIMEOUT) -> Iterator[None]:
    """Hold an exclusive lock for the data file at path. Raises LockTimeout."""
    _check_timeout(timeout)
    target = Path(path)
    lock = lock_path_for(target)
    key = os.path.realpath(lock)
    entry = _held.get(key)
    if entry is not None:
        entry[1] += 1
        try:
            yield
        finally:
            entry[1] -= 1
        return
    lock.parent.mkdir(parents=True, exist_ok=True)
    fd = _acquire(lock, target, timeout)
    _held[key] = [fd, 1]
    try:
        yield
    finally:
        del _held[key]
        os.close(fd)  # closing the fd drops the flock

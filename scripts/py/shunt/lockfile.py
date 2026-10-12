"""Exclusive inter-process lock on <file>.lock using fcntl.flock.

Mirrors shunt_providers_lock in scripts/lib/providers.sh: the lock file is
opened for append (created 0666 minus umask), polled with a non-blocking
lock every 0.1 s until the timeout, and nested use in one process only counts
depth. There is no mkdir fallback: fcntl is present on Linux and macOS.
Not thread safe: the nesting table is per process.
"""

import fcntl
import math
import os
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


def _acquire(lock: Path, target: Path, timeout: float) -> int:
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC, LOCK_FILE_MODE)
    if not math.isfinite(timeout) or timeout < 0:
        os.close(fd)
        raise ValueError(f"timeout must be a finite non-negative number, got {timeout!r}")
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

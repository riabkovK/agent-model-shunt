"""Publish step of code-write: the one place that turns checked text into a new file.

Never overwrites anything: the file appears through link(2), which fails when the name
exists (a dangling symlink included). Directories and the temp file are made relative to
an open directory descriptor opened with O_NOFOLLOW, so a symlink swapped in for a
directory cannot redirect the write. Each stage rolls back what it created when it fails
or when SIGINT, SIGTERM or SIGHUP arrives (see `rollback_on_signals`). The bash caller
(lib/codewrite.sh) runs the stages one after the other and keeps its test seam between them.

Residual risk, accepted: the stages are separate processes. A directory swapped for another
real directory between two stages is caught by the descriptor checks. The directory chain
above the one we hold is re-verified by canonical path at stage 2 only.
"""

import contextlib
import os
import secrets
import signal
import stat
from collections.abc import Sequence
from typing import IO

from . import cw_target, cw_text
from .cw_parse import DEFAULT_MAX_CODE_BYTES

DIR_MODE = 0o755
FILE_MODE = 0o644
STAGE_MODE = 0o600
TMP_PREFIX = b".shunt-cw."
_OPEN_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_CREATE = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
_TMP_TRIES = 100


class PublishError(Exception):
    """A publish failure. The text goes after "shunt: cannot write the file: "."""


class Interrupted(SystemExit):
    """A termination signal turned into an exit, so the rollback `except` blocks run."""


def _on_signal(signum: int, _frame: object) -> None:
    raise Interrupted(128 + signum)


def rollback_on_signals() -> None:
    """Make SIGTERM and SIGHUP raise (SIGINT already raises KeyboardInterrupt)."""
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, _on_signal)


def check_code_file(code_file: bytes) -> str:
    """Content gate of publish, the same limits as the parser. '' when fine, else the refusal text."""
    size = os.stat(code_file).st_size
    cap = cw_text.limit(os.environ.get("SHUNT_CW_MAX_CODE_BYTES", ""), DEFAULT_MAX_CODE_BYTES)
    if size == 0:
        return "shunt: refusing to write an empty file."
    if size > cap:
        return f"shunt: refusing to write {size} bytes, the cap is {cap}."
    reason = (cw_text.check_text(code_file) or cw_text.check_code_controls(code_file)
              or cw_text.check_invisible(code_file) or cw_text.check_protocol_tags(code_file))
    return f"shunt: refusing to write the content: {reason}." if reason else ""


def _plain_name(name: bytes) -> bytes:
    if name in (b"", b".", b"..") or b"/" in name or b"\0" in name:
        raise PublishError("the file name is not a plain component.")
    return name


def _rmdir_all(paths: Sequence[bytes]) -> None:
    for path in reversed(paths):  # only ours, deepest first, and only when empty
        with contextlib.suppress(OSError):
            os.rmdir(path)


def make_dirs(ancestor: bytes, missing: Sequence[bytes]) -> tuple[bytes, list[bytes]]:
    """Create missing[:-1] below ancestor (mode 0755 whatever the umask). Returns (deepest dir, created).

    A directory that appeared concurrently is used but never listed as ours. On any failure
    or signal the directories created so far are removed again.
    """
    created: list[bytes] = []
    path = ancestor
    held = -1
    try:
        held = os.open(ancestor, _OPEN_DIR)
        for name in missing[:-1]:
            path = path + b"/" + _plain_name(name)
            child = _enter(held, name, path, created)
            os.close(held)
            held = child
    except PublishError:
        _rmdir_all(created)
        raise
    except OSError as exc:
        _rmdir_all(created)
        raise PublishError(f"cannot create the directory {path.decode(errors='replace')}.") from exc
    except BaseException:
        _rmdir_all(created)
        raise
    finally:
        if held >= 0:
            os.close(held)
    return path, created


def _enter(parent: int, name: bytes, path: bytes, created: list[bytes]) -> int:
    """Create or reuse the directory `name` below the descriptor `parent`. Returns its descriptor."""
    try:
        os.mkdir(name, DIR_MODE, dir_fd=parent)
        created.append(path)
        mine = True
    except FileExistsError:
        mine = False
    child = os.open(name, _OPEN_DIR, dir_fd=parent)  # a symlink or a file here fails
    if mine:
        os.fchmod(child, DIR_MODE)
    return child


def _read(path: bytes) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


def _open_parent(directory: bytes) -> int:
    try:
        held = os.open(directory, _OPEN_DIR)
    except OSError as exc:
        raise PublishError("the parent directory changed while publishing.") from exc
    if not os.path.samestat(os.fstat(held), os.stat(directory)):
        os.close(held)
        raise PublishError("the parent directory changed while publishing.")
    return held


def _check_parent(root: bytes, directory: bytes, final_name: bytes) -> None:
    real = cw_target.canon_dir(directory)
    if real is None:
        raise PublishError("the parent directory disappeared.")
    try:
        cw_target.check_placement(root, real, final_name)
    except cw_target.Refusal as exc:
        raise PublishError(f"{exc}.") from exc
    if real != directory:
        raise PublishError("the parent directory changed while publishing.")


def _create_tmp(held: int, directory: bytes, name: bytes) -> tuple[int, bytes]:
    for _ in range(_TMP_TRIES):
        candidate = name or TMP_PREFIX + secrets.token_hex(4).encode()
        try:
            return _open_create(held, candidate), candidate
        except FileExistsError:
            if name:
                break
    raise PublishError(f"cannot create a temporary file in {directory.decode(errors='replace')}.")


def _open_create(held: int, name: bytes) -> int:
    return os.open(name, _CREATE, STAGE_MODE, dir_fd=held)


def stage_tmp(root: bytes, directory: bytes, final_name: bytes, code_file: bytes, tmp_name: bytes = b"") -> bytes:
    """Re-check the parent, then write the content to a 0600 temp file in it and make it 0644.

    The parent must resolve inside the root, pass the target rule and still be exactly
    `directory`. Returns the temp file path. The temp file is removed again on any failure
    or signal. tmp_name, when given, must be a fresh `.shunt-cw.*` name the caller can clean up.
    """
    if tmp_name and (not tmp_name.startswith(TMP_PREFIX) or b"/" in tmp_name):
        raise PublishError("the temporary file name is not allowed.")
    _check_parent(root, directory, _plain_name(final_name))
    content = _read(code_file)
    held = _open_parent(directory)
    name = b""
    try:
        try:
            fd, name = _create_tmp(held, directory, tmp_name)
        except OSError as exc:
            raise PublishError(f"cannot create a temporary file in {directory.decode(errors='replace')}.") from exc
        with os.fdopen(fd, "r+b") as handle:
            _fill(handle, content)
            os.fchmod(handle.fileno(), FILE_MODE)
    except BaseException:
        if name:
            with contextlib.suppress(OSError):
                os.unlink(name, dir_fd=held)
        raise
    finally:
        os.close(held)
    return directory + b"/" + name


def _fill(handle: IO[bytes], content: bytes) -> None:
    try:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
        handle.seek(0)
        written = handle.read()
    except OSError as exc:
        raise PublishError("cannot write the temporary file.") from exc
    if written != content:
        raise PublishError("the temporary file does not match the content (disk full?).")


def _is_ours(info: os.stat_result) -> bool:
    return stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()


def _exists(held: int, name: bytes) -> bool:
    try:
        os.stat(name, dir_fd=held, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _link(held: int, tmp: bytes, final: bytes) -> bool:
    """link(2) the temp file under the final name, never replacing anything. False when refused."""
    try:
        os.link(tmp, final, src_dir_fd=held, dst_dir_fd=held, follow_symlinks=False)
    except FileExistsError:
        return False
    except OSError:
        return _create_copy(held, tmp, final)  # no hard links on this filesystem
    placed = os.stat(final, dir_fd=held, follow_symlinks=False)
    return stat.S_ISREG(placed.st_mode) and os.path.samestat(placed, os.stat(tmp, dir_fd=held, follow_symlinks=False))


def _create_copy(held: int, tmp: bytes, final: bytes) -> bool:
    """Fallback without hard links: create the final name exclusively and copy the content in."""
    fd = -1
    try:
        fd = os.open(final, _CREATE, STAGE_MODE, dir_fd=held)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as out, os.fdopen(os.open(tmp, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=held), "rb") as src:
            data = src.read()
            out.write(data)
            out.flush()
            os.fchmod(out.fileno(), FILE_MODE)
        with os.fdopen(os.open(final, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=held), "rb") as check:
            return check.read() == data
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(final, dir_fd=held)  # ours: the exclusive create succeeded
        raise


def link_no_clobber(directory: bytes, tmp_name: bytes, final_name: bytes) -> bool:
    """Publish the staged file as directory/final_name without replacing anything.

    True only when the name now is a regular file holding our content. The temp file is
    removed in every case. A dangling symlink, a directory or a file at the name refuses.
    """
    _plain_name(final_name)
    _plain_name(tmp_name)
    if not tmp_name.startswith(TMP_PREFIX) or tmp_name == final_name:
        raise PublishError("the temporary file name is not allowed.")
    try:
        held = os.open(directory, _OPEN_DIR)
    except OSError:
        return False
    try:
        try:
            if not _is_ours(os.stat(tmp_name, dir_fd=held, follow_symlinks=False)):
                return False  # swapped, or the directory is not the one we staged in
            if _exists(held, final_name):
                return False  # something is there already
            return _link(held, tmp_name, final_name)
        finally:
            with contextlib.suppress(OSError):
                os.unlink(tmp_name, dir_fd=held)
    finally:
        os.close(held)

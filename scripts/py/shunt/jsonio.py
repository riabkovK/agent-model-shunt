"""JSON file reading and atomic writing."""

import json
import os
import tempfile
from pathlib import Path
from typing import Any

DEFAULT_FILE_MODE = 0o600  # providers.json and friends: chmod 600 in bash


class JsonReadError(Exception):
    """The file exists but cannot be read or does not hold valid JSON."""


def read_json(path: str | os.PathLike[str], default: Any = None) -> Any:
    """Return the parsed JSON in path, or default when the file does not exist."""
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return default
    except (OSError, UnicodeDecodeError) as exc:
        raise JsonReadError(f"cannot read {p}: {exc}") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise JsonReadError(f"{p} contains invalid JSON: {exc}") from exc


def _fsync_dir(directory: Path) -> None:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_json_atomic(
    path: str | os.PathLike[str],
    data: Any,
    mode: int = DEFAULT_FILE_MODE,
    indent: int | None = 2,
) -> None:
    """Write data as JSON via a temp file in the same dir, fsync and os.replace.

    The final file has exactly mode, whatever the umask. On any error the
    temp file is removed and an existing target is left untouched.
    """
    target = Path(path)
    payload = json.dumps(data, indent=indent, ensure_ascii=False, allow_nan=False) + "\n"  # fails before any file exists
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.")
    try:
        try:
            handle = os.fdopen(fd, "w", encoding="utf-8")
        except BaseException:
            os.close(fd)
            raise
        with handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, target)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise
    _fsync_dir(target.parent)

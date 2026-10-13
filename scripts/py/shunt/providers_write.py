"""Writer side of providers.json: put, `provider set` and the plaintext key store.

Port of shunt_providers_write, shunt_provider_plaintext_store and the jq code of
cmd_provider_set in bash. Argument parsing and the hint lines stay in bash.

Locking: `put`, `set` and `plaintext-store` take the providers lock (<file>.lock, flock,
SHUNT_PROVIDERS_LOCK_TIMEOUT seconds) around the write. The only lock implementation is lockfile.py.
migrate.py calls the functions in-process under its own file_lock, which nests.

The key of the plaintext store arrives on stdin and is held in memory only. It
is never put in a message: errors carry paths and fixed text.
"""

import argparse
import contextlib
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from . import env, providers
from .jsonio import JsonReadError, read_json, write_json_atomic
from .lockfile import LockTimeout, file_lock
from .models_write import parse_json
from .providers import ProviderError


def _lock(path: str, environ: Mapping[str, str]) -> Any:
    """The providers lock as a context manager."""
    try:
        timeout = env.providers_lock_timeout(environ)
    except env.EnvError as exc:
        raise ProviderError(str(exc)) from None
    return _timeout_as_error(path, timeout)


@contextlib.contextmanager
def _timeout_as_error(path: str, timeout: float) -> Any:
    try:
        with file_lock(path, timeout):
            yield
    except LockTimeout:
        raise ProviderError(f"timed out waiting for the lock on {path}.") from None


def _save(path: str, doc: Any) -> None:
    write_json_atomic(Path(path), doc)  # mode 0600, atomic


def put(path: str, text: str) -> None:
    """Validate that text is JSON (not null or false, as `jq -e .`) and replace providers.json with it."""
    try:
        doc = parse_json(text)
    except (ValueError, RecursionError):
        doc = None
    if doc is None or doc is False:
        raise ProviderError("refusing to write an invalid providers file.")
    _save(path, doc)


def _current(path: str) -> dict[str, Any]:
    providers.validate(path)
    try:
        doc = read_json(path)
    except JsonReadError as exc:
        raise ProviderError(str(exc)) from exc
    return {"version": 1, "providers": {}} if doc is None else doc


def _new_key(old: dict[str, Any], key_type: str, key_ref: str) -> dict[str, Any]:
    old_key = old.get("key")
    if key_type == "":
        return {} if "key" in old else {"key": {"type": "none"}}
    if key_type == "env":
        return {"key": {"type": "env", "ref": key_ref}}
    if key_type == "plaintext" and isinstance(old_key, dict) and old_key.get("type") == "plaintext":
        return {"key": old_key}
    return {"key": {"type": key_type}}


def set_provider(path: str, name: str, transport: str, base_url: str, key_type: str, key_ref: str,
                 healthcheck: str = "") -> str:
    """Create or update an entry, keeping fields not given. Returns the summary shown to the user.

    healthcheck is "on", "off" or "" (not given): a new entry then gets true, an existing one keeps its value.
    """
    doc = _current(path)
    table = doc["providers"]
    if not transport and name not in table:
        raise ProviderError(f"provider '{name}' is new: --transport is required.")
    old = table.get(name)
    old = old if isinstance(old, dict) else {}  # jq `// {}`
    entry = {**old}
    if transport:
        entry["transport"] = transport
    if base_url:
        entry["base_url"] = base_url
    entry.update(_new_key(old, key_type, key_ref))
    if healthcheck:
        entry["healthcheck"] = healthcheck == "on"
    elif name not in table:
        entry["healthcheck"] = True
    if (entry.get("transport") or "opencode") == "http" and not (entry.get("base_url") or ""):
        raise ProviderError(
            f"provider '{name}': transport http needs a base_url (--base-url http://... or https://...).")
    _save(path, {**doc, "providers": {**table, name: entry}})
    key = entry.get("key")
    key_name = key.get("type") if isinstance(key, dict) else None
    return f"transport {entry.get('transport') or 'opencode'}, key {key_name if isinstance(key_name, str) else 'none'}"


def plaintext_store(path: str, provider: str, key: str) -> None:
    """Store key as the plaintext ref of provider, unless its key type is no longer plaintext."""
    try:
        key_type = providers.field(path, provider, "key-type")
    except ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        key_type = ""
    if key_type != "plaintext":
        raise ProviderError(f"provider '{provider}' no longer has a plaintext key type, nothing stored.")
    doc = _current(path)
    entry = doc["providers"][provider]
    _save(path, {**doc, "providers": {**doc["providers"], provider: {**entry, "key": {**entry["key"], "ref": key}}}})


def _read_key_line() -> str:
    """One line of stdin without its newline, like `IFS= read -r key` (empty at EOF)."""
    line = sys.stdin.buffer.readline()
    return line.rstrip(b"\n").decode("utf-8", "surrogateescape")


def _dispatch(args: argparse.Namespace, environ: Mapping[str, str]) -> int:
    path = env.providers_file_text(environ)
    cmd = args.providers_write_command
    if cmd == "put":
        text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        with _lock(path, environ):
            put(path, text)
    elif cmd == "set":
        with _lock(path, environ):
            sys.stdout.write(set_provider(path, args.name, args.transport, args.base_url,
                                          args.key_type, args.key_ref, args.healthcheck) + "\n")
    elif cmd == "plaintext-store":
        key = _read_key_line()
        with _lock(path, environ):
            plaintext_store(path, args.provider, key)
    return 0


def run(args: argparse.Namespace) -> int:
    try:
        return _dispatch(args, os.environ)
    except BrokenPipeError:
        raise
    except ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return exc.code
    except ValueError:  # e.g. a key that cannot be encoded: no exception text, it could echo the key
        sys.stderr.write("shunt: the value could not be processed (invalid characters).\n")
        return 1
    except OSError as exc:  # paths and strerror text only
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


def register(subparsers: Any) -> None:
    """Add the `providers-write` command group to the top-level subparsers."""
    group = subparsers.add_parser("providers-write", help="change providers.json")
    group.set_defaults(func=run)
    sub = group.add_subparsers(dest="providers_write_command", required=True)
    sub.add_parser("put")
    setter = sub.add_parser("set")
    for name in ("name", "transport", "base_url", "key_type", "key_ref"):
        setter.add_argument(name)
    setter.add_argument("healthcheck", nargs="?", default="", choices=("", "on", "off"))
    store = sub.add_parser("plaintext-store")
    store.add_argument("provider")

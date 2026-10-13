"""Circuit breaker state and config for delegate models.

Replaces the former breaker.sh. scripts/shunt-breaker-config (breaker_config_cli.py) drives the config writes.
The state file (SHUNT_BREAKER_STATE_FILE) holds {"version": 1, "models": {key: {"failures": N,
"cooldown_until": EPOCH}}}. Reads never lock and never touch the file: a missing, corrupt
or oddly shaped file is a closed breaker. Every read-modify-write (record, write, clear,
config set) runs under lockfile.file_lock on <file>.lock (providers lock style:
SHUNT_PROVIDERS_LOCK_TIMEOUT seconds) and replaces the file atomically with mode 0600.
A write over a corrupt state file heals it.

Exit codes are the bash return codes: is-open and any-closed answer 0 or 1, everything
else 0 on success and 1 on a failure with a `shunt:` line on stderr.
"""

import argparse
import contextlib
import json
import os
import re
import sys
import time
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import Any

from . import env
from .jsonio import JsonReadError, read_json, write_json_atomic
from .lockfile import LockTimeout, file_lock
from .models import ShuntError

DEFAULT_THRESHOLD = 3
DEFAULT_COOLDOWN = 300
DEFAULT_UNREACHABLE_COOLDOWN = 120  # a host that did not even connect is probed again sooner
DISABLED_THRESHOLD = 999999999  # also read by breaker_config_cli.show to print the disabled status
MAX_DIGITS = 15  # keeps every number inside a 64-bit signed integer, like _shunt_breaker_uint_or
_UINT = re.compile(r"[0-9]{1,%d}" % MAX_DIGITS)
_LIMIT = 10**MAX_DIGITS


# ---------------------------------------------------------------- values

def uint_or(value: Any, fallback: int) -> int:
    """value as a decimal integer when it is 1 to 15 digits (text) or a whole JSON number below 10**15, else fallback."""
    if isinstance(value, str):
        return int(value) if _UINT.fullmatch(value) else fallback
    if isinstance(value, bool):
        return fallback
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, int) and 0 <= value < _LIMIT:
        return value
    return fallback


def now(environ: Mapping[str, str]) -> int:
    """Epoch seconds, or SHUNT_NOW_EPOCH when it is a plain non-negative integer (test hook)."""
    override = environ.get("SHUNT_NOW_EPOCH", "")
    return int(override) if _UINT.fullmatch(override) else int(time.time())


def _config_field(config: Any, name: str) -> Any:
    """A config value as `jq -r '.name // empty'` would print it, else None."""
    if not isinstance(config, dict):
        return None
    value = config.get(name)
    return None if value is None or value is False else value


def limits(environ: Mapping[str, str]) -> tuple[int, int]:
    """(threshold, cooldown seconds): env, then the config file, then the defaults. Invalid values are skipped."""
    try:
        config = read_json(env.breaker_config_file(environ))
    except JsonReadError:
        config = None
    threshold = uint_or(_config_field(config, "threshold"), DEFAULT_THRESHOLD)
    cooldown = uint_or(_config_field(config, "cooldown_seconds"), DEFAULT_COOLDOWN)
    return (uint_or(environ.get("SHUNT_BREAKER_THRESHOLD", ""), threshold),
            uint_or(environ.get("SHUNT_BREAKER_COOLDOWN_SECONDS", ""), cooldown))


def unreachable_cooldown(environ: Mapping[str, str]) -> int:
    """Cooldown seconds after an "unreachable" failure: env, then the config file, then the default."""
    try:
        config = read_json(env.breaker_config_file(environ))
    except JsonReadError:
        config = None
    configured = uint_or(_config_field(config, "unreachable_cooldown_seconds"), DEFAULT_UNREACHABLE_COOLDOWN)
    return uint_or(environ.get("SHUNT_BREAKER_UNREACHABLE_COOLDOWN_SECONDS", ""), configured)


# ---------------------------------------------------------------- state access

def _load(path: Path) -> Any:
    """The state document, or None when the file is missing, unreadable or corrupt."""
    try:
        return read_json(path)
    except JsonReadError:
        return None


def _entry(doc: Any, model_id: str) -> Any:
    """The model's state object, or None (jq `.models[$id] // null`, errors read as null)."""
    if not isinstance(doc, dict) or not isinstance(doc.get("models"), dict):
        return None
    entry = doc["models"].get(model_id)
    return None if entry is None or entry is False else entry


def _number_or_zero(value: Any) -> int:
    """State fields must be JSON numbers (the jq filter checked the type): a string such as "9" reads as 0."""
    return 0 if isinstance(value, str) else uint_or(value, 0)


def _parse(entry: Any) -> tuple[int, int]:
    """(failures, cooldown_until) of a state entry. Anything not a non-negative whole number reads as 0."""
    if not isinstance(entry, dict):
        return 0, 0
    return _number_or_zero(entry.get("failures")), _number_or_zero(entry.get("cooldown_until"))


def _is_open(entry: Any, threshold: int, at: int) -> bool:
    failures, cooldown_until = _parse(entry)
    return failures >= threshold and at < cooldown_until


@contextlib.contextmanager
def _locked(path: Path, environ: Mapping[str, str]) -> Iterator[None]:
    try:
        timeout = env.providers_lock_timeout(environ)
    except env.EnvError:
        raise ShuntError("SHUNT_PROVIDERS_LOCK_TIMEOUT must be a finite non-negative number.") from None
    try:
        with file_lock(path, timeout):
            yield
    except LockTimeout:
        raise ShuntError(f"timed out waiting for the lock on {path}.") from None


def _with_entry(doc: Any, model_id: str, failures: int, cooldown_until: int) -> dict[str, Any]:
    base = doc if isinstance(doc, dict) else {"version": 1}
    models = base.get("models") if isinstance(base.get("models"), dict) else {}
    return {**base, "models": {**models, model_id: {"failures": failures, "cooldown_until": cooldown_until}}}


# ---------------------------------------------------------------- commands

def model_state(environ: Mapping[str, str], model_id: str) -> str:
    entry = _entry(_load(env.breaker_state_file(environ)), model_id)
    return json.dumps(entry, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def is_open(environ: Mapping[str, str], model_id: str) -> bool:
    entry = _entry(_load(env.breaker_state_file(environ)), model_id)
    return _is_open(entry, limits(environ)[0], now(environ))


def any_closed(environ: Mapping[str, str], ids: list[str]) -> bool:
    """True when at least one id is closed. No ids is False, an unreadable state file is closed."""
    if not ids:
        return False
    doc = _load(env.breaker_state_file(environ))
    threshold, at = limits(environ)[0], now(environ)
    return any(not _is_open(_entry(doc, model_id), threshold, at) for model_id in ids)


def status(environ: Mapping[str, str], model_id: str) -> str:
    entry = _entry(_load(env.breaker_state_file(environ)), model_id)
    failures = _parse(entry)[0]
    opened = str(_is_open(entry, limits(environ)[0], now(environ))).lower()
    return f"failures={failures} open={opened}"


def _update(environ: Mapping[str, str], fn: Callable[[Any], Any]) -> None:
    """Replace the state file by fn(current document) under the lock. fn returns None for no write."""
    path = env.breaker_state_file(environ)
    with _locked(path, environ):
        new = fn(_load(path))
        if new is not None:
            write_json_atomic(path, new)


def write_state(environ: Mapping[str, str], model_id: str, failures: int, cooldown_until: int) -> None:
    _update(environ, lambda doc: _with_entry(doc, model_id, failures, cooldown_until))


def record_failure(environ: Mapping[str, str], model_id: str, unreachable: bool = False) -> None:
    """Count a failure. Once the threshold is reached the model pauses for the cooldown, or for the
    shorter unreachable cooldown when the failure was "no connection"."""
    threshold, cooldown = limits(environ)
    if unreachable:
        cooldown = unreachable_cooldown(environ)
    at = now(environ)

    def bump(doc: Any) -> dict[str, Any]:
        failures, cooldown_until = _parse(_entry(doc, model_id))
        failures += 1
        if failures >= threshold:
            cooldown_until = at + cooldown
        return _with_entry(doc, model_id, failures, cooldown_until)

    _update(environ, bump)


def clear_state(environ: Mapping[str, str], model_id: str) -> None:
    """Drop the plain key and every "<id>#<role>" key. No state file is a no-op, a corrupt one is an error."""
    path = env.breaker_state_file(environ)
    if not path.exists():
        return
    prefix = model_id + "#"

    def drop(doc: Any) -> Any:
        if doc is None and not path.exists():
            return None  # removed while we waited for the lock
        if not isinstance(doc, dict):
            raise ShuntError(f"{path} is not a valid breaker state file.")
        models = doc.get("models")
        if not models:
            return None
        if not isinstance(models, dict):
            raise ShuntError(f"{path} is not a valid breaker state file.")
        kept = {k: v for k, v in models.items() if k != model_id and not k.startswith(prefix)}
        return None if len(kept) == len(models) else {**doc, "models": kept}

    _update(environ, drop)


def _update_config(environ: Mapping[str, str], field: str, value: int, other: str, other_default: int) -> None:
    """Set field in the config file, and the other field to its default when it is unset."""
    path = env.breaker_config_file(environ)
    with _locked(path, environ):
        try:
            base = read_json(path)
        except JsonReadError as exc:
            raise ShuntError(str(exc)) from exc
        if base is None or base is False:
            base = {}
        if not isinstance(base, dict):
            raise ShuntError(f"{path} is not a valid breaker config.")
        new = {**base, field: value}
        if new.get(other) is None or new.get(other) is False:
            new[other] = other_default
        write_json_atomic(path, new)


def _uint_arg(text: str, what: str) -> int:
    if not _UINT.fullmatch(text):
        raise ShuntError(f"{what} must be a plain non-negative integer, got '{text}'.")
    return int(text)


def set_threshold(environ: Mapping[str, str], text: str) -> None:
    _update_config(environ, "threshold", _uint_arg(text, "threshold"), "cooldown_seconds", DEFAULT_COOLDOWN)


def set_cooldown(environ: Mapping[str, str], text: str) -> None:
    _update_config(environ, "cooldown_seconds", _uint_arg(text, "cooldown"), "threshold", DEFAULT_THRESHOLD)


def disable(environ: Mapping[str, str]) -> None:
    _update_config(environ, "threshold", DISABLED_THRESHOLD, "cooldown_seconds", DEFAULT_COOLDOWN)


# ---------------------------------------------------------------- cli


def _dispatch(args: argparse.Namespace, environ: Mapping[str, str]) -> int:
    cmd = args.breaker_command
    if cmd == "model-state":
        print(model_state(environ, args.id))
    elif cmd == "is-open":
        return 0 if is_open(environ, args.id) else 1
    elif cmd == "any-closed":
        return 0 if any_closed(environ, args.ids) else 1
    elif cmd == "status":
        print(status(environ, args.id))
    elif cmd == "write-state":
        write_state(environ, args.id, _uint_arg(args.failures, "failures"), _uint_arg(args.cooldown_until, "cooldown_until"))
    elif cmd == "record-failure":
        record_failure(environ, args.id)
    elif cmd == "record-success":
        write_state(environ, args.id, 0, 0)
    elif cmd == "clear-state":
        clear_state(environ, args.id)
    elif cmd == "config-threshold":
        set_threshold(environ, args.value)
    elif cmd == "config-cooldown":
        set_cooldown(environ, args.value)
    elif cmd == "limits":
        print(*limits(environ))
    elif cmd == "config-disable":
        disable(environ)
    return 0


def run(args: argparse.Namespace) -> int:
    try:
        return _dispatch(args, os.environ)
    except BrokenPipeError:
        raise
    except (ShuntError, OSError, UnicodeError, ValueError) as exc:
        if args.breaker_command in ("is-open", "any-closed"):
            return 1  # a failure to read means closed, like the bash twin
        if args.breaker_command == "model-state":
            print("null")
            return 0
        if args.breaker_command == "status":
            print("failures=0 open=false")
            return 0
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


_ID_COMMANDS = ("model-state", "is-open", "status", "record-failure", "record-success", "clear-state")


def register(subparsers: Any) -> None:
    """Add the `breaker` command group to the top-level subparsers."""
    group = subparsers.add_parser("breaker", help="circuit breaker state and config")
    group.set_defaults(func=run)
    sub = group.add_subparsers(dest="breaker_command", required=True)
    for name in _ID_COMMANDS:
        sub.add_parser(name).add_argument("id")
    write = sub.add_parser("write-state")
    for arg in ("id", "failures", "cooldown_until"):
        write.add_argument(arg)
    sub.add_parser("any-closed").add_argument("ids", nargs="*")
    sub.add_parser("config-threshold").add_argument("value")
    sub.add_parser("config-cooldown").add_argument("value")
    sub.add_parser("config-disable")
    sub.add_parser("limits", help="print the resolved threshold and cooldown seconds")

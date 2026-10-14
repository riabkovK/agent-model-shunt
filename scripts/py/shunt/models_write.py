"""Writer side of the delegate model registry (models.json).

Port of the jq read-modify-write code in scripts/shunt-models. Argument
parsing, usage text, the entry checks and the user-facing success lines are in
models_cli.py. Each subcommand here loads the file, builds a new document (the old one is
never mutated) and replaces the file atomically with mode 0600, as the bash
mktemp+mv did. Every load+save runs under the
models lock (<file>.lock, providers lock style: SHUNT_PROVIDERS_LOCK_TIMEOUT seconds).

Messages go through ShuntError: `shunt: <text>` on stderr, exit 1.
"""

import argparse
import contextlib
import json
import os
import sys
from collections.abc import Callable, Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from . import env
from .jsonio import JsonReadError, read_json, write_json_atomic
from .lockfile import LockTimeout, file_lock
from .models import OVERSIZE_POLICIES, ROLES, ShuntError, has_control_char, slug

MAX_CONTEXT_DIGITS = 12  # keep in sync with MAX_CONTEXT_DIGITS in models_cli.py
CLEAR = "--clear"
EMPTY_REGISTRY: dict[str, Any] = {"version": 1, "active": None, "models": []}


def _refuse_constant(name: str) -> Any:
    raise ValueError(f"not JSON: {name}")


def parse_json(text: str) -> Any:
    """json.loads that refuses NaN and Infinity, which jq does not accept as JSON input."""
    return json.loads(text, parse_constant=_refuse_constant)


# ---------------------------------------------------------------- file access

@contextlib.contextmanager
def models_lock(path: str, environ: Mapping[str, str]) -> Iterator[None]:
    """The models.json lock. It nests inside one process, so migrate can hold it around several writes."""
    try:
        timeout = env.providers_lock_timeout(environ)
    except env.EnvError as exc:
        raise ShuntError(str(exc)) from None
    try:
        with file_lock(path, timeout):
            yield
    except LockTimeout:
        raise ShuntError(f"timed out waiting for the lock on {path}.") from None


def _load(path: str, *, create: bool = False) -> dict[str, Any]:
    try:
        doc = read_json(path)
    except JsonReadError as exc:
        raise ShuntError(str(exc)) from exc
    if doc is None:
        if create:
            return dict(EMPTY_REGISTRY, models=[])
        raise ShuntError(f"no models registry at {path}.")
    if not isinstance(doc, dict) or not isinstance(doc.get("models"), list):
        raise ShuntError(f"{path} is not a valid models registry.")
    return doc


def _save(path: str, doc: Mapping[str, Any]) -> None:
    write_json_atomic(Path(path), doc)


def _map_model(doc: Mapping[str, Any], model_id: str, fn: Callable[[dict[str, Any]], dict[str, Any]]) -> dict[str, Any]:
    """A new document where fn replaced every entry whose id is model_id."""
    models = [fn(m) if isinstance(m, dict) and m.get("id") == model_id else m for m in doc["models"]]
    return {**doc, "models": models}


def _update(path: str, model_id: str, fn: Callable[[dict[str, Any]], dict[str, Any]]) -> None:
    _save(path, _map_model(_load(path), model_id, fn))


# ---------------------------------------------------------------- put and roles

def put(path: str, text: str) -> None:
    """Validate that text is JSON (not null or false, as `jq -e .`) and replace the registry with it."""
    try:
        doc = parse_json(text)
    except (ValueError, RecursionError):
        doc = None
    if doc is None or doc is False:
        raise ShuntError("refusing to write an invalid models registry.")
    _save(path, doc)


def parse_roles(arg: str) -> list[str]:
    """Roles of a comma separated line: order kept, duplicates dropped, unknown or empty refused."""
    if "\n" in arg:
        raise ShuntError("roles must be a single comma-separated line.")
    roles: list[str] = []
    for role in arg.split(","):
        if not role:
            raise ShuntError(f"empty role in '{arg}'. Roles: {' '.join(ROLES)}")
        if role not in ROLES:
            raise ShuntError(f"unknown role '{role}'. Known roles: {' '.join(ROLES)}")
        if role not in roles:
            roles.append(role)
    return roles


# ---------------------------------------------------------------- commands

def add(path: str, model_id: str, roles_csv: str) -> str:
    """Append a model with the given roles (all roles when empty). Returns its agent name."""
    if has_control_char(model_id):  # its agent file would be refused after the entry is saved
        raise ShuntError(f"model id {json.dumps(model_id)} contains a control character.")
    roles = parse_roles(roles_csv) if roles_csv else list(ROLES)
    doc = _load(path, create=True)
    if not all(isinstance(m, dict) for m in doc["models"]):  # materialize would fail after the save
        raise ShuntError(f"{path} has an entry that is not an object, nothing was changed.")
    if any(m.get("id") == model_id for m in doc["models"]):
        raise ShuntError(f"model '{model_id}' is already in the registry.")
    agent = slug(model_id)
    entry = {"id": model_id, "agent": agent, "enabled": True, "thinking": False,
             "thinking_options": None, "thinking_off_options": None, "roles": roles}
    _save(path, {**doc, "models": [*doc["models"], entry]})
    return agent


def remove(path: str, model_id: str) -> None:
    doc = _load(path)
    models = [m for m in doc["models"] if not (isinstance(m, dict) and m.get("id") == model_id)]
    new = {**doc, "models": models}
    if new.get("active") == model_id:
        new["active"] = None
    _save(path, new)


def reorder(path: str, model_id: str, position: int) -> None:
    """Move the model to the 1-based position. Slices behave like the jq ones, also for 0."""
    doc = _load(path)
    target = [m for m in doc["models"] if isinstance(m, dict) and m.get("id") == model_id]
    rest = [m for m in doc["models"] if not (isinstance(m, dict) and m.get("id") == model_id)]
    index = position - 1
    _save(path, {**doc, "models": rest[0:index] + target + rest[index:]})


def activate(path: str, model_id: str) -> None:
    doc = _load(path)
    if any(isinstance(m, dict) and m.get("id") == model_id and m.get("enabled") is False for m in doc["models"]):
        raise ShuntError(f"model '{model_id}' is disabled. Enable it first: shunt-models enable {model_id}")
    _save(path, {**doc, "active": model_id})


def set_enabled(path: str, model_id: str, value: bool) -> None:
    _update(path, model_id, lambda m: {**m, "enabled": value})


def thinking(path: str, model_id: str, state: str, options: str, role: str = "") -> None:
    """thinking on stores options (any JSON but null and false), off stores an object, {} clears it.

    With a role, only role_thinking[role] changes (state CLEAR removes it, the field goes when empty).
    Options given with a role are stored as the model's on or off options, the other state's stay.
    """
    if role:
        _role_thinking(path, model_id, state, options, role)
        return
    if state == "on":
        value = None
        if options:
            value = _parse_options(options)
            if value is None or value is False:
                raise ShuntError(f"thinking options must be valid JSON: {options}")
        _update(path, model_id, lambda m: {**m, "thinking": True, "thinking_options": value})
        return
    changes: dict[str, Any] = {"thinking": False, "thinking_options": None}
    if options:
        parsed = _parse_options(options)
        if not isinstance(parsed, dict):
            raise ShuntError(f"thinking off options must be a JSON object: {options}")
        changes["thinking_off_options"] = parsed or None
    _update(path, model_id, lambda m: {**m, **changes})


def _role_thinking(path: str, model_id: str, state: str, options: str, role: str) -> None:
    changes: dict[str, Any] = {}
    if options and state == "on":
        value = _parse_options(options)
        if value is None or value is False:
            raise ShuntError(f"thinking options must be valid JSON: {options}")
        changes["thinking_options"] = value
    elif options and state == "off":
        parsed = _parse_options(options)
        if not isinstance(parsed, dict):
            raise ShuntError(f"thinking off options must be a JSON object: {options}")
        changes["thinking_off_options"] = parsed or None

    def apply(model: dict[str, Any]) -> dict[str, Any]:
        current = model.get("role_thinking")
        if current is None or current is False:
            current = {}
        if not isinstance(current, dict):
            raise ShuntError(f"could not update the registry entry for '{model_id}'.")
        merged = {k: v for k, v in current.items() if k != role}
        if state != CLEAR:
            merged = {**current, role: state == "on"}
        rest = {k: v for k, v in {**model, **changes}.items() if k != "role_thinking"}
        return {**rest, "role_thinking": merged} if merged else rest

    _update(path, model_id, apply)


def _parse_options(options: str) -> Any:
    try:
        return parse_json(options)
    except (ValueError, RecursionError):
        raise ShuntError(f"thinking options must be valid JSON: {options}") from None


def request_body(path: str, model_id: str, role: str, value: str) -> str:
    """Set or clear request_body, or role_request_body[role]. Returns 'set' or 'cleared'."""
    body: Any = None
    if value != CLEAR:
        try:
            body = parse_json(value)
        except (ValueError, RecursionError):
            body = None
        if not isinstance(body, dict):
            raise ShuntError(f"request body must be a JSON object: {value}")

    def apply(model: dict[str, Any]) -> dict[str, Any]:
        if not role:
            rest = {k: v for k, v in model.items() if k != "request_body"}
            return rest if body is None else {**rest, "request_body": body}
        roles = model.get("role_request_body")
        if roles is None or roles is False:
            roles = {}
        if not isinstance(roles, dict):
            raise ShuntError(f"could not update the registry entry for '{model_id}'.")
        merged = {k: v for k, v in roles.items() if k != role}
        if body is not None:
            merged = {**roles, role: body}
        rest = {k: v for k, v in model.items() if k != "role_request_body"}
        return {**rest, "role_request_body": merged} if merged else rest

    _update(path, model_id, apply)
    return "cleared" if body is None else "set"


def set_roles(path: str, model_id: str, roles_csv: str) -> None:
    roles = parse_roles(roles_csv)
    _update(path, model_id, lambda m: {**m, "roles": roles})


def set_context(path: str, model_id: str, tokens: str) -> None:
    if not (tokens.isascii() and tokens.isdigit() and tokens[0] != "0" and len(tokens) <= MAX_CONTEXT_DIGITS):
        raise ShuntError(f"tokens must be a positive integer of at most {MAX_CONTEXT_DIGITS} digits.")
    _update(path, model_id, lambda m: {**m, "context_tokens": int(tokens)})


def set_oversize(path: str, model_id: str, policy: str) -> None:
    if policy != CLEAR and policy not in OVERSIZE_POLICIES:
        raise ShuntError(f"oversize policy must be one of: {' '.join(OVERSIZE_POLICIES)} or {CLEAR}.")

    def apply(model: dict[str, Any]) -> dict[str, Any]:
        rest = {k: v for k, v in model.items() if k != "oversize_policy"}
        return rest if policy == CLEAR else {**rest, "oversize_policy": policy}

    _update(path, model_id, apply)


# ---------------------------------------------------------------- command line

def _dispatch(args: argparse.Namespace, environ: Mapping[str, str]) -> int:
    path = env.models_file_text(environ)
    cmd = args.models_write_command
    if cmd == "parse-roles":
        sys.stdout.write(",".join(parse_roles(args.roles)) + "\n")
        return 0
    with models_lock(path, environ):
        _run_locked(args, path)
    return 0


def _run_locked(args: argparse.Namespace, path: str) -> None:
    cmd = args.models_write_command
    if cmd == "put":
        put(path, sys.stdin.buffer.read().decode("utf-8", "surrogateescape"))
    elif cmd == "add":
        sys.stdout.write(add(path, args.id, args.roles) + "\n")
    elif cmd == "remove":
        remove(path, args.id)
    elif cmd == "reorder":
        reorder(path, args.id, int(args.position))
    elif cmd == "activate":
        activate(path, args.id)
    elif cmd == "set-enabled":
        set_enabled(path, args.id, args.value == "true")
    elif cmd == "thinking":
        thinking(path, args.id, args.state, args.options, args.role)
    elif cmd == "request-body":
        sys.stdout.write(request_body(path, args.id, args.role, args.value) + "\n")
    elif cmd == "roles":
        set_roles(path, args.id, args.roles)
    elif cmd == "set-context":
        set_context(path, args.id, args.tokens)
    elif cmd == "oversize-policy":
        set_oversize(path, args.id, args.policy)


def run(args: argparse.Namespace) -> int:
    try:
        return _dispatch(args, os.environ)
    except BrokenPipeError:
        raise
    except (ShuntError, OSError, UnicodeError, ValueError) as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


_COMMAND_ARGS: Sequence[tuple[str, tuple[str, ...]]] = (
    ("add", ("id", "roles")),
    ("remove", ("id",)),
    ("reorder", ("id", "position")),
    ("activate", ("id",)),
    ("thinking", ("id", "state", "options")),
    ("request-body", ("id", "role", "value")),
    ("roles", ("id", "roles")),
    ("set-context", ("id", "tokens")),
    ("oversize-policy", ("id", "policy")),
)


def register(subparsers: Any) -> None:
    """Add the `models-write` command group to the top-level subparsers."""
    group = subparsers.add_parser("models-write", help="change the model registry")
    group.set_defaults(func=run)
    sub = group.add_subparsers(dest="models_write_command", required=True)
    sub.add_parser("put")
    sub.add_parser("parse-roles").add_argument("roles")
    for name, arg_names in _COMMAND_ARGS:
        parser = sub.add_parser(name)
        for arg_name in arg_names:
            parser.add_argument(arg_name)
    sub.choices["thinking"].add_argument("--role", default="", choices=("", *ROLES))
    enabled = sub.add_parser("set-enabled")
    enabled.add_argument("value", choices=("true", "false"))
    enabled.add_argument("id")

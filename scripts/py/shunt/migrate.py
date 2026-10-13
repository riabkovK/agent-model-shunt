"""`shunt-models --migrate-from-opencode [--apply [--yes]] [--key-storage keyring|env|plaintext|skip]`.

Port of the command part of scripts/lib/migrate.sh: argument parsing, the temporary
detection providers file, backups, key storage and the writes. The plan is in
migrate_plan.py and its documents and text in migrate_view.py.

Source of truth is $SHUNT_OPENCODE_CONFIG_HOME/opencode.json, never modified. Only providers
used by a registry model are migrated. The default is a dry run that changes nothing.

Secret rules: a copied key travels from its source in memory to the keyring command's stdin
or to providers.json, and is never printed, logged, put in argv or in a plan. The detection
providers file in TMPDIR never holds a key. SIGINT, SIGTERM and SIGHUP end the process with
130, 143 and 129 after the temp file is removed.
"""

import argparse
import contextlib
import io
import json
import os
import signal
import sys
import tempfile
import time
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from . import env, models, models_write, providers, providers_write
from .jsonio import write_json_atomic
from .lockfile import LockTimeout, file_lock
from .migrate_plan import STORAGE_CHOICES, Ctx, collect_providers, make_entry, initial_used_refs, plan_models, plan_provider, read_key
from .migrate_view import detect_doc, has_changes, models_doc, print_plan, providers_doc
from .providers import ProviderError

_USAGE = f"usage: shunt-models --migrate-from-opencode [--apply [--yes]] [--key-storage {'|'.join(STORAGE_CHOICES)}]"
_SIGNAL_EXIT = {"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129}
_BACKUP_TRIES = 5
_YES_ANSWERS = ("y", "Y", "yes", "YES")


class MigrateError(Exception):
    """A failure reported as one `shunt:` line."""

    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.code = code


def _parse(argv: Sequence[str], environ: Mapping[str, str]) -> tuple[Ctx, bool]:
    apply = yes = False
    flag = ""
    items = list(argv)
    while items:
        arg = items.pop(0)
        if arg == "--apply":
            apply = True
        elif arg == "--yes":
            yes = True
        elif arg == "--key-storage":
            if not items or items[0] not in STORAGE_CHOICES:
                raise MigrateError(f"--key-storage takes one of: {' '.join(STORAGE_CHOICES)}.")
            flag = items.pop(0)
        else:
            raise MigrateError(_USAGE)
    ctx = Ctx(environ=environ, apply=apply, flag=flag, hint_cmd=environ.get("SHUNT_MODELS_HINT_CMD", ""))
    return ctx, yes


# ---------------------------------------------------------------- plan with detection

@contextlib.contextmanager
def _detect_file(ctx: Ctx, plan: Mapping[str, Any]) -> Iterator[str]:
    """A 0600 temp providers file for detection, removed on every way out. It holds no key."""
    tmp = str(env.tmp_dir(ctx.environ))
    try:
        fd, path = tempfile.mkstemp(prefix="shunt-migrate.", dir=tmp)
    except OSError:
        raise MigrateError(f"cannot create a temp file in {tmp}.") from None
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(detect_doc(ctx, plan), handle, separators=(",", ":"), ensure_ascii=False)
        yield path
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)


def build_plan(ctx: Ctx) -> dict[str, Any]:
    ctx.used_refs.update(initial_used_refs(ctx))
    items = []
    for found in collect_providers(ctx):
        item = plan_provider(ctx, found)
        items.append(item)
        if item["storage"] == "env":
            ctx.used_refs.add(item["env_ref"])
    plan: dict[str, Any] = {"providers": items, "models": []}
    with _detect_file(ctx, plan) as pfile:
        return {**plan, "models": plan_models(ctx, plan, False, pfile)}


# ---------------------------------------------------------------- apply

def _backup(path: str, stamp: str) -> None:
    if not os.path.isfile(path):
        return
    with open(path, "rb") as source:
        payload = source.read()
    for attempt in range(_BACKUP_TRIES):
        suffix = "" if attempt == 0 else f".{os.getpid()}.{time.time_ns()}"
        dest = f"{path}.bak-{stamp}{suffix}"
        try:  # never overwrite or follow an existing path, the copy may hold keys
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as out:
            os.fchmod(out.fileno(), 0o600)
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        sys.stdout.write(f"shunt: backup: {dest}\n")
        return
    raise MigrateError(f"could not create a backup of {path}.")


def _store_failed(name: str, where: str, reason: ProviderError | None) -> MigrateError:
    if reason is not None:
        sys.stderr.write(f"shunt: {reason}\n")
    return MigrateError(f"could not store the key of '{name}' in {where}.")


def _store_keyring(ctx: Ctx, plan: dict[str, Any], name: str) -> None:
    item = next(p for p in plan["providers"] if p["name"] == name)
    key = read_key(ctx, item)
    try:
        if key is None:
            raise ProviderError("the key could not be read.")
        providers.keyring_store(name, ctx.version_file, io.BytesIO((key + "\n").encode("utf-8", "surrogateescape")))
    except (ProviderError, ValueError) as exc:
        if isinstance(exc, ProviderError):  # fixed text, never the key
            sys.stderr.write(f"shunt: {exc}\n")
        sys.stderr.write(f"shunt: could not store the key of '{name}' in the keyring, leaving it pending.\n")
        pending = {**item, "storage": "skip", "state": "pending",
                   "entry": make_entry("skip", item["base_url"], "")}
        plan["providers"] = [pending if p["name"] == name else p for p in plan["providers"]]


def _store_plaintext(ctx: Ctx, plan: Mapping[str, Any], name: str) -> None:
    item = next(p for p in plan["providers"] if p["name"] == name)
    key = read_key(ctx, item)
    try:
        if key is None:
            raise ProviderError("the key could not be read.")
        providers_write.plaintext_store(ctx.providers_path, name, key.split("\n", 1)[0])
    except ProviderError as exc:
        raise _store_failed(name, ctx.providers_path, exc) from None
    except ValueError:  # no exception text, it could echo the key
        raise _store_failed(name, ctx.providers_path, None) from None
    sys.stdout.write(f"shunt: warning: the key is stored in plain text in {ctx.providers_path} "
                     "(mode 600). Prefer a keyring or an environment variable.\n")


def _store_keys(ctx: Ctx, plan: dict[str, Any], which: str) -> None:
    names = [p["name"] for p in plan["providers"] if p["storage"] == which and p["state"] == "new"]
    for name in names:
        if which == "keyring":
            _store_keyring(ctx, plan, name)
        else:
            _store_plaintext(ctx, plan, name)


@contextlib.contextmanager
def _providers_lock(ctx: Ctx) -> Iterator[None]:
    path = ctx.providers_path
    try:
        with file_lock(path, env.providers_lock_timeout(ctx.environ)):
            yield
    except LockTimeout:
        sys.stderr.write(f"shunt: timed out waiting for the lock on {path}.\n")
        raise MigrateError(f"could not lock {path}.") from None
    except env.EnvError as exc:
        raise MigrateError(str(exc)) from None


@contextlib.contextmanager
def _models_lock(ctx: Ctx) -> Iterator[None]:
    path = ctx.models_path
    try:
        with models_write.models_lock(path, ctx.environ):
            yield
    except models.ShuntError as exc:
        raise MigrateError(str(exc)) from None


def _write(path: str, doc: Mapping[str, Any]) -> None:
    try:
        write_json_atomic(Path(path), doc)
    except OSError:
        raise MigrateError(f"could not write {path}.") from None


def apply_plan(ctx: Ctx, plan: dict[str, Any]) -> None:
    stamp = time.strftime("%Y%m%d%H%M%S")
    with _models_lock(ctx):
        _backup(ctx.models_path, stamp)
        with _providers_lock(ctx):
            _backup(ctx.providers_path, stamp)
        _store_keys(ctx, plan, "keyring")
        with _providers_lock(ctx):
            _write(ctx.providers_path, providers_doc(ctx, plan))
            _store_keys(ctx, plan, "plaintext")
        plan["models"] = plan_models(ctx, plan, True, ctx.providers_path)
        _write(ctx.models_path, models_doc(ctx, plan))
    sys.stdout.write(f"shunt: migration applied. Check with: {ctx.hint_cmd} status\n")


# ---------------------------------------------------------------- command

def _confirmed() -> bool:
    sys.stderr.write("Proceed? [y/N] ")
    sys.stderr.flush()
    return sys.stdin.readline().strip(" \t\n") in _YES_ANSWERS


def migrate(argv: Sequence[str], environ: Mapping[str, str]) -> int:
    ctx, yes = _parse(argv, environ)
    if not models.available(ctx.models_path):
        raise MigrateError(f"no models registry at {ctx.models_path}.")
    if not os.path.isfile(ctx.opencode_json):
        raise MigrateError(f"no {ctx.opencode_json} to migrate from.")
    providers.validate(ctx.providers_path)
    plan = build_plan(ctx)
    if not has_changes(ctx, plan):
        print_plan(plan, ctx.hint_cmd)
        sys.stdout.write("shunt: nothing to migrate, nothing to do.\n")
        return 0
    sys.stdout.write("shunt: migration plan\n" if ctx.apply else "shunt: migration plan (dry run, nothing is changed)\n")
    print_plan(plan, ctx.hint_cmd)
    if not ctx.apply:
        sys.stdout.write("shunt: re-run with --apply to write it (a backup of models.json and providers.json is made first).\n")
        return 0
    if not yes:
        if sys.stdin is None or not sys.stdin.isatty():
            raise MigrateError("refusing to apply without a terminal or --yes. Show the dry-run plan above to the user, "
                               "and re-run with --apply --yes after they confirm.")
        if not _confirmed():
            sys.stdout.write("shunt: aborted, nothing changed.\n")
            return 0
    apply_plan(ctx, plan)
    return 0


def _exit_on_signals() -> None:
    """Turn the termination signals into a normal exit so the temp file is removed."""
    for name, code in _SIGNAL_EXIT.items():
        sig = getattr(signal, name, None)
        if sig is not None:
            signal.signal(sig, lambda _num, _frame, code=code: sys.exit(code))


def run(args: argparse.Namespace) -> int:
    _exit_on_signals()
    try:
        return migrate(args.args, dict(os.environ))
    except BrokenPipeError:
        raise
    except MigrateError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return exc.code
    except ProviderError as exc:
        sys.stderr.write(f"shunt: {exc}\n")
        return exc.code
    except OSError as exc:  # paths and strerror text only
        sys.stderr.write(f"shunt: {exc}\n")
        return 1


def register(subparsers: Any) -> None:
    """Add the `migrate` command to the top-level subparsers."""
    command = subparsers.add_parser("migrate", help="migrate the OpenCode config to the HTTP transport")
    command.set_defaults(func=run)
    command.add_argument("args", nargs="*")

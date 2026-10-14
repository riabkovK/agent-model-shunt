"""The healthcheck off the request path: the gate a request asks, and the background probe.

A request never waits for a probe. `gate` reads the status cache (healthcheck.py) and answers at once:
True when the model was found unhealthy less than SHUNT_HEALTHCHECK_RETRY seconds ago (fail over now),
False otherwise (go on with the real call). A missing or stale status also starts a detached probe,
`shunt_main.py healthcheck-refresh <provider> <model>`. The child gets only the provider name and the
model id in argv. It looks up the provider and reads the key itself, so a key is never in argv.

One probe per provider, base_url and model runs at a time: a lock file made with O_EXCL, taken before
the child starts and removed by it. A lock older than twice the probe's time cap is stale and replaced.
The child has a time cap and always exits 0. Any problem to start it is swallowed, the real call goes on.
A successful probe also clears the circuit breaker state of the model.

The status is set by the probe, not by a failed connect of a real call. A real call that could not
connect (`note_connect_failure`) leaves the status alone and starts a probe at once, even when the status
is still fresh. The probe tries a connect three times (healthcheck.PROBE_CONNECT_RETRIES), so a tunnel
that needs a few seconds after idling does not disable the model. The real call itself fails over as
before. A success still marks healthy, and a broken model route (404, 5xx) still marks unhealthy.

SHUNT_HEALTHCHECK_INLINE=1 runs the probe in the calling process instead (tests only).
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import sys
import threading
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from . import breaker, env, healthcheck, models, providers

COMMAND = "healthcheck-refresh"
CAP_GRACE_SECONDS = 5.0
MAIN_SCRIPT = Path(__file__).resolve().parents[1] / "shunt_main.py"


def _lock_path(environ: Mapping[str, str], key: tuple[str, str, str]) -> Path:
    digest = hashlib.sha256("\0".join(key).encode("utf-8", "surrogateescape")).hexdigest()[:20]
    return env.healthcheck_cache_file(environ).parent / f".healthcheck-{digest}.lock"


def time_cap(environ: Mapping[str, str]) -> float:
    """The most seconds a probe may run: both steps, every connect attempt of both steps and a grace."""
    connects = 2 * (1 + healthcheck.PROBE_CONNECT_RETRIES)
    return (env.healthcheck_timeout(environ) + env.healthcheck_model_timeout(environ)
            + connects * env.connect_timeout(environ) + CAP_GRACE_SECONDS)


def _release(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def _expired(path: Path, stale_after: float) -> bool:
    try:
        age = time.time() - path.stat().st_mtime
        return age < 0 or age > stale_after  # a lock from the future cannot be trusted either
    except OSError:
        return False


def _acquire(path: Path, stale_after: float) -> bool:
    """Take the per key lock. A stale one is replaced (two spawners racing for it may both win once,
    which only costs one more probe)."""
    for _ in range(2):
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600))
            return True
        except FileExistsError:
            if not _expired(path, stale_after):
                return False
            _release(path)
        except OSError:
            return False
    return False


def _launch(environ: Mapping[str, str], pairs: list[tuple[str, str]]) -> None:
    import subprocess
    flat = [name for pair in pairs for name in pair]
    subprocess.Popen([sys.executable, "-I", "-B", str(MAIN_SCRIPT), COMMAND, "--", *flat],
                     env=dict(environ), start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)


def spawn(environ: Mapping[str, str], provider: str, base_url: str, model: str) -> None:
    """Start one background probe unless one runs. Never waits and never raises."""
    spawn_many(environ, [(provider, base_url, model)])


def spawn_many(environ: Mapping[str, str], items: list[tuple[str, str, str]]) -> None:
    """Start ONE detached child that probes the models whose lock could be taken, one after the other.
    Never waits and never raises."""
    claimed: list[tuple[Path, str, str]] = []
    try:
        for provider, base_url, model in items:
            lock = _lock_path(environ, (provider, healthcheck.normalize_base(base_url), model))
            if healthcheck.trusted_folder(lock.parent) and _acquire(lock, 2 * time_cap(environ)):
                claimed.append((lock, provider, model))
        if not claimed:
            return
        pairs = [(provider, model) for _, provider, model in claimed]
        if env.healthcheck_inline(environ):
            for provider, model in pairs:
                refresh(provider, model, environ)
        else:
            _launch(environ, pairs)
    except Exception:  # noqa: BLE001  a probe is an optimisation, the real call goes on
        for lock, _, _ in claimed:
            _release(lock)


def gate(environ: Mapping[str, str], provider: str, base_url: str, model: str) -> int | None:
    """Seconds until the next check (at least 1) when the request must fail over now, else None. Starts a background probe when the status is
    missing or stale. Raises env.EnvError for an invalid SHUNT_HEALTHCHECK_TTL or _RETRY."""
    ttl, retry = env.healthcheck_ttl(environ), env.healthcheck_retry(environ)
    base = healthcheck.normalize_base(base_url)
    found = healthcheck.lookup(env.healthcheck_cache_file(environ), provider, base, model, breaker.now(environ))
    blocked, probe = healthcheck.verdict(found, ttl, retry)
    if probe:
        spawn(environ, provider, base, model)
    if not blocked or found is None:
        return None
    return max(1, math.ceil(retry - found[1]))



def note_call(environ: Mapping[str, str], provider: str, base_url: str, model: str, healthy: bool) -> None:
    """The real call's outcome: a success marks healthy and clears the model's breaker state, a
    broken model route marks unhealthy. A connect failure goes to note_connect_failure instead."""
    healthcheck.remember(env.healthcheck_cache_file(environ), provider, base_url, model,
                         breaker.now(environ), healthy)
    if healthy:
        clear_breaker(environ, f"{provider}/{model}")


def note_connect_failure(environ: Mapping[str, str], provider: str, base_url: str, model: str) -> None:
    """The real call could not connect: leave the status as it is and let a probe decide (it retries
    the connect). Never waits and never raises."""
    try:
        if env.healthcheck_timeout(environ) <= 0:
            return  # the healthcheck is off
    except Exception:  # noqa: BLE001  an invalid value is reported by the gate
        return
    spawn(environ, provider, base_url, model)


def clear_breaker(environ: Mapping[str, str], model_id: str) -> None:
    try:
        breaker.clear_state(environ, model_id)
    except Exception:  # noqa: BLE001  the breaker is an optimisation
        return


def owns_unreachable(environ: Mapping[str, str], model_id: str) -> bool:
    """True when the healthcheck of this model's provider is on and its cache folder is trusted. Its
    unhealthy status, which expires after SHUNT_HEALTHCHECK_RETRY, then replaces the breaker pause for
    an unreachable failure. An untrusted folder gets no probe and no status, so the breaker keeps it."""
    try:
        if env.healthcheck_timeout(environ) <= 0:
            return False
        cache = env.healthcheck_cache_file(environ)
        if not healthcheck.trusted_folder(cache.parent):
            return False
        if cache.is_symlink() or (cache.exists() and not cache.is_file()):
            return False  # _store never writes such a path, so no status would ever replace the pause
        return providers.field(env.providers_file_text(environ), model_id.split("/", 1)[0], "healthcheck") == "true"
    except Exception:  # noqa: BLE001  unreadable config: keep the breaker
        return False


def base_url_of(path: str, provider: str) -> str | None:
    """The provider's base_url as the transport would call it, or None when it is unusable."""
    url = providers.field(path, provider, "base-url")
    code = providers.base_url_check(url)
    return url if code == 0 else "https://" + url if code == 3 else None


_pending: set[Path] = set()  # locks of this process that are not released yet


def _probe(provider: str, model: str, environ: Mapping[str, str]) -> None:
    lock = None
    try:
        path = env.providers_file_text(environ)
        base = base_url_of(path, provider)
        if base is None:
            return
        lock = _lock_path(environ, (provider, healthcheck.normalize_base(base), model))
        _pending.add(lock)
        if providers.field(path, provider, "healthcheck") != "true":
            return
        secret = providers.bearer_key(path, provider, environ, env.proc_version_file_text(environ))
        headers = {"Authorization": f"Bearer {secret}"} if secret else {}
        reason = healthcheck.run_probes(base, model, headers, env.healthcheck_timeout(environ),
                                        env.healthcheck_model_timeout(environ), env.connect_timeout(environ))
        note_call(environ, provider, base, model, reason is None)
    finally:
        if lock is not None:
            _release(lock)
            _pending.discard(lock)


def refresh(provider: str, model: str, environ: Mapping[str, str]) -> None:
    """The probe itself. Never raises: the status stays as it was when anything goes wrong."""
    try:
        _probe(provider, model, environ)
    except Exception:  # noqa: BLE001
        return


def warm_up(environ: Mapping[str, str]) -> None:
    """At session start: one background probe for each enabled model of a healthcheck provider whose
    status is missing or stale. Never waits, never raises."""
    try:
        _warm_up(environ)
    except Exception:  # noqa: BLE001
        return


def _warm_up(environ: Mapping[str, str]) -> None:
    if env.healthcheck_timeout(environ) <= 0:
        return
    path = env.providers_file_text(environ)
    ttl, retry = env.healthcheck_ttl(environ), env.healthcheck_retry(environ)
    bases: dict[str, str | None] = {}
    due: list[tuple[str, str, str]] = []
    for model_id in dict.fromkeys(models.enabled_ids(env.models_file_text(environ))):
        provider, _, model = model_id.partition("/")
        if provider not in bases:
            on = providers.field(path, provider, "healthcheck") == "true"
            bases[provider] = base_url_of(path, provider) if on else None
        base = bases[provider]
        if base is None or not model:
            continue
        found = healthcheck.lookup(env.healthcheck_cache_file(environ), provider,
                                   healthcheck.normalize_base(base), model, breaker.now(environ))
        if healthcheck.verdict(found, ttl, retry)[1]:
            due.append((provider, base, model))
    if due:
        spawn_many(environ, due)  # one child for all of them


def _hard_stop() -> None:
    """The time cap hit: free the locks still held and leave. os._exit cannot be caught by a
    broad `except` in the HTTP client the way a signal handler's exception can."""
    for lock in list(_pending):
        _release(lock)
    os._exit(0)


def run(args: argparse.Namespace) -> int:
    """healthcheck-refresh: the detached child. Always exits 0, within the time cap of all its models."""
    names = args.items
    pairs = list(zip(names[0::2], names[1::2]))
    try:
        timer = threading.Timer(max(1.0, time_cap(os.environ) * max(1, len(pairs))), _hard_stop)
        timer.daemon = True
        timer.start()
    except Exception:  # noqa: BLE001
        pass
    for provider, model in pairs:
        refresh(provider, model, os.environ)
    return 0


def register(subparsers: Any) -> None:
    command = subparsers.add_parser(COMMAND, help="refresh the healthcheck status of one model (background use)")
    command.set_defaults(func=run)
    command.add_argument("items", nargs="+", metavar="provider model", help="pairs of provider and model id")
